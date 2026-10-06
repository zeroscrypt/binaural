import AVFoundation
import Foundation

/// Plays the perceptual L/R test's tones (SPEC §4.2) on an ``AudioEngine``.
///
/// Port of what `LrTestDialog` asks of `core.engine.AudioEngine` in Python: hard-pan one
/// channel, play a short tone, restore. The hook it uses is M1's `StereoOscillator.setPan`
/// as reached through ``AudioEngine/setPan(left:right:)`` — nothing about the handover
/// changes: `panLeft`/`panRight` are two `Double`s in ``RenderParameters``, published the
/// same way as the frequencies, read once per block without ever blocking.
///
/// **Why this is not a second audio path.** `AudioEngine` already owns one oscillator, one
/// `AVAudioSourceNode` and one running graph, and tearing that down to play a test tone
/// would restart the phase — exactly the discontinuity SPEC F2 rules out. So the test tone
/// is the *same* graph with three values changed: both frequencies to 440 Hz, the pan
/// hard to one side, and the engine started if it was not. When the test ends the previous
/// frequencies, the previous pan and the previous play state are put back.
///
/// **It never throws and never traps.** A machine with no output device, a HAL that
/// refuses the format, an engine that will not start: every one of those degrades to "no
/// sound and an ``error`` string the dialog can show" (the rule `lr_test.py` states as
/// "a missing or broken engine never crashes the test").
@MainActor
public final class LRTonePlayer: LRTestTonePlaying {

    /// The engine the test plays through. Weak-free and not owned: the app's engine outlives
    /// any dialog, and a dialog that outlives its window must not keep a dead engine alive.
    private let engine: AudioEngine

    /// Frequencies, pan and play state as they were before the test, restored on silence.
    ///
    /// Held rather than read back from the engine because the engine has no getters for
    /// them, and because "restore what was there" is the only behaviour that cannot go
    /// wrong when the user starts the test halfway through a session.
    private var saved: SavedState?

    /// What to put back when the test ends.
    typealias SavedState = (
        left: Double, right: Double,
        pan: (left: Double, right: Double),
        wasRunning: Bool
    )
    /// What the engine refused, for the dialog to show as words. English catalogue key, so
    /// the dialog translates it at display time like every other engine message.
    public private(set) var error: String?

    public init(engine: AudioEngine) {
        self.engine = engine
    }

    /// True while a test tone is playing, and the user has not silenced it.
    public var isPlayingTone: Bool { saved != nil }

    // MARK: - LRTestTonePlaying

    /// Play `frequencyHz` in one ear only, hard-panned (SPEC §4.2 step 1 and 3).
    public func playTestTone(channel: LRTestChannel, frequencyHz: Double) {
        silenceTestTone()   // a second `begin()` is a no-op, not a double start
        error = nil

        let hz = frequencyHz.isFinite && frequencyHz > 0 ? frequencyHz : 440
        let frequencies = engine.currentFrequencies
        saved = (
            left: frequencies.left,
            right: frequencies.right,
            pan: engine.currentPan,
            wasRunning: engine.isRunning
        )

        // Both oscillators at the same frequency: with one side silenced there is no beat,
        // which is what makes the test tone a *channel* test and not a tone-pair test.
        try? engine.setFrequencies(leftHz: hz, rightHz: hz)
        switch channel {
        case .left: engine.setPan(left: 1, right: 0)
        case .right: engine.setPan(left: 0, right: 1)
        }

        if !engine.start() {
            error = engine.error
            restoreWithoutSound()
        }
    }

    /// Stop the tone and put the session back the way it was.
    public func silenceTestTone() {
        guard let previous = saved else { return }
        saved = nil
        restore(previous)
    }

    // MARK: - Restore

    /// Undo the pan and the frequencies but keep the engine running: the fade of a stopped
    /// engine is not what is wanted mid-test, and `stop()` would only ramp the gain.
    private func restoreWithoutSound() {
        guard let previous = saved else { return }
        saved = nil
        apply(previous)
        // The engine refused the format, so there is nothing to fade: stopping it here
        // only releases a graph that never produced a sample.
        if !previous.wasRunning { engine.stop() }
    }

    private func restore(_ previous: SavedState) {
        apply(previous)
        // Only stop what this player started. A session that was already playing must keep
        // playing — silently pausing someone's binaural tone because they answered a
        // question would be worse than anything the test itself could do.
        if !previous.wasRunning { engine.stop() }
    }

    private func apply(_ previous: SavedState) {
        try? engine.setFrequencies(leftHz: previous.left, rightHz: previous.right)
        engine.setPan(left: previous.pan.left, right: previous.pan.right)
    }
}

/// The main-thread schedule `LrTestSequence` is driven with.
///
/// `DispatchQueue.main.asyncAfter` rather than `Timer`: the sequence only needs "after this
/// many seconds, on the main thread", and a `Timer` would keep firing into a dialog that
/// has already gone. The canceller is a dispatch work item, so cancelling a pending step is
/// **exact** — no "the timer may still fire once more" window, which for a *tone* would mean
/// a tone outliving the dialog that asked the question about it.
///
/// The work is a plain `@escaping () -> Void`, exactly ``LrTestSequence/Schedule``'s type:
/// it is `@MainActor` at the call site in both cases, and demanding `@Sendable` as well
/// would only make every caller annotate a closure that provably never leaves the main
/// thread.
@MainActor
public enum MainQueueSchedule {

    /// The signature ``LrTestSequence/Schedule`` expects.
    public static func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return { item.cancel() }
    }
}