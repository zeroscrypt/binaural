"""Linux audio backend: pactl -> pw-cli -> amixer, first one available.

No hard dependency on any of them: missing tools, timeouts and parse errors
all degrade to UNKNOWN. Parsers are pure functions so tests never need a
sound server installed.
"""

from __future__ import annotations

import re
import subprocess

from .base import AudioDevice, DeviceClass, NullBackend, classify_device

__all__ = [
    "LinuxBackend",
    "classify_output",
    "parse_pactl_sinks",
    "parse_pw_cli_nodes",
    "parse_amixer",
]

_TIMEOUT_SECONDS = 2

_HEADPHONE_RE = re.compile(
    r"head\s*-?\s*phone|ear\s*-?\s*phone|ear\s*-?\s*bud|buds?\b|headset", re.I
)
_SPEAKER_RE = re.compile(r"speaker|hdmi|displayport|dp\s*-", re.I)
_VIRTUAL_RE = re.compile(r"blackhole|loopback|virtual|null|aggregate|dummy", re.I)


def classify_output(name: str, hint: str = "") -> DeviceClass:
    """Pure classifier for Linux outputs.

    ``hint`` carries the active port (e.g. ``[Out] Headphone``) or any other
    probe text. A selected Headphone port is the strongest signal available
    without ALSA jack detection.
    """
    haystack = f"{name} {hint}"
    if _VIRTUAL_RE.search(haystack):
        return DeviceClass.VIRTUAL
    if _HEADPHONE_RE.search(haystack):
        return DeviceClass.HEADPHONES
    if _SPEAKER_RE.search(haystack):
        return DeviceClass.SPEAKERS
    return DeviceClass.UNKNOWN


def _run(args: list[str]) -> str | None:
    """Runs a probe command with a hard timeout.

    Returns its stdout, or None when the tool is absent / timed out / failed.
    """
    try:
        proc = subprocess.run(
            args,
            timeout=_TIMEOUT_SECONDS,
            check=False,
            capture_output=True,
            text=True,
        )
    except Exception:
        # FileNotFoundError (tool absent), TimeoutExpired, anything else.
        return None
    return proc.stdout or ""


def parse_pactl_sinks(text: str) -> tuple[list[AudioDevice], dict[str, str]]:
    """Parses `pactl list sinks`.

    Returns ``(devices, hints)`` where ``hints`` maps a sink identifier to its
    active-port text, e.g. ``"analog_output_1": "[Out] Headphone"``.
    """
    devices: list[AudioDevice] = []
    hints: dict[str, str] = {}
    if not text:
        return devices, hints

    default_name = ""
    match = re.search(r"Default Sink:\s*(\S+)", text)
    if match:
        default_name = match.group(1)

    name: str | None = None
    description: str | None = None
    active_port = ""
    ports: list[str] = []
    in_ports = False

    def flush() -> None:
        nonlocal name, description, active_port, ports, in_ports
        if not name:
            return
        hint_parts = [active_port] + ports
        hints[name] = " ".join(part for part in hint_parts if part)
        devices.append(
            AudioDevice(
                name=description or name,
                transport="linux",
                is_default=name == default_name,
                identifier=name,
            )
        )
        name = None
        description = None
        active_port = ""
        ports = []
        in_ports = False

    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("Sink #"):
            flush()
            continue
        if not line:
            continue
        key, sep, value = line.partition(":")
        if not sep:
            continue
        key = key.strip().lower()
        value = value.strip()
        if key == "ports":
            # Everything below belongs to the port list of this sink.
            in_ports = True
            continue
        if in_ports:
            # Port lines look like "analog-output-headphone: Headphone";
            # both the port name and its description matter for the verdict.
            ports.append(line)
            continue
        if key == "name":
            name = value
        elif key == "description":
            description = value
        elif key == "active port":
            active_port = value
    flush()

    return devices, hints


def parse_pw_cli_nodes(text: str) -> tuple[list[AudioDevice], dict[str, str]]:
    """Parses `pw-cli list Node` output (indented `key : value` lines)."""
    if not text:
        return [], {}

    blocks: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped:
            current = None
            continue
        if stripped.lower().startswith("object"):
            # Object header: "Object Node", "Object Node #42", "object.node".
            if current:
                blocks.append(current)
            current = {}
            continue
        if current is None:
            continue
        # pw-cli writes "key = value"; be tolerant of "key: value" too.
        separator = "=" if "=" in stripped else ":"
        key, sep, value = stripped.partition(separator)
        if not sep:
            continue
        key = key.strip()
        if key.startswith("node."):
            key = key[len("node.") :]
        current[key] = value.strip().strip('"')
    if current:
        blocks.append(current)

    devices: list[AudioDevice] = []
    hints: dict[str, str] = {}
    for block in blocks:
        media_class = block.get("media.class", "").lower()
        # PipeWire reports "Stream/Output/Audio", Pulse "Audio/Sink".
        is_sink = media_class in ("audio/sink", "stream/output/audio") or media_class.endswith(
            "/output/audio"
        )
        if media_class and not is_sink:
            continue
        # "node." prefix was stripped while parsing.
        description = (
            block.get("description")
            or block.get("device.profile.description")
            or block.get("nick")
            or block.get("name")
            or ""
        )
        if not description:
            continue
        identifier = block.get("name", "") or block.get("id", "")
        hints[identifier] = block.get("device.profile.description", "")
        devices.append(
            AudioDevice(
                name=description,
                transport="linux",
                is_default=False,
                identifier=identifier,
            )
        )
    return devices, hints


def parse_amixer(text: str) -> list[AudioDevice]:
    """Parses `amixer scontents` output — last resort, control names only."""
    if not text:
        return []
    names: list[str] = []
    for raw in text.splitlines():
        match = re.match(r"^Simple mixer control '(?P<name>[^']+)'", raw.strip())
        if match:
            name = match.group("name")
            if name not in names:
                names.append(name)
    return [
        AudioDevice(name=name, transport="builtin", is_default=False, identifier=name)
        for name in names
    ]


class LinuxBackend:
    """Probes pactl / pw-cli / amixer in order and parses the first that works."""

    def __init__(self) -> None:
        self._null = NullBackend()
        self._hints: dict[str, str] = {}

    def _discover(self) -> list[AudioDevice]:
        self._hints = {}

        text = _run(["pactl", "list", "sinks"])
        if text:
            devices, hints = parse_pactl_sinks(text)
            if devices:
                self._hints = hints
                return devices

        text = _run(["pw-cli", "list", "Node"])
        if text:
            devices, hints = parse_pw_cli_nodes(text)
            if devices:
                self._hints = hints
                return devices

        text = _run(["amixer", "scontents"])
        if text:
            devices = parse_amixer(text)
            if devices:
                return devices

        return []

    def list_outputs(self) -> list[AudioDevice]:
        try:
            return self._discover()
        except Exception:
            return self._null.list_outputs()

    def default_output(self) -> AudioDevice | None:
        try:
            for device in self.list_outputs():
                if device.is_default:
                    return device
            return None
        except Exception:
            return None

    def classify(self, device: AudioDevice) -> DeviceClass:
        if not isinstance(device, AudioDevice):
            return DeviceClass.UNKNOWN
        verdict = classify_output(device.name, self._hints.get(device.identifier, ""))
        if verdict is not DeviceClass.UNKNOWN:
            return verdict
        return classify_device(device.name, device.transport)

    def heuristic_verdict(self) -> tuple[DeviceClass, AudioDevice | None]:
        device = self.default_output()
        if device is None:
            return DeviceClass.UNKNOWN, None
        return self.classify(device), device