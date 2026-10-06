import Foundation

/// Which enumeration the app asks for (CONTRACT §3, `get_backend()`).
///
/// Python picks a module by `sys.platform`; Swift picks by compile-time availability,
/// which is stricter and safer: the CoreAudio code is simply **not compiled** where
/// CoreAudio does not exist. A failure to build the CoreAudio backend is impossible by
/// construction, and an empty device list is still handled everywhere above.
///
/// **Spelling note.** Python calls the protocol `AudioBackend`; the Swift tree says
/// `AudioDeviceBackend`, and ``NullAudioDeviceBackend`` for `NullBackend`. The longer
/// name is used everywhere in `apple/` because `AudioEngine` is the *playback* type and
/// `AudioBackend` next to it reads as "the backend of the engine" rather than "the
/// backend of device enumeration"; CONTRACT §3 does not mandate a spelling, only the
/// four members.
public enum AudioDevices {

    /// The platform backend: CoreAudio on macOS, nothing at all elsewhere.
    public static func makeBackend() -> any AudioDeviceBackend {
        #if os(macOS)
        return CoreAudioDeviceBackend()
        #else
        return NullAudioDeviceBackend()
        #endif
    }
}

/// What the app concluded about the output device (CONTRACT §3, `DeviceClass`).
///
/// The four cases are Python's, and the raw values are its `Enum` values, so a value
/// that crosses over from a stored document compares equal.
public enum DeviceClass: String, CaseIterable, Sendable {
    /// Definitely headphones — Bluetooth, or a name that says so.
    case headphones
    /// Speakers: the machine's own output, a monitor or a TV.
    case speakers
    /// A routing helper or a null sink: it says nothing about the physical setup.
    case virtual
    /// Nothing to go on. The perceptual test decides (SPEC §4.2).
    case unknown
}

/// How much the heuristic actually knew (CONTRACT §4, `confidence`).
///
/// Python keeps this as the string `"high" | "medium" | "low"`; an enum is the Swift
/// spelling of the same three values, and its raw values are those strings.
public enum DetectionConfidence: String, CaseIterable, Sendable {
    /// The verdict came from the transport alone.
    case high
    /// The verdict came from the device name.
    case medium
    /// Nothing conclusive.
    case low
}

/// One output device (CONTRACT §3, the frozen `AudioDevice` dataclass).
///
/// `transport` is the **normalised** string the shared heuristics understand —
/// `"bluetooth" | "usb" | "builtin" | "hdmi" | "displayport" | "airplay" | "pci" |
/// "virtual" | "unknown"` — because the backend does the normalising before the record
/// is built. That is where Python puts it too (`macos.py::_device_transport`).
public struct AudioDevice: Sendable, Equatable, Hashable, Identifiable {

    /// Display name as CoreAudio reports it, trimmed. Never empty: a device with no
    /// readable name is skipped by the backends rather than recorded blank.
    public let name: String

    /// Normalised transport, see ``name``.
    public let transport: String

    /// True for the device the system plays to.
    public let isDefault: Bool

    /// A stable identifier — the CoreAudio UID, or the numeric object id as a fallback.
    public let identifier: String

    public init(
        name: String,
        transport: String,
        isDefault: Bool = false,
        identifier: String = ""
    ) {
        self.name = name
        self.transport = transport
        self.isDefault = isDefault
        self.identifier = identifier
    }

    public var id: String { identifier.isEmpty ? name : identifier }
}

/// The platform layer's whole surface (CONTRACT §3, the `AudioBackend` protocol).
///
/// `Sendable` because the implementations are stateless values and the protocol is
/// called from the main actor and from tests alike; nothing here may hold mutable state,
/// which is what keeps detection from touching the audio thread.
public protocol AudioDeviceBackend: Sendable {

    /// Every output device the HAL knows about, in enumeration order.
    func listOutputs() -> [AudioDevice]

    /// The device the system plays to, or `nil` when it could not be read.
    func defaultOutput() -> AudioDevice?

    /// The heuristic verdict for one device.
    func classify(_ device: AudioDevice) -> DeviceClass

    /// The verdict for the default device: `(class, device)`.
    func heuristicVerdict() -> (verdict: DeviceClass, device: AudioDevice?)
}

/// The backend that knows nothing — Python's `NullBackend`, and the factory's answer on
/// every platform without a device layer.
///
/// "Nothing is known, nothing raises" is the CONTRACT §3 rule: any failure of detection
/// degrades to `UNKNOWN`, and this is what makes that rule structural rather than a
/// convention every call site has to remember.
public struct NullAudioDeviceBackend: AudioDeviceBackend {

    public init() {}

    public func listOutputs() -> [AudioDevice] { [] }

    public func defaultOutput() -> AudioDevice? { nil }

    public func classify(_ device: AudioDevice) -> DeviceClass { .unknown }

    public func heuristicVerdict() -> (verdict: DeviceClass, device: AudioDevice?) {
        (.unknown, nil)
    }
}

/// The shared, pure heuristics of SPEC §4.1 — the Swift half of
/// `audio/platform/base.py::_heuristic`.
///
/// Pure functions over a name/transport pair: no audio, no CoreAudio, no subprocess.
/// That is what makes every row of SPEC §4.1's table a plain unit test, on any machine
/// and with no hardware at all.
public enum DeviceHeuristics {

    // MARK: - Tables (verbatim from base.py)

    /// Substrings that mean headphones wherever they appear in a device name. Covers the
    /// USB wired headsets macOS gives no jack detection for.
    public static let headphoneNameHints: [String] = [
        "airpods", "headset", "headphone", "earphone", "buds", "earbuds",
    ]

    /// Substrings that mean a routing helper rather than a physical output. `"udio"`
    /// catches "Audio" plug-ins and null sinks while staying clear of the Russian
    /// "Динамики", which *is* the built-in speaker.
    public static let virtualNameHints: [String] = [
        "blackhole", "loopback", "aggregate", "multi-output", "virtual", "udio",
    ]

    /// Every spelling of a transport that must mean the same thing: the normalised names
    /// plus the FourCC codes CoreAudio reports.
    public static let transportAliases: [String: String] = [
        "bluetooth": "bluetooth", "bluetoothle": "bluetooth", "bluetooth_le": "bluetooth",
        "blue": "bluetooth", "blth": "bluetooth", "blea": "bluetooth", "blet": "bluetooth",
        "builtin": "builtin", "built_in": "builtin", "bltn": "builtin", "buit": "builtin",
        "usb": "usb", "usb_": "usb",
        "hdmi": "hdmi", "displayport": "hdmi", "dprt": "hdmi", "dp": "hdmi",
        "airplay": "hdmi", "airp": "hdmi",
        "virtual": "virtual", "virt": "virtual", "aggregate": "virtual", "grup": "virtual",
        "pci": "virtual", "pci_": "virtual",
    ]

    /// Normalise a transport: trim, lowercase, then fold the aliases.
    public static func normalizedTransport(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return transportAliases[value] ?? value
    }

    /// The whole verdict plus how it was reached.
    ///
    /// The order is SPEC §4.1's table read top to bottom, and it matters: transport
    /// first (wireless audio is essentially never a pair of speakers you can hear a beat
    /// with), then the name, then virtual devices, then speakers, then nothing. Python
    /// checks the name hints *before* the virtual transport, so a virtual device that calls
    /// itself "AirPods Monitor" is reported as headphones — deliberately, because a real
    /// headset behind a routing helper is the case that needs swapping, and the
    /// perceptual L/R test is what settles it if that guess is wrong.
    public static func verdict(
        name: String?,
        transport: String?
    ) -> (verdict: DeviceClass, confidence: DetectionConfidence) {
        let nameLower = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let transportLower = normalizedTransport(transport)

        // Transport is the strongest signal.
        if transportLower == "bluetooth" { return (.headphones, .high) }

        // Name hints: this is what catches USB wired headsets.
        if headphoneNameHints.contains(where: { nameLower.contains($0) }) {
            return (.headphones, .medium)
        }

        // Routing helpers and null sinks tell us nothing about the physical setup.
        if transportLower == "virtual" { return (.virtual, .high) }
        if virtualNameHints.contains(where: { nameLower.contains($0) }) {
            return (.virtual, .medium)
        }

        // Display and TV outputs are monitors with built-in speakers.
        if transportLower == "hdmi" { return (.speakers, .high) }

        // Built-in audio is the machine's own speaker; headphone names were handled
        // above, so what is left on this transport is a speaker even when the name is
        // just "Built-in Output".
        if transportLower == "builtin" { return (.speakers, .medium) }

        // USB with no name hint could be anything: leave it to the perceptual test.
        return (.unknown, .low)
    }

    /// The verdict alone, for `classify(_:)`.
    public static func classify(name: String?, transport: String?) -> DeviceClass {
        verdict(name: name, transport: transport).verdict
    }

    /// The confidence alone, for `classify_confidence(...)`.
    public static func confidence(name: String?, transport: String?) -> DetectionConfidence {
        verdict(name: name, transport: transport).confidence
    }
}
