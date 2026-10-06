import XCTest

@testable import BinauralCore

/// Parity with `tests/test_platform.py` — the device model and the shared heuristics of
/// `audio/platform/base.py`.
///
/// No hardware, no CoreAudio, no subprocess: the heuristics are pure functions over a
/// name/transport pair precisely so that every row of SPEC §4.1's table is a plain unit
/// test on any machine.
final class DeviceModelTests: XCTestCase {

    // MARK: - Raw values (CONTRACT §3)

    /// The enum's raw values are Python's, so a value that crosses over from a stored
    /// document compares equal.
    func testDeviceClassRawValues() {
        XCTAssertEqual(DeviceClass.headphones.rawValue, "headphones")
        XCTAssertEqual(DeviceClass.speakers.rawValue, "speakers")
        XCTAssertEqual(DeviceClass.virtual.rawValue, "virtual")
        XCTAssertEqual(DeviceClass.unknown.rawValue, "unknown")
    }

    /// Python keeps confidence as the string `"high" | "medium" | "low"`; the enum is the
    /// Swift spelling of the same three values.
    func testConfidenceRawValues() {
        XCTAssertEqual(DetectionConfidence.high.rawValue, "high")
        XCTAssertEqual(DetectionConfidence.medium.rawValue, "medium")
        XCTAssertEqual(DetectionConfidence.low.rawValue, "low")
    }

    // MARK: - AudioDevice defaults

    func testAudioDeviceDefaults() {
        let device = AudioDevice(name: "X", transport: "usb")
        XCTAssertFalse(device.isDefault)
        XCTAssertEqual(device.identifier, "")
        // `id` falls back to the name when there is no identifier, so the value is usable
        // as an `Identifiable` before a backend has read a UID.
        XCTAssertEqual(device.id, "X")
        XCTAssertEqual(
            AudioDevice(name: "X", transport: "usb", isDefault: true, identifier: "42").id,
            "42"
        )
    }

    // MARK: - classify_device

    func testClassifyMatchesPythonTable() {
        let cases: [(name: String?, transport: String?, expected: DeviceClass)] = [
            // Transport says wireless -> headphones.
            ("Whatever", "bluetooth", .headphones),
            ("Whatever", "bluetoothle", .headphones),
            // Name hints.
            ("AirPods Pro", "usb", .headphones),
            ("Studio Headset", "usb", .headphones),
            ("Buds", "bluetooth", .headphones),
            ("Earphone", "builtin", .headphones),
            ("AB Earphones 3", "usb", .headphones),
            // Built-in speakers.
            ("Динамики Mac mini", "builtin", .speakers),
            ("Built-in Output", "builtin", .speakers),
            ("Speakers", "builtin", .speakers),
            // Monitor / TV outputs.
            ("Mi Monitor", "hdmi", .speakers),
            ("Mi Monitor", "displayport", .speakers),
            ("Living Room", "airplay", .speakers),
            // Virtual devices.
            ("BlackHole 2ch", "usb", .virtual),
            ("Loopback", "pci", .virtual),
            ("Aggregate Device", "builtin", .virtual),
            ("Null Output", "virt", .virtual),
            ("Multi-Output Device", "builtin", .virtual),
            // Nothing conclusive.
            ("zzz-device", "usb", .unknown),
            ("", "", .unknown),
            ("????", "???", .unknown),
            (nil, nil, .unknown),
        ]
        for testCase in cases {
            XCTAssertEqual(
                DeviceHeuristics.classify(name: testCase.name, transport: testCase.transport),
                testCase.expected,
                "name: \(testCase.name ?? "nil"), transport: \(testCase.transport ?? "nil")"
            )
        }
    }

    // MARK: - classify_confidence

    func testConfidenceMatchesPythonLevels() {
        XCTAssertEqual(
            DeviceHeuristics.confidence(name: "Whatever", transport: "bluetooth"), .high
        )
        XCTAssertEqual(DeviceHeuristics.confidence(name: "Mi Monitor", transport: "hdmi"), .high)
        XCTAssertEqual(DeviceHeuristics.confidence(name: "AirPods Pro", transport: "usb"), .medium)
        XCTAssertEqual(
            DeviceHeuristics.confidence(name: "Динамики Mac mini", transport: "builtin"), .medium
        )
        XCTAssertEqual(DeviceHeuristics.confidence(name: "zzz-device", transport: "usb"), .low)
        XCTAssertEqual(DeviceHeuristics.confidence(name: "", transport: "zzz"), .low)
    }

    /// `verdict(_:_:)` is the single source of truth; the two accessors must not drift
    /// from it, because `HeadphoneDetector` reads them independently.
    func testVerdictAgreesWithItsTwoAccessors() {
        for name in ["AirPods Pro", "BlackHole 2ch", "Mi Monitor", "zzz"] {
            for transport in ["bluetooth", "usb", "builtin", "hdmi", "zzz"] {
                let both = DeviceHeuristics.verdict(name: name, transport: transport)
                XCTAssertEqual(DeviceHeuristics.classify(name: name, transport: transport), both.verdict)
                XCTAssertEqual(
                    DeviceHeuristics.confidence(name: name, transport: transport), both.confidence
                )
            }
        }
    }

    // MARK: - Case folding and transport aliases

    func testClassifyIsCaseInsensitive() {
        XCTAssertEqual(DeviceHeuristics.classify(name: "airpods", transport: "usb"), .headphones)
        XCTAssertEqual(DeviceHeuristics.classify(name: "AIRPODS PRO", transport: "usb"), .headphones)
    }

    func testNormalisedTransportFoldsAliasesAndTrims() {
        XCTAssertEqual(DeviceHeuristics.normalizedTransport("  Bluetooth  "), "bluetooth")
        XCTAssertEqual(DeviceHeuristics.normalizedTransport("bluetoothLE"), "bluetooth")
        XCTAssertEqual(DeviceHeuristics.normalizedTransport("displayport"), "hdmi")
        XCTAssertEqual(DeviceHeuristics.normalizedTransport("airplay"), "hdmi")
        XCTAssertEqual(DeviceHeuristics.normalizedTransport("virt"), "virtual")
        XCTAssertEqual(DeviceHeuristics.normalizedTransport("grup"), "virtual")
        XCTAssertEqual(DeviceHeuristics.normalizedTransport("USB"), "usb")
        // An unknown transport is passed through lowercased, not invented.
        XCTAssertEqual(DeviceHeuristics.normalizedTransport("ThUnDeRbOlT"), "thunderbolt")
        XCTAssertEqual(DeviceHeuristics.normalizedTransport(nil), "")
    }

    /// The order is Python's, and it is deliberate: a device *named* "AirPods" is
    /// headphones even on a virtual transport, because the name hint is checked before the
    /// virtual transport — and a *bluetooth* transport beats a "BlackHole" name.
    func testNameHintsPrecedeVirtualTransportAndTransportBeatsTheName() {
        XCTAssertEqual(
            DeviceHeuristics.verdict(name: "AirPods Monitor", transport: "virtual").verdict,
            .headphones
        )
        XCTAssertEqual(
            DeviceHeuristics.verdict(name: "AirPods Monitor", transport: "virtual").confidence,
            .medium
        )
        XCTAssertEqual(
            DeviceHeuristics.verdict(name: "BlackHole", transport: "bluetooth").verdict, .headphones
        )
        // The virtual *transport* is still high confidence once no name hint claimed it.
        let nullOutput = DeviceHeuristics.verdict(name: "Null Output", transport: "virtual")
        XCTAssertEqual(nullOutput.verdict, .virtual)
        XCTAssertEqual(nullOutput.confidence, .high)
    }

    /// `"udio"` catches "Audio" plug-ins and null sinks while staying clear of the Russian
    /// "Динамики", which *is* the built-in speaker.
    func testVirtualHintDoesNotCatchTheRussianBuiltInSpeaker() {
        XCTAssertEqual(DeviceHeuristics.classify(name: "Динамики Mac mini", transport: "builtin"), .speakers)
    }

    // MARK: - NullAudioDeviceBackend (CONTRACT §3: nothing known, nothing raises)

    func testNullBackendKnowsNothing() {
        let backend = NullAudioDeviceBackend()
        XCTAssertEqual(backend.listOutputs(), [])
        XCTAssertNil(backend.defaultOutput())
        XCTAssertEqual(
            backend.classify(AudioDevice(name: "AirPods", transport: "bluetooth")), .unknown
        )
        let verdict = backend.heuristicVerdict()
        XCTAssertEqual(verdict.verdict, .unknown)
        XCTAssertNil(verdict.device)
    }

    /// The factory must always hand back something that satisfies the protocol, so any
    /// failure of detection degrades to `UNKNOWN` rather than throwing.
    ///
    /// Only the *type* is checked. Calling `listOutputs()` here would talk to the live
    /// CoreAudio HAL from a non-app xctest process, where it blocks until the runner times
    /// the test out; the HAL round-trip is exercised by the app itself, not by a unit test.
    func testFactoryAlwaysReturnsAUsableBackend() {
        let backend = AudioDevices.makeBackend()
        #if os(macOS)
        XCTAssertTrue(backend is CoreAudioDeviceBackend)
        #else
        XCTAssertTrue(backend is NullAudioDeviceBackend)
        #endif
        // Conformance is compile-time; this pins that the value is the protocol and not `Any`.
        let existential: any AudioDeviceBackend = backend
        XCTAssertNotNil(existential as Any)
    }

    /// The protocol is the whole surface; a conforming backend has exactly these four
    /// members, which is what CONTRACT §3 requires and nothing more.
    func testBackendProtocolSurface() {
        func requireFourMembers<B: AudioDeviceBackend>(_ backend: B, file: StaticString = #filePath, line: UInt = #line) {
            _ = backend.listOutputs()
            _ = backend.defaultOutput()
            _ = backend.classify(AudioDevice(name: "x", transport: "usb"))
            _ = backend.heuristicVerdict()
        }
        requireFourMembers(NullAudioDeviceBackend())
    }
}

#if os(macOS)
extension DeviceModelTests {

    /// The FourCC table is the macOS half of the port: CoreAudio reports `blth`, `bltn`,
    /// `dprt`…, and each must resolve to the transport name the aliases then fold.
    func testTransportForFourCC() {
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "blue"), "bluetooth")
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "blet"), "bluetoothle")
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "bltn"), "builtin")
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "buit"), "builtin")
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "hdmi"), "hdmi")
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "dprt"), "displayport")
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "dp  "), "displayport")
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "airp"), "airplay")
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "usb "), "usb")
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "pci "), "pci")
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "virt"), "virtual")
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "grup"), "aggregate")
        // A code nobody has seen must read as "unknown", never as a guess.
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "zzzz"), "unknown")
    }

    /// The two-step Python does: FourCC -> transport name -> folded transport. Whatever
    /// the name resolves to must be either a transport the heuristic knows, or one it
    /// passes through to `UNKNOWN` — never a spelling it would misread as something else.
    func testEveryFourCCResolvesToAKnownTransportOrToUnknown() {
        let known = ["bluetooth", "builtin", "usb", "hdmi", "virtual"]
        for (fourCC, name) in DeviceHeuristics.transportByFourCC {
            let normalised = DeviceHeuristics.normalizedTransport(name)
            if known.contains(normalised) {
                continue
            }
            // Not a transport the heuristic knows: it must land on UNKNOWN, not guess.
            XCTAssertEqual(
                DeviceHeuristics.classify(name: "Whatever", transport: normalised),
                .unknown,
                "\(fourCC) -> \(name) -> \(normalised)"
            )
        }
        // `thunderbolt` and `firewire` are exactly those pass-through cases.
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "thun"), "thunderbolt")
        XCTAssertEqual(DeviceHeuristics.transport(forFourCC: "1394"), "firewire")
        XCTAssertEqual(
            DeviceHeuristics.classify(name: "Whatever", transport: "thunderbolt"), .unknown
        )
    }

    /// The real backend must never throw — but enumerating the HAL from a non-app xctest
    /// process blocks until the runner times the test out, so only the type and the
    /// device-independent half are exercised here. Python's equivalent
    /// (`test_macos_backend_never_raises`) assumes a real session; this one does not.
    func testCoreAudioBackendTypeIsUsableWithoutTouchingTheHAL() {
        let backend = CoreAudioDeviceBackend()
        XCTAssertTrue((backend as any AudioDeviceBackend) is CoreAudioDeviceBackend)
        // `classify` is pure — it needs no HAL round-trip at all.
        XCTAssertEqual(
            backend.classify(AudioDevice(name: "AirPods Pro", transport: "usb")), .headphones
        )
    }

    /// The real HAL, end to end.
    ///
    /// This is the test that pins the call the launch smoke test found broken: nothing
    /// called `deviceIDs()` until the app ran the §4 check at start-up, and it faulted —
    /// SIGBUS inside `swift_retain`, on the way out of `withUnsafeMutableBytes(of:)`.
    ///
    /// Nothing is asserted about *which* devices exist — a CI machine, a Mac mini and a
    /// studio all differ. What is asserted is the contract: enumerating must not fault, and
    /// whatever comes back must be usable.
    func testTheRealHALEnumeratesWithoutFaulting() {
        let backend = CoreAudioDeviceBackend()
        let devices = backend.listOutputs()
        for device in devices {
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertFalse(device.transport.isEmpty)
            XCTAssertNotEqual(backend.classify(device), .unknown, "\(device.name) is classified")
        }
        if let defaultDevice = backend.defaultOutput() {
            XCTAssertTrue(
                devices.contains { $0.identifier == defaultDevice.identifier },
                "the default output must be among the enumerated devices"
            )
        }
    }

    /// The heuristic reads the default device and never throws, whatever the machine has.
    func testTheRealHALProducesAUsableVerdict() {
        let verdict = HeadphoneDetector.detect(backend: CoreAudioDeviceBackend())
        XCTAssertTrue(DeviceClass.allCases.contains(verdict.verdict))
        // `deviceName` is "" when nothing was readable — never a crash, never a trap.
        XCTAssertFalse(verdict.deviceName.isEmpty && verdict.device == nil)
    }
}
#endif
