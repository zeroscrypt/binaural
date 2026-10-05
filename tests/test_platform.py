"""Platform layer tests.

No test may depend on a real audio device or on pactl being installed:
the classifiers are pure functions and the Linux parser is fed canned output.
"""

from __future__ import annotations

import subprocess

import pytest

from binaural.audio.platform import get_backend
from binaural.audio.platform.base import (
    AudioBackend,
    AudioDevice,
    DeviceClass,
    NullBackend,
    classify_confidence,
    classify_device,
)
from binaural.audio.platform.linux import (
    LinuxBackend,
    classify_output,
    parse_amixer,
    parse_pactl_sinks,
    parse_pw_cli_nodes,
)
from binaural.audio.platform.macos import MacOSBackend, transport_name


# --------------------------------------------------------------------------
# Types and factory
# --------------------------------------------------------------------------


def test_device_class_values():
    assert DeviceClass.HEADPHONES.value == "headphones"
    assert DeviceClass.SPEAKERS.value == "speakers"
    assert DeviceClass.VIRTUAL.value == "virtual"
    assert DeviceClass.UNKNOWN.value == "unknown"


def test_audio_device_defaults():
    device = AudioDevice(name="X", transport="usb")
    assert device.is_default is False
    assert device.identifier == ""
    with pytest.raises(Exception):
        device.name = "Y"  # frozen


def test_backend_protocol_methods():
    for name in ("list_outputs", "default_output", "classify", "heuristic_verdict"):
        assert hasattr(AudioBackend, name)
    assert isinstance(NullBackend(), AudioBackend)


def test_get_backend_returns_usable_object():
    backend = get_backend()
    for name in ("list_outputs", "default_output", "classify", "heuristic_verdict"):
        assert callable(getattr(backend, name))
    assert isinstance(backend.list_outputs(), list)
    verdict, device = backend.heuristic_verdict()
    assert isinstance(verdict, DeviceClass)
    assert device is None or isinstance(device, AudioDevice)


def test_null_backend_behaviour():
    backend = NullBackend()
    assert backend.list_outputs() == []
    assert backend.default_output() is None
    assert backend.classify(AudioDevice(name="AirPods", transport="bluetooth")) is DeviceClass.UNKNOWN
    assert backend.heuristic_verdict() == (DeviceClass.UNKNOWN, None)


# --------------------------------------------------------------------------
# macOS transport FourCC -> string
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "fourcc, expected",
    [
        ("blth", "bluetooth"),
        ("blue", "bluetooth"),
        ("blet", "bluetoothle"),
        ("blea", "bluetoothle"),
        ("usb ", "usb"),
        ("buit", "builtin"),
        ("bltn", "builtin"),
        ("hdmi", "hdmi"),
        ("dp  ", "displayport"),
        ("dprt", "displayport"),
        ("airp", "airplay"),
        ("pci ", "pci"),
        ("virt", "virtual"),
        ("grup", "aggregate"),
        ("zzzz", "unknown"),
    ],
)
def test_transport_name(fourcc, expected):
    assert transport_name(fourcc) == expected


def test_macos_backend_never_raises():
    # Only checks the failure contract, not the presence of any device.
    backend = MacOSBackend()
    outputs = backend.list_outputs()
    assert isinstance(outputs, list)
    for device in outputs:
        assert isinstance(device, AudioDevice)
        assert isinstance(backend.classify(device), DeviceClass)
    assert isinstance(backend.heuristic_verdict()[0], DeviceClass)


# --------------------------------------------------------------------------
# Shared classifier — the main test, no hardware involved
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "name, transport, expected",
    [
        # Transport says wireless -> headphones, high confidence.
        ("Whatever", "bluetooth", DeviceClass.HEADPHONES),
        ("Whatever", "bluetoothle", DeviceClass.HEADPHONES),
        # Name hints.
        ("AirPods Pro", "usb", DeviceClass.HEADPHONES),
        ("Studio Headset", "usb", DeviceClass.HEADPHONES),
        ("Buds", "bluetooth", DeviceClass.HEADPHONES),
        ("Earphone", "builtin", DeviceClass.HEADPHONES),
        ("AB Earphones 3", "usb", DeviceClass.HEADPHONES),
        # Built-in speakers.
        ("Динамики Mac mini", "builtin", DeviceClass.SPEAKERS),
        ("Built-in Output", "builtin", DeviceClass.SPEAKERS),
        ("Speakers", "builtin", DeviceClass.SPEAKERS),
        # Monitor / TV outputs.
        ("Mi Monitor", "hdmi", DeviceClass.SPEAKERS),
        ("Mi Monitor", "displayport", DeviceClass.SPEAKERS),
        ("Living Room", "airplay", DeviceClass.SPEAKERS),
        # Virtual devices.
        ("BlackHole 2ch", "usb", DeviceClass.VIRTUAL),
        ("Loopback", "pci", DeviceClass.VIRTUAL),
        ("Aggregate Device", "builtin", DeviceClass.VIRTUAL),
        ("Null Output", "virt", DeviceClass.VIRTUAL),
        ("Multi-Output Device", "builtin", DeviceClass.VIRTUAL),
        # Nothing conclusive.
        ("zzz-device", "usb", DeviceClass.UNKNOWN),
        ("", "", DeviceClass.UNKNOWN),
        ("????", "???", DeviceClass.UNKNOWN),
        (None, None, DeviceClass.UNKNOWN),
    ],
)
def test_classify_device(name, transport, expected):
    assert classify_device(name, transport) is expected


def test_classify_confidence_levels():
    assert classify_confidence("Whatever", "bluetooth") == "high"
    assert classify_confidence("Mi Monitor", "hdmi") == "high"
    assert classify_confidence("AirPods Pro", "usb") == "medium"
    assert classify_confidence("Динамики Mac mini", "builtin") == "medium"
    assert classify_confidence("zzz-device", "usb") == "low"
    assert classify_confidence("", "zzz") == "low"


def test_classify_uses_case_insensitive_names():
    assert classify_device("airpods", "usb") is DeviceClass.HEADPHONES
    assert classify_device("AIRPODS PRO", "usb") is DeviceClass.HEADPHONES


def test_backend_classify_matches_pure_function():
    backend = NullBackend()
    device = AudioDevice(name="AirPods Pro", transport="usb")
    assert backend.classify(device) is DeviceClass.UNKNOWN
    assert classify_device(device.name, device.transport) is DeviceClass.HEADPHONES


# --------------------------------------------------------------------------
# Linux parsers (canned output, never a real sound server)
# --------------------------------------------------------------------------

PACTL_HEADPHONE = """
Sink #0
\tState: IDLE
\tName: alsa_output.pci-0000_00_1f.3.analog-stereo
\tDescription: Built-in Audio Analog Stereo
\tDriver: module-alsa-card
\tFlags: HARDWARE HW_MUTE_CTRL HW_VOLUME_CTRL DECIBEL_VOLUME LATENCY DYNAMIC_LATENCY
\tActive Port: analog-output-headphone
\tPorts:
\t\tanalog-output-headphone: Headphone
\t\t[Out] Headphone: Headphone
\t\tanalog-output-speaker: Speaker
\t\t[Out] Speaker: Speaker

Sink #1
\tState: IDLE
\tName: alsa_output.usb-Apeaksoft_Analog
\tDescription: AP Extended Audio Plug-in
\tDriver: module-alsa-card
\tActive Port: analog-output-speaker
\tPorts:
\t\t[Out] Speaker: Speaker
"""

PACTL_SPEAKERS = """
Sink #0
\tName: alsa_output.pci-0000_00_1f.3.analog-stereo
\tDescription: Built-in Audio Analog Stereo
\tActive Port: analog-output-speaker
\tPorts:
\t\t[Out] Speaker: Speaker
"""

PACTL_MONITOR = """
Sink #0
\tName: alsa_output.pci-0000_00_1f.3.hdmi-stereo
\tDescription: HDA Intel HDMI
\tActive Port: hdmi-output-0
\tPorts:
\t\thdmi-output-0: HDMI

Default Sink: alsa_output.pci-0000_00_1f.3.hdmi-stereo
"""


def test_parse_pactl_headphone_port():
    devices, hints = parse_pactl_sinks(PACTL_HEADPHONE)
    assert len(devices) == 2
    first = devices[0]
    assert first.name == "Built-in Audio Analog Stereo"
    assert first.identifier == "alsa_output.pci-0000_00_1f.3.analog-stereo"
    assert "Headphone" in hints[first.identifier]
    assert classify_output(first.name, hints[first.identifier]) is DeviceClass.HEADPHONES


def test_parse_pactl_speaker_port():
    devices, hints = parse_pactl_sinks(PACTL_SPEAKERS)
    assert len(devices) == 1
    device = devices[0]
    assert classify_output(device.name, hints[device.identifier]) is DeviceClass.SPEAKERS


def test_parse_pactl_hdmi_is_speakers_and_marks_default():
    # An HDMI sink is a monitor/TV: speakers, never headphones.
    devices, hints = parse_pactl_sinks(PACTL_MONITOR)
    assert len(devices) == 1
    device = devices[0]
    assert device.is_default is True
    assert classify_output(device.name, hints[device.identifier]) is DeviceClass.SPEAKERS


def test_parse_pactl_null_sink_is_virtual():
    output = (
        "Sink #0\n\tName: auto_null\n\tDescription: Dummy Output\n"
        "\tActive Port: null-output\n\tPorts:\n\t\tnull-output: Null Output\n"
    )
    devices, hints = parse_pactl_sinks(output)
    assert classify_output(devices[0].name, hints[devices[0].identifier]) is DeviceClass.VIRTUAL


def test_parse_pactl_empty_and_garbage():
    assert parse_pactl_sinks("") == ([], {})
    assert parse_pactl_sinks("total: nonsense\n")[0] == []


PW_CLI_OUTPUT = """
Object Node
\tnode.name = "sink_alsa_output_pci_0000_00_1f_3_analog_stereo"
\tnode.description = "Built-in Audio Analog Stereo"
\tnode.nick = "Built-in Audio"
\tmedia.class = "Stream/Output/Audio"
Object Node
\tnode.name = "sink_alsa_output_usb_Apeaksoft"
\tnode.description = "AP Extended Audio Plug-in"
\tmedia.class = "Stream/Input/Audio"
"""


def test_parse_pw_cli_only_outputs():
    devices, hints = parse_pw_cli_nodes(PW_CLI_OUTPUT)
    assert len(devices) == 1
    assert devices[0].name == "Built-in Audio Analog Stereo"
    assert isinstance(hints, dict)
    assert parse_pw_cli_nodes("") == ([], {})


AMIXER_OUTPUT = """
Simple mixer control 'Master',0
  Capabilities: pvolume pswitch pswitch-joined
  Front Left: Playback 455 [68%]
Simple mixer control 'Speaker',0
  Capabilities: pvolume pswitch pswitch-joined
"""


def test_parse_amixer():
    devices = parse_amixer(AMIXER_OUTPUT)
    assert [d.name for d in devices] == ["Master", "Speaker"]
    assert parse_amixer("") == []


def test_classify_output_speakers_and_unknown():
    assert classify_output("Built-in Audio", "[Out] Speaker") is DeviceClass.SPEAKERS
    assert classify_output("Something", "") is DeviceClass.UNKNOWN


def _fake_pactl(output: str):
    """Stands in for linux._run: canned pactl output, other tools absent."""

    def runner(args, **kwargs):
        if args[0] == "pactl":
            return output
        return None

    return runner


def test_linux_backend_uses_pactl_output(monkeypatch):
    from binaural.audio.platform import linux as linux_module

    monkeypatch.setattr(linux_module, "_run", _fake_pactl(PACTL_HEADPHONE))
    backend = LinuxBackend()
    devices = backend.list_outputs()
    assert devices
    backend.classify(devices[0])
    assert backend.heuristic_verdict() == (DeviceClass.UNKNOWN, None)


def test_linux_backend_speakers_verdict(monkeypatch):
    from binaural.audio.platform import linux as linux_module

    output = PACTL_SPEAKERS + "\nDefault Sink: alsa_output.pci-0000_00_1f.3.analog-stereo\n"
    monkeypatch.setattr(linux_module, "_run", _fake_pactl(output))
    backend = LinuxBackend()
    verdict, device = backend.heuristic_verdict()
    assert device is not None
    assert verdict is DeviceClass.SPEAKERS


def test_linux_backend_without_any_tool_is_unknown(monkeypatch):
    from binaural.audio.platform import linux as linux_module

    def missing(args, **kwargs):
        raise FileNotFoundError(args[0])

    monkeypatch.setattr(linux_module.subprocess, "run", missing)
    backend = LinuxBackend()
    assert backend.list_outputs() == []
    assert backend.default_output() is None
    assert backend.heuristic_verdict() == (DeviceClass.UNKNOWN, None)
    # Classification of an explicit device still works without any probe tool.
    assert (
        backend.classify(AudioDevice(name="AirPods", transport="bluetooth"))
        is DeviceClass.HEADPHONES
    )


def test_linux_run_has_timeout(monkeypatch):
    from binaural.audio.platform import linux as linux_module

    captured = {}

    def runner(args, **kwargs):
        captured.update(kwargs)
        return subprocess.CompletedProcess(args, 0, "", "")

    monkeypatch.setattr(linux_module.subprocess, "run", runner)
    linux_module._run(["pactl", "list", "sinks"])
    assert captured["timeout"] == 2
    assert captured["check"] is False
    assert captured["capture_output"] is True