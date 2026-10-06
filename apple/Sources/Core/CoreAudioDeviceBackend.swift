import Foundation

#if os(macOS)

import CoreAudio

/// CoreAudio enumeration — the Swift half of `audio/platform/macos.py`.
///
/// The same four properties the Python backend reads, and no others:
///
/// * `kAudioHardwarePropertyDevices` — every device the HAL knows;
/// * `kAudioDevicePropertyDeviceNameCFString` — the display name;
/// * `kAudioDevicePropertyTransportType` — the FourCC (`bltn`, `blue`, `blea`, `dprt`…);
/// * `kAudioObjectUID` / `kAudioDevicePropertyDeviceUID` — a stable identifier;
/// * `kAudioHardwarePropertyDefaultOutputDevice` — the one the system plays to.
///
/// **Every failure degrades to "no information"**, never to an exception or a zeroed
/// property: detection must not be able to break the app (CONTRACT §3, "любое падение
/// детекта сводится к `UNKNOWN`").
///
/// `kAudioDevicePropertyJackIsConnected` is deliberately **absent**. Python established
/// on this machine that it fails with `err 2003332927` (`kAudioHardwareNotRunningError`
/// family) for every device, so it carries no information and retrying it would only
/// add a failing HAL round-trip per launch. The heuristic plus the perceptual L/R test
/// (SPEC §4.1/§4.2) is what replaces it.
///
/// macOS only. `BinauralCore` also builds for iOS, where the factory in
/// ``AudioDevices`` returns ``NullAudioDeviceBackend`` instead and this file compiles
/// to nothing.
public struct CoreAudioDeviceBackend: AudioDeviceBackend {

    public init() {}

    // MARK: - Backend

    public func listOutputs() -> [AudioDevice] {
        let defaultID = Self.defaultOutputID()
        var devices: [AudioDevice] = []
        for id in Self.deviceIDs() {
            let name = Self.deviceName(id)
            guard !name.isEmpty else { continue }
            devices.append(
                AudioDevice(
                    name: name,
                    transport: Self.deviceTransport(id),
                    isDefault: id == defaultID,
                    identifier: Self.deviceUID(id) ?? String(id)
                )
            )
        }
        return devices
    }

    public func defaultOutput() -> AudioDevice? {
        let devices = listOutputs()
        if let match = devices.first(where: \.isDefault) { return match }
        // Safety net: if the default id could not be matched inside the enumeration,
        // look it up by raw device id (Python does the same).
        let defaultID = Self.defaultOutputID()
        guard defaultID != kAudioObjectUnknown else { return nil }
        return devices.first { $0.identifier == String(defaultID) }
    }

    public func classify(_ device: AudioDevice) -> DeviceClass {
        DeviceHeuristics.classify(name: device.name, transport: device.transport)
    }

    public func heuristicVerdict() -> (verdict: DeviceClass, device: AudioDevice?) {
        guard let device = defaultOutput() else { return (.unknown, nil) }
        return (classify(device), device)
    }

    // MARK: - HAL plumbing

    /// Read one scalar property. `nil` on any error, including a size CoreAudio reports
    /// but does not then fill.
    private static func scalar<T: FixedWidthInteger>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as _: T.Type = T.self
    ) -> T? {
        var address = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value: T = 0
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        return status == noErr && size == UInt32(MemoryLayout<T>.size) ? value : nil
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// The HAL's system object. Typed as `AudioObjectID` explicitly because the SDK
    /// constant is spelled as a plain `Int32`.
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func deviceIDs() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            systemObject, &address, 0, nil, &size
        ) == noErr else { return [] }

        let stride = MemoryLayout<AudioObjectID>.size
        let count = Int(size) / stride
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        var written = UInt32(count * stride)
        // CoreAudio may write up to `size` bytes, which is exactly the array's own
        // storage: the buffer is allocated for `count` ids and no more.
        //
        // `ids.withUnsafeMutableBytes { … }` rather than
        // `withUnsafeMutableBytes(of: &ids) { … }`, and the difference is not cosmetic:
        // the second form **crashes** on this toolchain (Swift 6.4, macOS 26) as soon as
        // the closure touches the buffer — SIGBUS inside `swift_retain` on the way out of
        // the call, inside `deviceIDs()`. It was found by the launch smoke test, because
        // nothing else calls this function: the array's own method is the equivalent, does
        // exactly the same thing, and is the documented way to get at an array's bytes.
        let status = ids.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(-1) }
            return AudioObjectGetPropertyData(
                systemObject, &address, 0, nil, &written, base
            )
        }
        return status == noErr ? ids : []
    }

    private static func defaultOutputID() -> AudioObjectID {
        scalar(
            systemObject,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal
        ) ?? kAudioObjectUnknown
    }

    /// The device name as a Swift `String`.
    ///
    /// `CFString` is bridged rather than walked with `CFStringGetCharacters`: the
    /// bridging copy is Unicode-correct for "Динамики Mac mini" — which is exactly this
    /// machine's default output — where `CFStringGetCStringPtr` only serves the Latin-1
    /// fast path and returns NULL for everything else. Under ARC the +1 reference the
    /// Core Foundation Get Rule hands back is released by the compiler, so this cannot
    /// leak even though it runs on every launch and every "Retry check".
    private static func stringProperty(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = address(selector, kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<CFTypeRef>.size)
        var value: CFTypeRef?
        // Written through a typed pointer, never `&value`: CoreAudio fills the pointer's
        // pointee, and forming a raw pointer to an `Optional` that may hold an object
        // reference is exactly the aliasing mistake that warning exists for.
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        // `as?` is the type check: a property that is not a `CFString` fails the cast and
        // reads as "no name", which is the same degradation as any other failure.
        return value as? String
    }

    private static func deviceName(_ id: AudioObjectID) -> String {
        (stringProperty(id, kAudioDevicePropertyDeviceNameCFString) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deviceUID(_ id: AudioObjectID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    /// The transport FourCC as a readable name, or `unknown`.
    private static func deviceTransport(_ id: AudioObjectID) -> String {
        guard let code: UInt32 = scalar(id, kAudioDevicePropertyTransportType) else {
            return "unknown"
        }
        return DeviceHeuristics.transport(forFourCC: fourCC(code))
    }

    /// A `UInt32` OSType back to its four characters, big-endian.
    private static func fourCC(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }
}

// MARK: - FourCC table

extension DeviceHeuristics {

    /// Transport FourCC -> the spelling `base.py::TRANSPORT_BY_FOURCC` produces.
    ///
    /// The codes are listed both as `AudioHardwareBase.h` declares them and as they were
    /// seen in the wild and written in SPEC §4.1, so both spellings resolve; the *value*
    /// is the transport's own name (`displayport`, `airplay`, `bluetoothle`), which
    /// ``normalizedTransport(_:)`` then folds — exactly the two-step Python does, so the
    /// heuristic cannot be handed a name it was never written to understand.
    ///
    /// Trailing spaces are part of the key: CoreAudio's `'usb '`, `'pci '` and `'dp  '`
    /// are four-character OSTypes, not names.
    static let transportByFourCC: [String: String] = [
        // Declared in AudioHardwareBase.h
        "blue": "bluetooth",
        "blea": "bluetoothle",
        "bltn": "builtin",
        "hdmi": "hdmi",
        "dprt": "displayport",
        "airp": "airplay",
        "usb ": "usb",
        "pci ": "pci",
        "virt": "virtual",
        "grup": "aggregate",
        "thun": "thunderbolt",
        "1394": "firewire",
        // Codes seen in the wild / named in SPEC §4.1
        "blth": "bluetooth",
        "blet": "bluetoothle",
        "buit": "builtin",
        "dp  ": "displayport",
    ]

    /// FourCC -> readable transport name, `unknown` for a code nobody has seen.
    public static func transport(forFourCC fourCC: String) -> String {
        transportByFourCC[fourCC] ?? "unknown"
    }
}

#endif
