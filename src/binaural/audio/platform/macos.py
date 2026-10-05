"""macOS CoreAudio backend via ctypes.

Only the CoreAudio framework is used — no third-party bindings.
Every call is wrapped so that any failure degrades to "no information"
(UNKNOWN) instead of an exception: detection must never break the app.
"""

from __future__ import annotations

import ctypes
from typing import Any

from .base import AudioDevice, DeviceClass, NullBackend, classify_device

__all__ = ["MacOSBackend", "transport_name", "TRANSPORT_BY_FOURCC"]

_CORE_AUDIO = "/System/Library/Frameworks/CoreAudio.framework/CoreAudio"
_CORE_FOUNDATION = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"

# AudioObjectPropertyAddress selectors (FourCC)
_K_AUDIO_HARDWARE_PROPERTY_DEVICES = "dev#"
_K_AUDIO_HARDWARE_PROPERTY_DEFAULT_OUTPUT_DEVICE = "dOut"
_K_AUDIO_DEVICE_PROPERTY_TRANSPORT_TYPE = "tran"
_K_AUDIO_DEVICE_PROPERTY_DEVICE_NAME_CFSTRING = "lnam"
_K_AUDIO_DEVICE_PROPERTY_DEVICE_UID = "uid "  # stable per-device identifier

_K_AUDIO_OBJECT_SYSTEM_OBJECT = 1
_K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL = "glob"
_K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN = 0

# Transport FourCC -> normalized string used by the shared heuristics.
# Codes are listed both as declared in AudioHardwareBase.h and as they were
# observed on real hardware / in the project spec, so both spellings work.
TRANSPORT_BY_FOURCC: dict[str, str] = {
    # Declared in AudioHardwareBase.h
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
    # Alternative codes seen in the wild / in the spec
    "blth": "bluetooth",
    "blet": "bluetoothle",
    "buit": "builtin",
    "dp  ": "displayport",
}


def transport_name(fourcc: str) -> str:
    """FourCC code -> readable transport string; unknown codes -> 'unknown'."""
    return TRANSPORT_BY_FOURCC.get(fourcc, "unknown")


class _AudioObjectPropertyAddress(ctypes.Structure):
    _fields_ = [
        ("mSelector", ctypes.c_uint32),
        ("mScope", ctypes.c_uint32),
        ("mElement", ctypes.c_uint32),
    ]


def _fourcc(code: str) -> int:
    """'dev#' -> big-endian uint32 value as CoreAudio expects."""
    padded = (code + "    ")[:4]
    return int.from_bytes(padded.encode("ascii", "replace"), "big")


class MacOSBackend:
    """CoreAudio device enumeration + shared classification."""

    def __init__(self) -> None:
        self._null = NullBackend()
        self._core: Any = None
        self._foundation: Any = None
        try:
            self._core = ctypes.CDLL(_CORE_AUDIO, use_errno=True)
            self._foundation = ctypes.CDLL(_CORE_FOUNDATION, use_errno=True)
            self._setup_signatures()
        except Exception:
            # Non-macOS machine or missing framework: behave as NullBackend.
            self._core = None
            self._foundation = None

    # -- CoreAudio plumbing -------------------------------------------------

    def _setup_signatures(self) -> None:
        self._core.AudioObjectGetPropertyDataSize.argtypes = [
            ctypes.c_uint32,
            ctypes.POINTER(_AudioObjectPropertyAddress),
            ctypes.c_uint32,
            ctypes.c_void_p,  # inQualifierData is a pointer, not a value
            ctypes.POINTER(ctypes.c_uint32),
        ]
        self._core.AudioObjectGetPropertyDataSize.restype = ctypes.c_int32
        # NOTE: ioDataSize is an in/out pointer (UInt32*), not a plain UInt32.
        # Passing it by value segfaults.
        self._core.AudioObjectGetPropertyData.argtypes = [
            ctypes.c_uint32,
            ctypes.POINTER(_AudioObjectPropertyAddress),
            ctypes.c_uint32,
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_uint32),
            ctypes.c_void_p,
        ]
        self._core.AudioObjectGetPropertyData.restype = ctypes.c_int32

    def _get_data(
        self,
        object_id: int,
        selector: str,
        scope: str,
        out_type: Any,
    ) -> Any:
        """Reads one CoreAudio property. Returns None on any error."""
        if self._core is None:
            return None
        try:
            address = _AudioObjectPropertyAddress(
                mSelector=_fourcc(selector),
                mScope=_fourcc(scope),
                mElement=_K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
            )
            size = ctypes.c_uint32(0)
            status = self._core.AudioObjectGetPropertyDataSize(
                object_id,
                ctypes.byref(address),
                ctypes.c_uint32(0),
                None,
                ctypes.byref(size),
            )
            if status != 0 or size.value == 0:
                return None
            # CoreAudio writes `size.value` bytes, which can exceed
            # sizeof(out_type). Allocating only out_type() here overflows the
            # heap and corrupts adjacent memory -> delayed SIGSEGV inside an
            # unrelated CoreAudio call. Use a raw buffer of the exact size and
            # decode into out_type afterwards.
            raw = ctypes.create_string_buffer(size.value)
            io_size = ctypes.c_uint32(size.value)
            status = self._core.AudioObjectGetPropertyData(
                object_id,
                ctypes.byref(address),
                ctypes.c_uint32(0),
                None,
                ctypes.byref(io_size),
                raw,
            )
            if status != 0:
                return None
            result = out_type()
            copied = min(ctypes.sizeof(result), size.value, io_size.value)
            if copied > 0:
                ctypes.memmove(ctypes.byref(result), raw, copied)
            return result
        except Exception:
            return None

    def _device_ids(self) -> list[int]:
        size = ctypes.c_uint32(0)
        try:
            address = _AudioObjectPropertyAddress(
                mSelector=_fourcc(_K_AUDIO_HARDWARE_PROPERTY_DEVICES),
                mScope=_fourcc(_K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL),
                mElement=_K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
            )
            status = self._core.AudioObjectGetPropertyDataSize(
                _K_AUDIO_OBJECT_SYSTEM_OBJECT,
                ctypes.byref(address),
                ctypes.c_uint32(0),
                None,
                ctypes.byref(size),
            )
            if status != 0 or size.value == 0:
                return []
            count = size.value // ctypes.sizeof(ctypes.c_uint32)
            if count == 0:
                return []
            # Exact-size buffer: never let CoreAudio write past our allocation.
            raw = ctypes.create_string_buffer(size.value)
            io_size = ctypes.c_uint32(size.value)
            status = self._core.AudioObjectGetPropertyData(
                _K_AUDIO_OBJECT_SYSTEM_OBJECT,
                ctypes.byref(address),
                ctypes.c_uint32(0),
                None,
                ctypes.byref(io_size),
                raw,
            )
            if status != 0:
                return []
            array_type = ctypes.c_uint32 * count
            array = array_type()
            ctypes.memmove(ctypes.byref(array), raw, count * 4)
            return [int(array[i]) for i in range(count)]
        except Exception:
            return []

    def _default_output_id(self) -> int:
        value = self._get_data(
            _K_AUDIO_OBJECT_SYSTEM_OBJECT,
            _K_AUDIO_HARDWARE_PROPERTY_DEFAULT_OUTPUT_DEVICE,
            _K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            ctypes.c_uint32,
        )
        return int(value.value) if value is not None else 0

    def _device_name(self, device_id: int) -> str:
        value = self._get_data(
            device_id,
            _K_AUDIO_DEVICE_PROPERTY_DEVICE_NAME_CFSTRING,
            _K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            ctypes.c_void_p,
        )
        if value is None or not value.value:
            return ""
        try:
            return self._cfstring_to_str(value.value) or ""
        except Exception:
            return ""

    def _device_uid(self, device_id: int) -> str:
        value = self._get_data(
            device_id,
            _K_AUDIO_DEVICE_PROPERTY_DEVICE_UID,
            _K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            ctypes.c_void_p,
        )
        if value is None or not value.value:
            return ""
        try:
            return self._cfstring_to_str(value.value) or ""
        except Exception:
            return ""

    def _device_transport(self, device_id: int) -> str:
        value = self._get_data(
            device_id,
            _K_AUDIO_DEVICE_PROPERTY_TRANSPORT_TYPE,
            _K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            ctypes.c_uint32,
        )
        if value is None:
            return "unknown"
        return transport_name(value.value.to_bytes(4, "big").decode("ascii", "replace"))

    def _cfstring_to_str(self, cf_string: int) -> str:
        """CFStringRef -> str.

        CFStringGetCStringPtr is unreliable here (it only serves the latin1
        fast path and returns NULL for anything else, e.g. "Динамики Mac
        mini"), so the reliable CFStringGetCharacters + CFStringGetLength pair
        is used instead.
        """
        if self._foundation is None:
            return ""
        get_length = self._foundation.CFStringGetLength
        get_length.argtypes = [ctypes.c_void_p]
        get_length.restype = ctypes.c_long
        get_characters = self._foundation.CFStringGetCharacters
        get_characters.argtypes = [
            ctypes.c_void_p,
            ctypes.c_long,
            ctypes.c_long,
            ctypes.c_void_p,
        ]
        get_characters.restype = ctypes.c_void_p
        reference = ctypes.c_void_p(cf_string)
        length = int(get_length(reference))
        if length <= 0:
            return ""
        buffer = ctypes.create_string_buffer(2 * length + 2)
        # Return value is unreliable through ctypes; the buffer is the result.
        get_characters(reference, ctypes.c_long(0), ctypes.c_long(length), buffer)
        return buffer.raw[: 2 * length].decode("utf-16-le", "replace")

    # -- AudioBackend -------------------------------------------------------

    def list_outputs(self) -> list[AudioDevice]:
        if self._core is None:
            return self._null.list_outputs()
        try:
            default_id = self._default_output_id()
            devices: list[AudioDevice] = []
            for device_id in self._device_ids():
                name = self._device_name(device_id)
                if not name:
                    continue
                devices.append(
                    AudioDevice(
                        name=name,
                        transport=self._device_transport(device_id),
                        is_default=device_id == default_id,
                        identifier=self._device_uid(device_id) or str(device_id),
                    )
                )
            return devices
        except Exception:
            return []

    def default_output(self) -> AudioDevice | None:
        if self._core is None:
            return None
        try:
            devices = self.list_outputs()
            for device in devices:
                if device.is_default:
                    return device
            # Safety net: if the default id could not be matched inside the
            # enumeration, look it up by numeric device id.
            default_id = self._default_output_id()
            if not default_id:
                return None
            for device in devices:
                if device.identifier == str(default_id):
                    return device
            return None
        except Exception:
            return None

    def classify(self, device: AudioDevice) -> DeviceClass:
        return classify_device(device.name, device.transport)

    def heuristic_verdict(self) -> tuple[DeviceClass, AudioDevice | None]:
        device = self.default_output()
        if device is None:
            return DeviceClass.UNKNOWN, None
        return self.classify(device), device