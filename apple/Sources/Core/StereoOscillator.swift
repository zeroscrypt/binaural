import Foundation

/// Two sine oscillators with independent frequencies and continuous phase.
///
/// Port of `binaural.core.oscillator.StereoOscillator` (CONTRACT §1). The port keeps
/// every behaviour the contract calls out:
///
/// * the phase is **never reset** when the frequency changes, so there is no click;
/// * the amplitude fade is **accumulated** towards a target (first-order approach),
///   never interpolated per block, so the curve does not depend on the block size;
/// * ``render(frames:)`` never throws and never logs — it runs from the audio callback.
///
/// Not `Sendable` on purpose: it owns mutable audio state and is meant to be confined
/// to whichever thread drives it. Marking it `@unchecked Sendable` would hide a race
/// rather than fix one.
///
/// M2 honoured that: `AudioEngine` creates the oscillator **on the render callback's
/// own thread** and no other thread ever touches it, so there is nothing to race on.
/// Frequencies, gain, pan and the sample rate travel the other way as plain values
/// through `ParameterMailbox` — see its documentation for the handover.
///
/// Sample buffers are `[Float]`, as CONTRACT §1 requires ("float32-like samples");
/// all internal arithmetic stays `Double`.
public final class StereoOscillator {

    // MARK: - State

    private var _sampleRate: Int
    private var _leftHz: Double
    private var _rightHz: Double

    /// Phase as a fraction of a cycle, so it never grows large.
    private var _phaseLeft: Double = 0.0
    private var _phaseRight: Double = 0.0

    private var _gain: Double = 0.0
    private var _targetGain: Double = 0.0
    private var _alpha: Double = 0.0
    private var _rampSeconds: Double = BeatMath.defaultRampSeconds

    /// One tone of the drone as the oscillator remembers it: the frequency, the phase
    /// and the amplitude on its way to the target.
    private struct DroneState {
        var hz: Double
        /// The phase, as a fraction of a cycle.
        var phase: Double
        /// The amplitude now.
        var gain: Double
        /// The amplitude it is heading for.
        var targetGain: Double
    }

    /// The tones under the main pair: extra frequencies rendered in both channels.
    ///
    /// The drone of the chakra mode: the tones of the steps below the one being played
    /// keep sounding under it, the way the set of tones accumulated in the reference
    /// app. They are centred, so the beat — a difference between the two channels —
    /// stays exactly what it was.
    private var drone: [DroneState] = []

    /// Per-channel amplitude, used to hard-pan the L/R headphone test (SPEC §4.2).
    private var _panLeft: Double = 1.0
    private var _panRight: Double = 1.0

    // MARK: - Life cycle

    /// - Throws: ``FrequencyError/invalidSampleRate(_:)`` when `sampleRate <= 0`.
    public init(sampleRate: Int = BeatMath.defaultSampleRate) throws {
        guard sampleRate > 0 else {
            throw FrequencyError.invalidSampleRate(sampleRate)
        }
        _sampleRate = sampleRate
        _leftHz = BeatMath.defaultCarrierHz
        _rightHz = BeatMath.defaultCarrierHz
        setFade(0.0, rampSeconds: BeatMath.defaultRampSeconds)
    }

    // MARK: - Accessors

    public var sampleRate: Int { _sampleRate }
    public var leftHz: Double { _leftHz }
    public var rightHz: Double { _rightHz }

    /// Current fractional phase of both oscillators, for tests and diagnostics.
    public var phase: (left: Double, right: Double) { (_phaseLeft, _phaseRight) }

    /// Current amplitude, in 0...1.
    public var gain: Double { _gain }

    /// Amplitude the fade is approaching, in 0...1.
    public var targetGain: Double { _targetGain }

    /// Per-channel amplitude as `(left, right)`, each in 0...1.
    public var pan: (left: Double, right: Double) { (_panLeft, _panRight) }

    // MARK: - Configuration

    /// Apply a new frequency pair without breaking the phase.
    ///
    /// - Throws: ``FrequencyError`` when a value is not a finite audible frequency.
    public func setFrequencies(leftHz: Double, rightHz: Double) throws {
        _leftHz = try BeatMath.validated(leftHz, name: "left_hz")
        _rightHz = try BeatMath.validated(rightHz, name: "right_hz")
    }

    /// Adopt a device sample rate.
    ///
    /// Phases are stored as fractions of a cycle, so only the increments and the ramp
    /// coefficient change — no click is introduced.
    public func setSampleRate(_ sampleRate: Int) throws {
        guard sampleRate > 0 else {
            throw FrequencyError.invalidSampleRate(sampleRate)
        }
        _sampleRate = sampleRate
        if _targetGain != _gain {
            recomputeAlpha()
        }
    }

    /// Target amplitude in 0...1, reached smoothly within `rampSeconds`.
    public func setFade(_ gain: Double, rampSeconds: Double = BeatMath.defaultRampSeconds) {
        _targetGain = min(1.0, max(0.0, gain.isFinite ? gain : 0.0))
        _rampSeconds = max(0.0, rampSeconds.isFinite ? rampSeconds : 0.0)
        if _rampSeconds <= 0.0 {
            // Still one sample of ramp: an instantaneous jump is a click.
            _alpha = 1.0
            return
        }
        recomputeAlpha()
    }

    /// Per-channel amplitude in 0...1; `(1, 0)` silences the right ear.
    public func setPan(left: Double = 1.0, right: Double = 1.0) {
        _panLeft = min(1.0, max(0.0, left.isFinite ? left : 0.0))
        _panRight = min(1.0, max(0.0, right.isFinite ? right : 0.0))
    }

    /// First-order approach: after `rampSeconds` the remaining error is 1/e.
    private func recomputeAlpha() {
        _alpha = 1.0 - exp(-1.0 / (_rampSeconds * Double(_sampleRate)))
    }

    /// Set the drone: the tones under the main pair, each with the amplitude it should
    /// have.
    ///
    /// A tone that stays keeps its phase, so a change cannot click. A tone that arrives
    /// fades in and a tone that leaves fades out, for the same reason.
    public func setDrone(_ tones: [DroneTone]) {
        var updated: [DroneState] = []
        updated.reserveCapacity(tones.count)
        for tone in tones {
            let hz = max(0, tone.hz)
            let gain = min(1, max(0, tone.gain))
            if let existing = drone.first(where: { abs($0.hz - hz) < 0.01 }) {
                updated.append(DroneState(
                    hz: hz, phase: existing.phase, gain: existing.gain, targetGain: gain
                ))
            } else {
                updated.append(DroneState(hz: hz, phase: 0, gain: 0, targetGain: gain))
            }
        }
        // A tone that is leaving keeps its place until its amplitude has fallen to
        // nothing, so the fade is a fade and not a step.
        for existing in drone where !updated.contains(where: { abs($0.hz - existing.hz) < 0.01 }) {
            if existing.gain > 1e-4 {
                updated.append(DroneState(
                    hz: existing.hz, phase: existing.phase, gain: existing.gain, targetGain: 0
                ))
            }
        }
        drone = updated
    }

    /// The drone's tones, for tests and diagnostics.
    public var droneTones: [DroneTone] {
        drone.map { DroneTone(hz: $0.hz, gain: $0.gain) }
    }

    // MARK: - Render

    /// Render `frames` samples per channel and advance both phases.
    ///
    /// Never throws, never logs: called from the audio callback.
    ///
    /// Allocates two arrays, so it is the right entry point for tests, previews and
    /// offline rendering — but *not* for a real-time callback, where the heap traffic
    /// is exactly what must not happen. Live output uses
    /// ``render(frames:into:intoRight:)`` below with storage it owns.
    public func render(frames: Int) -> (left: [Float], right: [Float]) {
        guard frames > 0 else { return ([], []) }

        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                render(frames: frames, into: leftBuffer, intoRight: rightBuffer)
            }
        }
        return (left, right)
    }

    /// Render `frames` samples per channel into storage the caller already owns.
    ///
    /// Identical maths, identical phase and fade state, and **no allocation** — the
    /// M2 addition that makes the oscillator usable from an `AVAudioSourceNode` render
    /// callback, where "no allocation in the hot loop" (CONTRACT §1) is a hard rule.
    ///
    /// The shorter of the two buffers decides how much is written: a partially filled
    /// buffer is left alone rather than overrun.
    public func render(
        frames: Int,
        into left: UnsafeMutableBufferPointer<Float>,
        intoRight right: UnsafeMutableBufferPointer<Float>
    ) {
        let count = min(frames, left.count, right.count)
        guard count > 0 else { return }

        let inverseRate = 1.0 / Double(_sampleRate)
        let stepLeft = _leftHz * inverseRate
        let stepRight = _rightHz * inverseRate

        let alpha = _alpha
        let panLeft = _panLeft
        let panRight = _panRight
        var gain = _gain
        let target = _targetGain
        var phaseLeft = _phaseLeft
        var phaseRight = _phaseRight

        for index in 0..<count {
            // The phase already carries the frequency through its increment
            // (f / sampleRate), so the argument is 2*pi*phase only.
            left[index] = Float(gain * panLeft * sin(2 * Double.pi * phaseLeft))
            right[index] = Float(gain * panRight * sin(2 * Double.pi * phaseRight))
            phaseLeft += stepLeft
            phaseRight += stepRight
            if phaseLeft >= 1.0 {
                phaseLeft = phaseLeft.truncatingRemainder(dividingBy: 1.0)
            }
            if phaseRight >= 1.0 {
                phaseRight = phaseRight.truncatingRemainder(dividingBy: 1.0)
            }
            if gain != target {
                gain += (target - gain) * alpha
                if abs(target - gain) < 1e-6 {
                    gain = target
                }
            }
        }

        // The drone: the extra tones, centred in both channels. They are added on top
        // of the main pair, so the beat — the difference between the channels — is
        // untouched by them.
        for index in drone.indices {
            let tone = drone[index]
            let step = tone.hz * inverseRate
            var phase = tone.phase
            var toneGain = tone.gain
            let target = tone.targetGain
            for sample in 0..<count {
                let value = Float(toneGain * sin(2 * Double.pi * phase))
                left[sample] += value
                right[sample] += value
                phase += step
                if phase >= 1.0 {
                    phase = phase.truncatingRemainder(dividingBy: 1.0)
                }
                if toneGain != target {
                    toneGain += (target - toneGain) * alpha
                    if abs(target - toneGain) < 1e-6 {
                        toneGain = target
                    }
                }
            }
            drone[index].phase = phase
            drone[index].gain = toneGain
        }
        // A tone that has faded away is forgotten.
        drone.removeAll { $0.targetGain == 0 && $0.gain < 1e-4 }

        _phaseLeft = phaseLeft
        _phaseRight = phaseRight
        _gain = gain
    }
}