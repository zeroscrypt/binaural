import Foundation

/// The answer to SPEC §4.2's question, "what did you hear?".
public enum LRTestResult: String, CaseIterable, Sendable {
    /// Left then right: headphones, channels correct.
    case leftThenRight = "left_then_right"
    /// Right then left: headphones, **channels swapped** — the app must swap them.
    case rightThenLeft = "right_then_left"
    /// Both at once, or nothing to tell: speakers or a mono mixer.
    case indeterminate = "indeterminate"

    /// Lenient parsing, like Python's `_coerce`: anything unusable is
    /// ``indeterminate``, because "I did not understand" must never be read as "it is
    /// fine".
    public init(lenient raw: String) {
        self = LRTestResult(rawValue: raw) ?? .indeterminate
    }
}

/// What the check concluded (CONTRACT §4, `HeadphoneReport`).
public struct HeadphoneReport: Sendable, Equatable {

    /// The heuristic verdict, possibly revised by the perceptual test.
    public let verdict: DeviceClass
    /// The device the verdict is about, `nil` when nothing was readable.
    public let device: AudioDevice?
    public let confidence: DetectionConfidence
    /// The user's answer to the L/R test, `nil` when it was not run.
    public let lrTest: LRTestResult?

    public init(
        verdict: DeviceClass,
        device: AudioDevice?,
        confidence: DetectionConfidence,
        lrTest: LRTestResult? = nil
    ) {
        self.verdict = verdict
        self.device = device
        self.confidence = confidence
        self.lrTest = lrTest
    }

    /// The report to start from: nothing known, nothing to prove.
    public static let unknown = HeadphoneReport(
        verdict: .unknown,
        device: nil,
        confidence: .low
    )

    /// Are these headphones? The heuristic says so, or the user heard them.
    public var isHeadphones: Bool {
        verdict == .headphones
            || lrTest == .leftThenRight
            || lrTest == .rightThenLeft
    }

    /// True when the L/R test proved the channels are swapped and the generator has to
    /// swap them (SPEC §4.2).
    public var channelsSwapped: Bool { lrTest == .rightThenLeft }

    /// The device name, or `""` when nothing was readable.
    public var deviceName: String { device?.name ?? "" }
}

/// The headphone check as a whole — the Swift half of `binaural.audio.headphones`.
///
/// Level 1 is ``detect(previous:)``: heuristics only, no sound, no questions. Level 2 is
/// ``LrTestSequence``, which is what settles a report the heuristic was unsure about.
///
/// Nothing here throws and nothing here talks to a specific platform: the backend is
/// injected, which is what makes the whole scenario testable without audio hardware.
public enum HeadphoneDetector {

    /// Run the heuristic for the default output device.
    ///
    /// - Parameter previous: a stored or earlier report. Its L/R answer is carried over
    ///   and re-applied to the fresh verdict, so switching devices does not lose a test
    ///   the user already did.
    public static func detect(
        backend: any AudioDeviceBackend = AudioDevices.makeBackend(),
        previous: HeadphoneReport? = nil
    ) -> HeadphoneReport {
        let verdictAndDevice = backend.heuristicVerdict()
        let device = verdictAndDevice.device

        let confidence: DetectionConfidence
        if verdictAndDevice.verdict != .unknown, device != nil {
            confidence = DeviceHeuristics.confidence(name: device?.name, transport: device?.transport)
        } else {
            confidence = .low
        }

        let fresh = HeadphoneReport(
            verdict: verdictAndDevice.verdict,
            device: device,
            confidence: confidence,
            lrTest: previous?.lrTest
        )
        guard let lrTest = previous?.lrTest else { return fresh }
        return applying(lrTest, to: fresh)
    }

    /// Fold a perceptual answer into a report. The test is **definitive**: it outranks
    /// the heuristic in both directions (SPEC §4.2).
    public static func applying(
        _ result: LRTestResult,
        to report: HeadphoneReport
    ) -> HeadphoneReport {
        let verdict: DeviceClass
        let confidence: DetectionConfidence
        switch result {
        case .indeterminate:
            // "Both at once" is a positive answer for speakers: it beats a name or
            // transport hint.
            verdict = report.verdict == .headphones ? .speakers : report.verdict
            confidence = report.verdict == .headphones ? .high : report.confidence
        case .leftThenRight, .rightThenLeft:
            // The user heard one ear at a time — headphones, whatever the name said.
            verdict = .headphones
            confidence = .high
        }
        return HeadphoneReport(
            verdict: verdict,
            device: report.device,
            confidence: confidence,
            lrTest: result
        )
    }

    /// The report updated with the user's answer, ready to be shown.
    public static func withLRResult(
        _ result: LRTestResult,
        in report: HeadphoneReport
    ) -> HeadphoneReport {
        applying(result, to: report)
    }

    /// Apply the swap decision to a frequency pair (SPEC §4.2).
    ///
    /// Only the *generator* swaps. The window keeps showing what the user asked for, and
    /// the session keeps the unswapped numbers, so the stored document is readable
    /// without knowing the user's hardware.
    public static func swapChannels(
        leftHz: Double,
        rightHz: Double,
        swapped: Bool
    ) -> (left: Double, right: Double) {
        swapped ? (rightHz, leftHz) : (leftHz, rightHz)
    }
}

/// Which ear a test tone goes to (SPEC §4.2).
public enum LRTestChannel: String, Sendable {
    case left
    case right
}

/// What the sequence needs from the audio side.
///
/// Deliberately tiny: the dialog owns the *question* and the sequence owns the
/// *timing*, while the engine owns the sound. A missing or broken engine must not crash
/// the test, so every call site is `try?`-shaped on the shell side.
public protocol LRTestTonePlaying: AnyObject {
    /// Play one channel only, hard-panned, at `frequencyHz`.
    func playTestTone(channel: LRTestChannel, frequencyHz: Double)
    /// Stop the test tone and restore full stereo.
    func silenceTestTone()
}

/// One step of the perceptual test — Python's `STEP_*` constants, typed.
public enum LRTestStep: String, CaseIterable, Sendable {
    case idle
    case left
    case pause
    case right
    case answer
}

/// The timing of the perceptual test (SPEC §4.2). Values are Python's.
public struct LRTestTiming: Sendable, Equatable {

    public static let standard = LRTestTiming(
        frequencyHz: 440,
        toneSeconds: 1.5,
        gapSeconds: 0.3
    )

    public let frequencyHz: Double
    public let toneSeconds: Double
    public let gapSeconds: Double

    public init(frequencyHz: Double = 440, toneSeconds: Double = 1.5, gapSeconds: Double = 0.3) {
        self.frequencyHz = frequencyHz
        self.toneSeconds = max(0.01, toneSeconds.isFinite ? toneSeconds : 1.5)
        self.gapSeconds = max(0.01, gapSeconds.isFinite ? gapSeconds : 0.3)
    }
}

/// Drives the perceptual L/R test and holds its state — port of
/// `binaural.audio.headphones.LrTestSequence`.
///
/// `left tone → pause → right tone → question`, exactly as SPEC §4.2 tabulates it. The
/// *answer* is collected by the UI and handed back through ``answer(_:)``; this type
/// never asks anything itself.
///
/// Scheduling is injected. The app schedules on the main queue; the tests schedule by
/// hand, so the sequence can be stepped through without a run loop and without a
/// millisecond of real time.
///
/// Main-actor isolated, like everything that drives an engine: the player calls are main
/// thread only, which is also what `AudioEngine` requires.
@MainActor
public final class LrTestSequence {

    /// Called whenever the step changes, so the dialog can re-read its status line.
    public var onStepChanged: ((LRTestStep) -> Void)?
    /// Called once when the user answers.
    public var onFinished: ((LRTestResult) -> Void)?

    /// Schedules `work` after `delay` seconds and returns a canceller.
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void

    public let timing: LRTestTiming

    private let player: LRTestTonePlaying
    private let schedule: Schedule
    private var cancelPending: (() -> Void)?
    private var stepValue: LRTestStep = .idle
    private var resultValue: LRTestResult?

    public init(
        player: LRTestTonePlaying,
        timing: LRTestTiming = .standard,
        schedule: @escaping Schedule
    ) {
        self.player = player
        self.timing = timing
        self.schedule = schedule
    }

    public var step: LRTestStep { stepValue }
    public var result: LRTestResult? { resultValue }

    /// Start the sequence. Does nothing while one is already running, exactly like the
    /// Python `begin()`.
    public func begin() {
        guard stepValue == .idle || stepValue == .answer else { return }
        resultValue = nil
        play(channel: .left)
        goto(.left)
        after(timing.toneSeconds) { [weak self] in self?.afterLeft() }
    }

    /// Feed the answer in. Accepted at any point: a click that arrives before the
    /// question is asked must not be lost.
    @discardableResult
    public func answer(_ result: LRTestResult) -> LRTestResult {
        resultValue = result
        cancelPendingWork()
        player.silenceTestTone()
        goto(.idle)
        onFinished?(result)
        return result
    }

    /// Abort playback and return to idle. Safe to call repeatedly, and always safe to
    /// call — the dialog does it when it closes, so no tone can outlive it.
    public func stop() {
        cancelPendingWork()
        player.silenceTestTone()
        goto(.idle)
    }

    // MARK: - Flow

    private func afterLeft() {
        guard stepValue == .left else { return }
        player.silenceTestTone()
        goto(.pause)
        after(timing.gapSeconds) { [weak self] in self?.afterPause() }
    }

    private func afterPause() {
        guard stepValue == .pause else { return }
        play(channel: .right)
        goto(.right)
        after(timing.toneSeconds) { [weak self] in self?.ask() }
    }

    private func ask() {
        guard stepValue == .right else { return }
        player.silenceTestTone()
        goto(.answer)
    }

    private func play(channel: LRTestChannel) {
        player.playTestTone(channel: channel, frequencyHz: timing.frequencyHz)
    }

    private func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        cancelPendingWork()
        cancelPending = schedule(delay, work)
    }

    private func cancelPendingWork() {
        cancelPending?()
        cancelPending = nil
    }

    private func goto(_ step: LRTestStep) {
        guard step != stepValue else { return }
        stepValue = step
        onStepChanged?(step)
    }
}
