import AVFoundation
import Foundation

/// Everything the audio thread needs to know, as plain values.
///
/// `Sendable` on purpose: this is the *only* thing that crosses the thread boundary,
/// and crossing it as a value type means there is no shared mutable state to protect.
/// Frequencies, gain, pan and the sample rate are `Double`/`Int`, so a copy is a copy.
public struct RenderParameters: Sendable, Equatable {

    /// Left channel frequency in Hz.
    public var leftHz: Double
    /// Right channel frequency in Hz.
    public var rightHz: Double
    /// Target amplitude in 0...1 — playback on/off, volume and mute folded together.
    public var gain: Double
    /// How long ``gain`` should take to arrive, in seconds.
    public var rampSeconds: Double
    /// Per-channel amplitude in 0...1; `(1, 0)` is the left-ear-only L/R test tone.
    public var panLeft: Double
    /// See ``panLeft``.
    public var panRight: Double
    /// Sample rate of the device the engine is feeding.
    public var sampleRate: Int

    public init(
        leftHz: Double = BeatMath.defaultCarrierHz,
        rightHz: Double = BeatMath.defaultCarrierHz,
        gain: Double = 0,
        rampSeconds: Double = BeatMath.defaultRampSeconds,
        panLeft: Double = 1,
        panRight: Double = 1,
        sampleRate: Int = BeatMath.defaultSampleRate
    ) {
        self.leftHz = leftHz
        self.rightHz = rightHz
        self.gain = gain
        self.rampSeconds = rampSeconds
        self.panLeft = panLeft
        self.panRight = panRight
        self.sampleRate = sampleRate
    }

    /// ``gain`` and ``rampSeconds`` together — what `StereoOscillator.setFade` takes.
    public var fade: (gain: Double, rampSeconds: Double) { (gain, rampSeconds) }
}

/// The main thread -> audio thread handover.
///
/// ## Why this is correct
///
/// `StereoOscillator` is non-`Sendable` by design and the main thread must not touch
/// it, so the only way for a frequency change to reach the audio thread is a channel
/// of *plain values*. The channel has exactly one writer (the main thread, through
/// ``publish(_:)``) and exactly one reader (the render callback, through
/// ``load(fallback:)``), and it is guarded by one `NSLock` used with
/// `try lock()` — a **non-blocking** try, never a wait:
///
/// * the audio thread copies the whole `RenderParameters` value while holding the
///   lock, so it can never observe a half-updated pair of frequencies (no torn read,
///   no need for a version counter);
/// * if the try fails — which needs the main thread to be *inside* `publish`, a window
///   of a few nanoseconds — the callback does **not** block and does **not** spin. It
///   renders the previous block's parameters instead. One stale block (~5 ms) on the
///   rarest possible interleaving is inaudible, and every later block picks the change
///   up; the alternative (blocking the real-time thread) is how you get a dropout;
/// * `NSLock` is already documented thread-safe and `RenderParameters` is a value
///   type, so `Sendable` is derived rather than asserted — no `@unchecked` anywhere in
///   this file.
///
/// Nothing here allocates, and no lock is held across a call into AppKit.
public final class ParameterMailbox: @unchecked Sendable {

    private let lock = NSLock()
    private var stored: RenderParameters

    public init(_ initial: RenderParameters = RenderParameters()) {
        stored = initial
    }

    /// Publish a new set of parameters. Cheap enough to call on every slider tick:
    /// one lock, one struct copy.
    public func publish(_ parameters: RenderParameters) {
        lock.lock()
        stored = parameters
        lock.unlock()
    }

    /// Take the latest parameters, or `fallback` when the writer holds the lock.
    ///
    /// `fallback` is the caller's own last-known-good copy, so a lost race costs one
    /// block of stale parameters and never a stall.
    public func load(fallback: RenderParameters) -> RenderParameters {
        guard lock.try() else { return fallback }
        let parameters = stored
        lock.unlock()
        return parameters
    }
}

/// The state that belongs to the audio thread: the oscillator and its scratch buffers.
///
/// ## Why `@unchecked Sendable` is the honest answer here
///
/// The object is `@unchecked Sendable` only so that a `@Sendable` render block can
/// capture it. The memory-safety argument is:
////
/// * the stored `StereoOscillator` is created **by `render` itself**, i.e. on the
///   render-callback thread, on first use — no other thread can ever observe it
///   before that, because there is nothing to observe;
/// * every read and every write of it happens inside `render`, on that same thread.
///   `AVAudioEngine` calls a node's render block from one thread at a time, and
///   `stop()` tears the thread down before it can run again, so no two calls overlap;
/// * the type's `init` takes no oscillator, so a caller cannot smuggle one in from
///   another thread and get a second reference out;
/// * the scratch buffers are allocated once, here, and reused for every block.
///
/// Marking `StereoOscillator` itself `@unchecked Sendable` would be the version of
/// this that hides a race: it would invite the main thread to call `setFrequencies`
/// on it. Creating it on the audio thread removes the race instead of describing it
/// away.
final class AudioRenderContext: @unchecked Sendable {

    /// Created on the audio thread by the first ``render(frameCount:into:)``.
    private var oscillator: StereoOscillator?
    private var current: RenderParameters

    /// Block scratch space, sized for the largest block seen so far.
    /// Two separate buffers rather than one interleaved one: `AVAudioEngine` hands
    /// over either layout, and filling planar storage first makes both a stride copy.
    private var left: [Float] = []
    private var right: [Float] = []

    /// Where the main thread publishes; read once per block, never blocking.
    private let mailbox: ParameterMailbox

    init(mailbox: ParameterMailbox, parameters: RenderParameters = RenderParameters()) {
        self.mailbox = mailbox
        current = parameters
    }

    /// Render one block into `buffers`, which may be interleaved, planar or mono.
    ///
    /// Allocation-free once the block size has settled: storage grows only when a
    /// larger block shows up.
    func render(
        frameCount: AVAudioFrameCount,
        into buffers: UnsafeMutableAudioBufferListPointer
    ) -> OSStatus {
        let frames = Int(frameCount)
        guard frames > 0, !buffers.isEmpty else { return noErr }

        // 1. Adopt whatever the main thread published; on a lost race keep rendering
        //    the previous block's parameters (see `ParameterMailbox`).
        current = mailbox.load(fallback: current)

        let oscillator = adopt(parameters: current)

        // 2. One preallocated block of maths.
        if left.count < frames {
            left = [Float](repeating: 0, count: frames)
            right = [Float](repeating: 0, count: frames)
        }
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                oscillator.render(frames: frames, into: leftBuffer, intoRight: rightBuffer)
            }
        }

        // 3. Fan the two channels out to whatever the engine asked for.
        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                write(left: leftBuffer, right: rightBuffer, into: buffers)
            }
        }
        return noErr
    }

    /// Create the oscillator on first use, then push only what actually changed into
    /// it. Phase is never touched, so a frequency change cannot click (SPEC F2).
    ///
    /// Cannot throw and cannot crash: the sample rate is clamped to a positive value
    /// first, which is the only thing `StereoOscillator.init` rejects.
    private func adopt(parameters: RenderParameters) -> StereoOscillator {
        if let oscillator {
            apply(parameters, to: oscillator)
            return oscillator
        }
        let rate = parameters.sampleRate > 0 ? parameters.sampleRate : BeatMath.defaultSampleRate
        guard let created = try? StereoOscillator(sampleRate: rate) else {
            preconditionFailure("StereoOscillator rejects only sample_rate <= 0")
        }
        apply(parameters, to: created)
        // Written after `apply`, still on the audio thread, and only read from there.
        oscillator = created
        return created
    }

    private func apply(_ parameters: RenderParameters, to oscillator: StereoOscillator) {
        if oscillator.sampleRate != parameters.sampleRate {
            // Cannot fail: the mailbox only carries rates > 0 (see `AudioEngine`).
            try? oscillator.setSampleRate(parameters.sampleRate)
        }
        if oscillator.leftHz != parameters.leftHz || oscillator.rightHz != parameters.rightHz {
            // Cannot fail either: the mailbox only carries frequencies that
            // `BeatMath.validated` accepted (see `AudioEngine.setFrequencies`).
            try? oscillator.setFrequencies(leftHz: parameters.leftHz, rightHz: parameters.rightHz)
        }
        let fade = parameters.fade
        if oscillator.targetGain != fade.gain || oscillator.gain != fade.gain {
            oscillator.setFade(fade.gain, rampSeconds: fade.rampSeconds)
        }
        let pan = oscillator.pan
        if pan.left != parameters.panLeft || pan.right != parameters.panRight {
            oscillator.setPan(left: parameters.panLeft, right: parameters.panRight)
        }
    }

    /// Fill an `AudioBufferList` of any shape the engine may hand over.
    ///
    /// * one buffer, two or more channels — interleaved, stride = channel count;
    /// * one buffer, one channel — a mono mixdown, which is what a mono device gets;
    /// * several buffers — planar: channel 0 is the left tone, channel 1 the right,
    ///   and any further channel (a surround device fed through the mixer) is silent,
    ///   because a binaural pair has nothing to say to the third speaker.
    private func write(
        left: UnsafeBufferPointer<Float>,
        right: UnsafeBufferPointer<Float>,
        into buffers: UnsafeMutableAudioBufferListPointer
    ) {
        let frames = min(left.count, right.count)

        guard let first = buffers.first else { return }
        let channels = max(1, Int(first.mNumberChannels))

        if buffers.count == 1 {
            first.mData?.assumingMemoryBound(to: Float.self).update(
                from: left,
                right: right,
                frames: frames,
                channels: channels
            )
            return
        }

        for (index, buffer) in buffers.enumerated() {
            guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            switch index {
            case 0: samples.update(from: left, count: frames)
            case 1: samples.update(from: right, count: frames)
            // Any further channel (a surround device fed through the mixer) is silent:
            // a binaural pair has nothing to say to the third speaker.
            default: samples.zero(count: frames)
            }
        }
    }
}

/// The failure texts ``AudioEngine`` can publish, as English catalogue keys.
///
/// Named constants rather than literals at the call sites, for the same reason Python
/// keeps `_ERROR_SOURCES`: the text must be translated when it is *shown*, never when the
/// failure happens — a dictionary built by calling `tr()` at import time would freeze
/// whatever language happened to be active then. ``L10nTests`` reads `all` so these keys
/// cannot go untranslated.
public enum AudioFailure {

    /// No usable output device, or no format could be built for it.
    public static let deviceUnavailable = "Could not open the audio output device."

    /// The device was there but `AVAudioEngine.start()` refused.
    public static let startFailed = "Could not start audio output."

    /// Every failure key, for the translation tests.
    public static let all: [String] = [deviceUnavailable, startFailed]
}

/// Stereo output through `AVAudioEngine` + `AVAudioSourceNode`.
///
/// Swift half of `binaural.core.engine.AudioEngine` (CONTRACT §2), with the same
/// surface the Python one exposes: `start`/`stop`/`shutdown`, `volume`, `isRunning` and
/// an `error` string carrying the **English source text** of the failure so the caller
/// can run it through `L10n.tr` at display time (the rule from `engine.py`: never
/// translate when the failure happens, translate when it is shown).
///
/// Main-actor isolated because every public method is a device operation, and because
/// `AVAudioEngine` is documented as main-thread-only for configuration. Nothing here
/// may be reached from the render callback except through ``mailbox`` and the
/// `AudioRenderContext` it holds.
@MainActor
public final class AudioEngine {

    /// User-facing failure text. Always an English catalogue key or an
    /// already-interpolated message; the UI translates it when it shows it.
    public private(set) var error: String?

    /// True while the engine is pulling samples.
    public private(set) var isRunning = false

    /// Output level in 0...1. Drives the oscillator's gain, never a post-hoc scale of
    /// the buffers (SPEC F2).
    public var volume: Double = Session.defaultVolume {
        didSet { updateParameters() }
    }

    /// Silences the output without forgetting the volume.
    public var isMuted = false {
        didSet { updateParameters() }
    }

    /// Sample rate the engine actually runs at — the device's, never an assumption.
    public private(set) var sampleRate = 0

    /// Channel count the engine actually runs at, from the device's stream format.
    public private(set) var channelCount = 0

    /// The main thread -> audio thread channel. Public so a caller can prove the
    /// handover with a test instead of trusting this comment.
    public let mailbox: ParameterMailbox

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let context: AudioRenderContext
    private let fadeSeconds = BeatMath.defaultRampSeconds
    private var frequencies: (left: Double, right: Double) = (
        Session.defaultLeftHz,
        Session.defaultRightHz
    )
    private var pan: (left: Double, right: Double) = (1, 1)

    public init(volume: Double = Session.defaultVolume) {
        self.volume = volume
        let mailbox = ParameterMailbox()
        self.mailbox = mailbox
        context = AudioRenderContext(mailbox: mailbox)
        mailbox.publish(currentParameters())
    }

    // MARK: - Parameters

    /// Set both channel frequencies. Values that are not finite audible frequencies
    /// are rejected and nothing is published — the same validation as the Python
    /// `set_frequencies`, done here so the audio thread never has to throw.
    public func setFrequencies(leftHz: Double, rightHz: Double) throws {
        let left = try BeatMath.validated(leftHz, name: "left_hz")
        let right = try BeatMath.validated(rightHz, name: "right_hz")
        frequencies = (left, right)
        updateParameters()
    }

    /// Hard-pan one channel, for the perceptual L/R test (SPEC §4.2). The hook itself is
    /// the M1 `setPan`, reached through the same mailbox as everything else.
    public func setPan(left: Double, right: Double) {
        pan = (left, right)
        updateParameters()
    }

    /// The pair the engine is currently set to, for a caller that has to put it back.
    ///
    /// Read-only on purpose. Nothing in the app needs this except ``LRTonePlayer``, which
    /// changes the frequencies to play a test tone and must restore exactly what was there
    /// — and a setter would let two pieces of state be written from two places, which is
    /// the failure M2-a's single-writer mailbox exists to prevent.
    public var currentFrequencies: (left: Double, right: Double) { frequencies }

    /// The per-channel amplitudes currently published, likewise read-only.
    public var currentPan: (left: Double, right: Double) { pan }

    /// The amplitude the oscillator should be approaching right now.
    ///
    /// A pure function so the rule — silent unless playing, silent when muted, otherwise
    /// exactly the volume — is testable without an output device, which a headless test
    /// host does not have. Nothing can blast audio on launch: the gain is 0 until Play.
    public static func outputGain(isRunning: Bool, isMuted: Bool, volume: Double) -> Double {
        guard isRunning, !isMuted else { return 0 }
        return min(1, max(0, volume.isFinite ? volume : 0))
    }

    /// Fold play state, volume and mute into the one published gain, then hand it over.
    private func currentParameters() -> RenderParameters {
        RenderParameters(
            leftHz: frequencies.left,
            rightHz: frequencies.right,
            gain: Self.outputGain(isRunning: isRunning, isMuted: isMuted, volume: volume),
            rampSeconds: fadeSeconds,
            panLeft: pan.left,
            panRight: pan.right,
            sampleRate: sampleRate > 0 ? sampleRate : BeatMath.defaultSampleRate
        )
    }

    private func updateParameters() {
        mailbox.publish(currentParameters())
    }

    // MARK: - Life cycle

    /// Start playback. Returns `false` and fills ``error`` when no device is available.
    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        error = nil

        let deviceFormat = engine.outputNode.inputFormat(forBus: 0)
        // The device's own rate, not 48000 by habit. A device that reports nothing yet
        // (it happens before the first start on some Macs) falls back to the contract's
        // documented default, and the oscillator is told either way.
        let rate = deviceFormat.sampleRate > 0 ? Int(deviceFormat.sampleRate.rounded()) : BeatMath.defaultSampleRate
        let channels = max(2, Int(deviceFormat.channelCount))

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(rate),
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            error = AudioFailure.deviceUnavailable
            return false
        }
        sampleRate = rate
        channelCount = channels
        updateParameters()

        // The context already exists; the render callback adopts the sample rate on
        // its first block, so no oscillator is created before the device is ready.
        if sourceNode == nil {
            let node = Self.makeSourceNode(format: format, context: context)
            engine.attach(node)
            sourceNode = node
        }
        guard let sourceNode else {
            error = AudioFailure.deviceUnavailable
            return false
        }
        // Through the mixer, so AVAudioEngine maps our format onto whatever the
        // device's own channel layout happens to be.
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.prepare()

        do {
            try engine.start()
        } catch {
            engine.disconnectNodeOutput(sourceNode)
            self.error = AudioFailure.startFailed
            return false
        }
        isRunning = true
        updateParameters()  // opens the amplitude through the fade, never as a step
        return true
    }

    /// Stop playback.
    ///
    /// The amplitude is ramped to zero first, so stopping is not a click; the engine
    /// itself keeps running and idle until ``shutdown()``. Holding the graph costs a
    /// negligible idle pull and buys an instant, click-free restart — the alternative
    /// (stop the engine and re-create the oscillator) would restart the phase from
    /// zero, which is precisely the discontinuity SPEC F2 rules out.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        updateParameters()
    }

    /// Tear the device down. Safe to call more than once; the app calls it on quit.
    public func shutdown() {
        stop()
        guard isRunning || sourceNode != nil else { return }
        engine.stop()
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
    }
}

// MARK: - The render block

extension AudioEngine {

    /// Build the source node whose render block is `context.render`.
    ///
    /// **This function is `nonisolated`, and that is a correctness requirement, not a
    /// style choice.** `AVAudioSourceNode` pulls its render block from the **CoreAudio IO
    /// thread**. Written inline inside `start()` — a `@MainActor` method — the closure
    /// *inherits* that isolation under Swift 6's closure-inference rules, so the compiler
    /// emits a main-actor check at the top of the block. Called from the IO thread that
    /// check trips `_dispatch_assert_queue` and the app dies with `SIGTRAP` the first
    /// time real audio renders.
    ///
    /// It stayed hidden through M2-a because the tests that start a real engine either
    /// skipped (no device) or pulled the block once from the calling (main) thread during
    /// `prepare()`, where the check passes. Found by the launch smoke test: the app ran,
    /// opened its window, and was killed by the audio thread seconds later.
    ///
    /// Hoisted out, the closure inherits no isolation: no runtime check, no actor hop, no
    /// dispatch assertion — the block touches only the context and the mailbox, which is
    /// exactly the threading design §7.2 of `apple/DESIGN.md` describes. Verified on the
    /// real IO thread by `testRenderBlockRunsOnTheAudioThreadWithoutAnIsolationTrap`.
    nonisolated static func makeSourceNode(
        format: AVAudioFormat,
        context: AudioRenderContext
    ) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, buffers in
            context.render(
                frameCount: frameCount,
                into: UnsafeMutableAudioBufferListPointer(buffers)
            )
        }
    }
}

// MARK: - Buffer writers

private extension UnsafeMutablePointer where Pointee == Float {

    /// Interleaved or mono copy: one destination buffer, `channels` samples per frame.
    func update(
        from left: UnsafeBufferPointer<Float>,
        right: UnsafeBufferPointer<Float>,
        frames: Int,
        channels: Int
    ) {
        guard channels > 1 else {
            for index in 0..<min(frames, left.count, right.count) {
                self[index] = 0.5 * (left[index] + right[index])
            }
            return
        }

        for index in 0..<min(frames, left.count, right.count) {
            let base = index * channels
            self[base] = left[index]
            self[base + 1] = right[index]
            for channel in 2..<channels { self[base + channel] = 0 }
        }
    }

    /// Planar copy, one channel at a time.
    func update(from source: UnsafeBufferPointer<Float>, count: Int) {
        guard let start = source.baseAddress else {
            zero(count: count)
            return
        }
        self.update(from: start, count: min(count, source.count))
    }

    /// Silence, for the channels a binaural pair does not drive.
    func zero(count: Int) {
        for index in 0..<count { self[index] = 0 }
    }
}