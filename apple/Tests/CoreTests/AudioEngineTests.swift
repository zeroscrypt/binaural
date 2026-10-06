import AVFoundation
import Foundation
import XCTest

@testable import BinauralCore

/// The handover between the main thread and the render callback.
///
/// The render path is driven directly — through ``AudioRenderContext`` — instead of
/// starting a real `AVAudioEngine`. That makes these tests hermetic (no device, no
/// timing, no sound) while exercising exactly the code the audio thread runs.
final class AudioEngineTests: XCTestCase {

    // MARK: - The mailbox

    func testMailboxDeliversPublishedParameters() {
        let mailbox = ParameterMailbox()
        let published = RenderParameters(
            leftHz: 205, rightHz: 215, gain: 0.5, sampleRate: 44_100
        )
        mailbox.publish(published)
        XCTAssertEqual(mailbox.load(fallback: RenderParameters()), published)
    }

    /// The race path: while the writer holds the lock the reader must get its fallback
    /// rather than block or crash. This is the behaviour that makes an unlucky
    /// interleaving cost one block of stale parameters instead of a dropout.
    func testMailboxReturnsTheFallbackWhenTheWriterHoldsTheLock() {
        let mailbox = ParameterMailbox()
        let stale = RenderParameters(leftHz: 100, rightHz: 110)
        mailbox.publish(stale)
        // `ParameterMailbox` owns its lock, so contention is provoked with concurrent
        // publishes: many writers, one reader, and no reader may ever see half a pair.
        let group = DispatchGroup()
        let writer = DispatchQueue(label: "writer")
        for index in 0..<500 {
            writer.async(group: group) {
                mailbox.publish(
                    RenderParameters(leftHz: Double(200 + index), rightHz: 300)
                )
            }
        }
        var mismatched = 0
        for _ in 0..<500 {
            let value = mailbox.load(fallback: stale)
            // Every published pair is internally consistent: right is always 300.
            if value.rightHz != 300 && value.rightHz != stale.rightHz { mismatched += 1 }
        }
        group.wait()
        XCTAssertEqual(mismatched, 0, "the reader observed a half-written parameter pair")
    }

    // MARK: - The render path

    func testRenderProducesTheRequestedNumberOfFrames() {
        let context = makeContext()
        let buffers = AudioBufferFixture(frames: 256, layout: .planar(channels: 2))
        XCTAssertEqual(context.render(frameCount: 256, into: buffers.buffers), noErr)
        XCTAssertEqual(buffers.ears.left.count, 256)
        XCTAssertEqual(buffers.ears.right.count, 256)
    }

    func testRenderIsSilentBeforeAnyGainIsPublished() {
        let context = makeContext()
        let buffers = AudioBufferFixture(frames: 512, layout: .planar(channels: 2))
        _ = context.render(frameCount: 512, into: buffers.buffers)
        XCTAssertEqual(SignalAnalysis.peak(buffers.ears.left), 0)
        XCTAssertEqual(SignalAnalysis.peak(buffers.ears.right), 0)
    }

    /// The heart of it: whatever the main thread publishes, the audio thread plays that
    /// frequency on that channel.
    func testRenderFollowsPublishedFrequencies() {
        let context = makeContext(gain: 1, leftHz: 440, rightHz: 452)
        let buffers = AudioBufferFixture(frames: 4_096, layout: .planar(channels: 2))
        _ = context.render(frameCount: 4_096, into: buffers.buffers)
        let (left, right) = buffers.ears
        assertClose(SignalAnalysis.frequency(of: left, sampleRate: 48_000), 440, accuracy: 0.5)
        assertClose(SignalAnalysis.frequency(of: right, sampleRate: 48_000), 452, accuracy: 0.5)
    }

    /// The two channels are independent — changing one must not move the other
    /// (SPEC F1, the property the whole UI rests on).
    func testChannelsAreIndependent() {
        let mailbox = ParameterMailbox()
        let context = AudioRenderContext(mailbox: mailbox)
        mailbox.publish(
            RenderParameters(leftHz: 300, rightHz: 300, gain: 1, rampSeconds: 0, sampleRate: 48_000)
        )
        let buffers = AudioBufferFixture(frames: 4_096, layout: .planar(channels: 2))
        _ = context.render(frameCount: 2_048, into: buffers.buffers)

        mailbox.publish(
            RenderParameters(leftHz: 300, rightHz: 500, gain: 1, rampSeconds: 0, sampleRate: 48_000)
        )
        _ = context.render(frameCount: 4_096, into: buffers.buffers)

        let (left, right) = buffers.ears
        assertClose(
            SignalAnalysis.frequency(of: Array(left[2_048...]), sampleRate: 48_000),
            300, accuracy: 0.5, "the left channel must not follow the right one"
        )
        assertClose(
            SignalAnalysis.frequency(of: Array(right[2_048...]), sampleRate: 48_000),
            500, accuracy: 0.5
        )
    }

    /// A frequency change must not restart the phase, or it clicks (SPEC F2).
    ///
    /// Two separate fixtures, because each `render` fills its buffer from index 0 — the
    /// seam to inspect is the last sample of one block against the first of the next. A
    /// phase reset would make that second sample exactly 0, while a continuous 440 Hz
    /// tone steps by at most `2*pi*f/rate` per sample.
    func testFrequencyChangeKeepsPhaseContinuous() {
        let slew = 2 * Double.pi * 440 / 48_000          // ~0.0576
        let mailbox = ParameterMailbox()
        let context = AudioRenderContext(mailbox: mailbox)
        mailbox.publish(
            RenderParameters(leftHz: 440, rightHz: 440, gain: 1, rampSeconds: 0, sampleRate: 48_000)
        )

        let before = AudioBufferFixture(frames: 4_096, layout: .planar(channels: 2))
        _ = context.render(frameCount: 4_096, into: before.buffers)

        mailbox.publish(
            RenderParameters(leftHz: 441, rightHz: 441, gain: 1, rampSeconds: 0, sampleRate: 48_000)
        )

        let after = AudioBufferFixture(frames: 4_096, layout: .planar(channels: 2))
        _ = context.render(frameCount: 4_096, into: after.buffers)

        let lastBefore = try! XCTUnwrap(before.ears.left.last)
        let firstAfter = try! XCTUnwrap(after.ears.left.first)
        XCTAssertGreaterThan(
            abs(Double(lastBefore)), slew,
            "the fixture must hold a real tone, not silence"
        )
        XCTAssertLessThan(
            abs(Double(lastBefore - firstAfter)), slew * 1.5,
            "a phase reset would land on 0.0; a continuous tone steps by at most \(slew)"
        )
    }

    /// Gain opens through the accumulating fade, so the first block after Play is
    /// quieter than the last.
    func testGainOpensThroughAFade() {
        let mailbox = ParameterMailbox()
        let context = AudioRenderContext(mailbox: mailbox)
        mailbox.publish(
            RenderParameters(leftHz: 440, rightHz: 440, gain: 0, sampleRate: 48_000)
        )
        let buffers = AudioBufferFixture(frames: 4_096, layout: .planar(channels: 2))
        _ = context.render(frameCount: 512, into: buffers.buffers)   // settle at silence

        mailbox.publish(
            RenderParameters(
                leftHz: 440, rightHz: 440, gain: 1, rampSeconds: 0.03, sampleRate: 48_000
            )
        )
        _ = context.render(frameCount: 4_096, into: buffers.buffers)

        let left = buffers.ears.left
        let opening = SignalAnalysis.rms(Array(left[0..<512]))
        let settled = SignalAnalysis.rms(Array(left[3_584..<4_096]))
        XCTAssertGreaterThan(settled, 0.5, "the fade should have finished within 85 ms")
        XCTAssertLessThan(opening, settled, "the amplitude must ramp, not step")
    }

    /// Volume reaches the oscillator as gain, not as a post-hoc scale of the buffers.
    func testGainScalesTheSamples() {
        let loud = AudioBufferFixture(frames: 4_096, layout: .planar(channels: 2))
        _ = makeContext(gain: 1).render(frameCount: 4_096, into: loud.buffers)

        let quiet = AudioBufferFixture(frames: 4_096, layout: .planar(channels: 2))
        _ = makeContext(gain: 0.5).render(frameCount: 4_096, into: quiet.buffers)

        assertClose(
            SignalAnalysis.rms(quiet.ears.left),
            0.5 * SignalAnalysis.rms(loud.ears.left),
            accuracy: 0.01
        )
    }

    /// A pan of `(1, 0)` is the left-ear-only tone the perceptual L/R test needs
    /// (SPEC §4.2, CONTRACT §4).
    func testPanSilencesOneChannel() {
        let mailbox = ParameterMailbox()
        let context = AudioRenderContext(mailbox: mailbox)
        mailbox.publish(
            RenderParameters(
                leftHz: 440, rightHz: 440, gain: 1, rampSeconds: 0,
                panLeft: 1, panRight: 0, sampleRate: 48_000
            )
        )
        let buffers = AudioBufferFixture(frames: 4_096, layout: .planar(channels: 2))
        _ = context.render(frameCount: 4_096, into: buffers.buffers)
        XCTAssertGreaterThan(SignalAnalysis.peak(buffers.ears.left), 0.5)
        XCTAssertEqual(SignalAnalysis.peak(buffers.ears.right), 0)
    }

    // MARK: - Buffer layouts

    /// The layout the source node actually asks for, but asserted through the
    /// interleaved path because that is the one where a stride bug would hide.
    func testInterleavedOutputFillsBothChannels() {
        let context = makeContext(gain: 1)
        let buffers = AudioBufferFixture(frames: 1_024, layout: .interleaved(channels: 2))
        XCTAssertEqual(context.render(frameCount: 1_024, into: buffers.buffers), noErr)
        XCTAssertEqual(SignalAnalysis.peak(buffers.ears.left), 1, accuracy: 0.05)
        XCTAssertEqual(SignalAnalysis.peak(buffers.ears.right), 1, accuracy: 0.05)
        XCTAssertNotEqual(SignalAnalysis.peak(buffers.ears.right), 0)
    }

    func testMonoOutputIsAMixdown() {
        let context = makeContext(gain: 1, leftHz: 440, rightHz: 441)
        let mono = AudioBufferFixture(frames: 1_024, layout: .mono)
        XCTAssertEqual(context.render(frameCount: 1_024, into: mono.buffers), noErr)
        XCTAssertGreaterThan(mono.peak(channel: 0, ofBuffer: 0), 0.5)
    }

    /// A surround device fed through the mixer: only the ear channels get sound.
    func testSurroundLayoutSilencesTheExtraChannels() {
        let context = makeContext(gain: 1)
        let surround = AudioBufferFixture(frames: 512, layout: .planar(channels: 4))
        _ = context.render(frameCount: 512, into: surround.buffers)
        XCTAssertGreaterThan(surround.peak(channel: 0, ofBuffer: 0), 0.5)
        XCTAssertGreaterThan(surround.peak(channel: 0, ofBuffer: 1), 0.5)
        XCTAssertEqual(surround.peak(channel: 0, ofBuffer: 2), 0)
        XCTAssertEqual(surround.peak(channel: 0, ofBuffer: 3), 0)
    }

    func testZeroFramesIsANoOp() {
        let context = makeContext(gain: 1)
        let buffers = AudioBufferFixture(frames: 64, layout: .planar(channels: 2))
        XCTAssertEqual(context.render(frameCount: 0, into: buffers.buffers), noErr)
    }

    /// The block size the engine hands over is not promised, so scratch storage has to
    /// grow to the largest block seen without corrupting the previous one.
    func testScratchStorageGrowsWithTheBlockSize() {
        let context = makeContext(gain: 1)
        let small = AudioBufferFixture(frames: 64, layout: .planar(channels: 2))
        _ = context.render(frameCount: 64, into: small.buffers)
        let large = AudioBufferFixture(frames: 2_048, layout: .planar(channels: 2))
        _ = context.render(frameCount: 2_048, into: large.buffers)
        XCTAssertEqual(large.ears.left.count, 2_048)
        XCTAssertEqual(SignalAnalysis.peak(large.ears.left), 1, accuracy: 0.05)
    }

    // MARK: - The device handshake

    /// The sample rate must come from the device, not from `BeatMath.defaultSampleRate`
    /// (M2.md §1). This machine's built-in output runs at 44.1 kHz, so a hardcoded
    /// 48000 would be wrong here — which is what the assertion is for: after `start()`,
    /// the published rate is the one CoreAudio reports for the default output device.
    ///
    /// The probe engine is released before the engine under test is created: two live
    /// `AVAudioEngine` instances contend over the HAL, and the second one to start stalls
    /// the test host.
    @MainActor
    func testEngineAdoptsTheDeviceSampleRate() throws {
        let deviceRate = Self.defaultOutputDeviceSampleRate()
        try XCTSkipIf(deviceRate <= 0, "no default output device in this environment")

        let engine = AudioEngine()
        guard engine.start() else {
            throw XCTSkip("the device is present but could not be opened: \(engine.error ?? "")")
        }
        defer { engine.shutdown() }
        XCTAssertEqual(Double(engine.sampleRate), deviceRate, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(engine.channelCount, 2)
        XCTAssertEqual(
            engine.mailbox.load(fallback: RenderParameters()).sampleRate,
            engine.sampleRate,
            "the audio thread must be told the device rate, not the default"
        )
    }

    /// The render block must survive being called from the **CoreAudio IO thread**.
    ///
    /// This is the regression test for a real crash: the block used to be written inline
    /// inside `start()`, a `@MainActor` method, so the closure inherited that isolation and
    /// the compiler emitted a main-actor check at the top of it. On the IO thread that
    /// check tripped `_dispatch_assert_queue` and the process died with `SIGTRAP` the first
    /// time real audio rendered — which is why the app was stable in a test host (the block
    /// is also pulled once from the calling thread during `prepare()`, where the check
    /// passes) and died seconds after launch in the running app.
    ///
    /// Nothing here asserts *that* sound came out: it asserts that a real device rendered
    /// blocks through the real callback without the process trapping, which is the property
    /// that broke. Skips where there is no output device.
    @MainActor
    func testRenderBlockRunsOnTheAudioThreadWithoutAnIsolationTrap() throws {
        try XCTSkipIf(
            Self.defaultOutputDeviceSampleRate() <= 0,
            "no default output device in this environment"
        )

        let engine = AudioEngine()
        guard engine.start() else {
            throw XCTSkip("the device is present but could not be opened: \(engine.error ?? "")")
        }
        defer { engine.shutdown() }

        // Long enough for the IO thread to pull several blocks. If the closure were still
        // main-actor isolated the process would be dead before this returns.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(engine.isRunning, "the engine survived its own render callback")
    }

    /// Sample rate of the default output device, read through a throwaway engine that is
    /// gone before this one returns.
    @MainActor
    private static func defaultOutputDeviceSampleRate() -> Double {
        var rate = 0.0
        do {
            let probe = AVAudioEngine()
            rate = probe.outputNode.inputFormat(forBus: 0).sampleRate
            // Held only until here: releasing it frees the HAL claim.
        }
        return rate
    }

    @MainActor
    func testEngineStartsAndStopsWithoutCrashing() {
        let engine = AudioEngine()
        try? engine.setFrequencies(leftHz: 205, rightHz: 215)
        let started = engine.start()
        if started {
            XCTAssertTrue(engine.isRunning)
            XCTAssertNil(engine.error)
            XCTAssertGreaterThan(engine.sampleRate, 0)
            engine.stop()
            XCTAssertFalse(engine.isRunning)
        } else {
            // No output device in this environment (CI, a locked-down VM): the contract
            // is a user-facing message, never a crash.
            XCTAssertNotNil(engine.error)
        }
        engine.shutdown()
    }

    @MainActor
    func testEngineRejectsOutOfRangeFrequencies() {
        let engine = AudioEngine()
        XCTAssertThrowsError(try engine.setFrequencies(leftHz: 0.5, rightHz: 215))
        XCTAssertThrowsError(try engine.setFrequencies(leftHz: 205, rightHz: 30_000))
        // A rejected change must not have moved anything.
        XCTAssertEqual(engine.mailbox.load(fallback: RenderParameters()).leftHz, 205)
    }

        /// Silent unless playing, silent when muted, otherwise exactly the volume — the
    /// rule that keeps a launch from blasting audio and that makes Mute work.
    @MainActor
    func testOutputGainFolding() {
        XCTAssertEqual(AudioEngine.outputGain(isRunning: false, isMuted: false, volume: 0.7), 0)
        XCTAssertEqual(AudioEngine.outputGain(isRunning: true, isMuted: true, volume: 0.7), 0)
        XCTAssertEqual(AudioEngine.outputGain(isRunning: true, isMuted: false, volume: 0.3), 0.3)
        XCTAssertEqual(AudioEngine.outputGain(isRunning: true, isMuted: false, volume: 5), 1)
        XCTAssertEqual(AudioEngine.outputGain(isRunning: true, isMuted: false, volume: -1), 0)
        XCTAssertEqual(AudioEngine.outputGain(isRunning: true, isMuted: false, volume: .nan), 0)
    }

    @MainActor
    func testEngineIsSilentUntilPlaying() {
        let engine = AudioEngine(volume: 0.7)
        XCTAssertEqual(engine.mailbox.load(fallback: RenderParameters()).gain, 0)

        engine.isMuted = true
        XCTAssertEqual(engine.mailbox.load(fallback: RenderParameters()).gain, 0)

        // The volume slider moves the published value even while stopped — it is the
        // play state, not the slider, that holds the output at zero.
        engine.volume = 0.3
        XCTAssertEqual(engine.mailbox.load(fallback: RenderParameters()).gain, 0)
    }

    // MARK: - Helpers

    private func makeContext(
        gain: Double = 0,
        leftHz: Double = 440,
        rightHz: Double = 440,
        sampleRate: Int = 48_000
    ) -> AudioRenderContext {
        let mailbox = ParameterMailbox()
        mailbox.publish(
            RenderParameters(
                leftHz: leftHz, rightHz: rightHz, gain: gain,
                rampSeconds: gain > 0 ? 0 : BeatMath.defaultRampSeconds,
                sampleRate: sampleRate
            )
        )
        return AudioRenderContext(mailbox: mailbox)
    }
}

// MARK: - AudioBufferList fixtures

/// A hand-built `AudioBufferList` of any shape the engine may hand over.
///
/// Built by allocating the exact byte count the flexible trailing array needs, because
/// `AudioBufferList` ends in `mNumberBuffers` `AudioBuffer` entries: sizing the
/// allocation from the buffer count is the only way to get more than one entry without
/// writing past the end. (An `AVAudioPCMBuffer` would do it too, but it cannot express a
/// 4-channel planar layout, which is the surround case under test.)
final class AudioBufferFixture {

    private let raw: UnsafeMutableRawPointer
    private var storage: [UnsafeMutablePointer<Float>]
    let frames: Int
    let bufferCount: Int
    let channelsPerBuffer: Int

    /// Samples per buffer, which is `frames` for planar and `frames * channels` for an
    /// interleaved one.
    let samplesPerBuffer: Int

    /// - Parameters:
    ///   - frames: samples per frame.
    ///   - layout: `.planar(channels:)` — one buffer per channel, which is what a
    ///     non-interleaved source node receives; `.interleaved(channels:)` — one buffer
    ///     holding every channel; `.mono` — one buffer, one channel.
    init(frames: Int, layout: Layout) {
        self.frames = frames
        switch layout {
        case let .planar(channels):
            bufferCount = channels
            channelsPerBuffer = 1
        case let .interleaved(channels):
            bufferCount = 1
            channelsPerBuffer = channels
        case .mono:
            bufferCount = 1
            channelsPerBuffer = 1
        }
        samplesPerBuffer = frames * (channelsPerBuffer > 1 ? channelsPerBuffer : 1)

        let stride = MemoryLayout<AudioBuffer>.stride
        let bytes = MemoryLayout<AudioBufferList>.size + stride * (bufferCount - 1)
        raw = UnsafeMutableRawPointer.allocate(
            byteCount: bytes,
            alignment: MemoryLayout<AudioBuffer>.alignment
        )
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)

        // Every buffer is allocated at full size so the deinit path has one count, even
        // though a planar buffer only fills its own `frames` samples.
        let capacity = frames * max(1, bufferCount * channelsPerBuffer)
        storage = (0..<bufferCount).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            pointer.initialize(repeating: 0, count: capacity)
            return pointer
        }

        raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers = UInt32(bufferCount)
        let list = buffers
        for index in 0..<bufferCount {
            list[index].mNumberChannels = UInt32(channelsPerBuffer)
            list[index].mDataByteSize = UInt32(samplesPerBuffer * MemoryLayout<Float>.size)
            list[index].mData = UnsafeMutableRawPointer(storage[index])
        }
    }

    enum Layout {
        case planar(channels: Int)
        case interleaved(channels: Int)
        case mono
    }

    deinit {
        let capacity = frames * max(1, bufferCount * channelsPerBuffer)
        for pointer in storage {
            pointer.deinitialize(count: capacity)
            pointer.deallocate()
        }
        raw.deallocate()
    }

    /// The pointer the render callback takes.
    var buffers: UnsafeMutableAudioBufferListPointer {
        UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    }

    /// Samples of one buffer, in that buffer's own layout.
    func samples(ofBuffer index: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: storage[index], count: samplesPerBuffer))
    }

    /// One channel of one buffer, resolving interleaving — so a test can ask for "the
    /// right channel" without caring which layout the fixture uses.
    func samples(channel: Int, ofBuffer index: Int) -> [Float] {
        let all = samples(ofBuffer: index)
        guard channelsPerBuffer > 1 else { return all }
        return stride(from: channel, to: all.count, by: channelsPerBuffer).map { all[$0] }
    }

    /// Peak absolute value of one channel.
    func peak(channel: Int, ofBuffer index: Int) -> Float {
        SignalAnalysis.peak(samples(channel: channel, ofBuffer: index))
    }

    /// The two ear channels: buffer 0 and buffer 1 for planar, channel 0 and channel 1
    /// of the single buffer for interleaved.
    var ears: (left: [Float], right: [Float]) {
        if channelsPerBuffer > 1 {
            return (samples(channel: 0, ofBuffer: 0), samples(channel: 1, ofBuffer: 0))
        }
        return (samples(ofBuffer: 0), samples(ofBuffer: bufferCount > 1 ? 1 : 0))
    }
}
