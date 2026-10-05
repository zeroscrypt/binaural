"""Dialog tests (SPEC §4, §6.12, §6.13, §7).

A single QApplication is shared for the whole session. If Qt cannot open any
display the session is skipped rather than failed — a headless machine without
the offscreen platform plugin still needs a green suite.
"""

from __future__ import annotations

import os
import time

import pytest

# The offscreen platform keeps the suite runnable without a window server.
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QEventLoop, QObject, Qt, Signal  # noqa: E402
from PySide6.QtGui import QKeyEvent  # noqa: E402
from PySide6.QtWidgets import (  # noqa: E402
    QApplication,
    QDialog,
    QLabel,
    QLineEdit,
    QPushButton,
)

from binaural import __version__  # noqa: E402
from binaural.audio.headphones import (  # noqa: E402
    HeadphoneReport,
    LrTestResult,
)
from binaural.audio.platform.base import AudioDevice, DeviceClass  # noqa: E402
from binaural.core.oscillator import beat_frequency, pair_from_beat  # noqa: E402
from binaural.data.frequencies import search  # noqa: E402
from binaural.ui.dialogs import (  # noqa: E402
    MIN_CONTRAST,
    MIN_TOUCH_PX,
    AboutDialog,
    HeadphoneCheckDialog,
    LrTestDialog,
    ReferenceDialog,
    contrast_ratio,
    resolve_theme,
)
from binaural.ui.dialogs.reference import frequencies_for  # noqa: E402

HEADPHONES_DEVICE = AudioDevice("AirPods Pro", "bluetooth", True)
SPEAKERS_DEVICE = AudioDevice("Динамики Mac mini", "builtin", True)


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------


@pytest.fixture(scope="session")
def qapp():
    app = QApplication.instance()
    if app is None:
        try:
            app = QApplication([])
        except Exception as exc:  # pragma: no cover - depends on the machine
            pytest.skip(f"No usable Qt display: {exc}")
    yield app


class FakeEngine(QObject):
    """Minimal AudioEngine stand-in: hard-panned tones, no hardware."""

    error = Signal(str)

    def __init__(self) -> None:
        super().__init__()
        self.running = False
        self.events: list[object] = []

    @property
    def oscillator(self) -> None:
        return None

    @property
    def is_running(self) -> bool:
        return self.running

    def play_left_tone(self, freq_hz: float, seconds: float) -> None:
        self.events.append(("left", freq_hz, seconds))
        self.running = True

    def play_right_tone(self, freq_hz: float, seconds: float) -> None:
        self.events.append(("right", freq_hz, seconds))
        self.running = True

    def start(self) -> bool:
        self.events.append("start")
        self.running = True
        return True

    def stop(self) -> None:
        self.events.append("stop")
        self.running = False


class BrokenEngine(QObject):
    """Engine whose every audio call raises — the dialog must survive it."""

    error = Signal(str)

    @property
    def oscillator(self) -> None:
        return None

    @property
    def is_running(self) -> bool:
        return False

    def start(self) -> bool:
        raise RuntimeError("no device")

    def stop(self) -> None:
        raise RuntimeError("no device")


def _wait_until(predicate, timeout: float = 3.0) -> bool:
    """Spin the event loop until ``predicate`` holds or the timeout expires."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        QApplication.processEvents(QEventLoop.ProcessEventsFlag.AllEvents, 10)
        time.sleep(0.005)
    QApplication.processEvents(QEventLoop.ProcessEventsFlag.AllEvents, 10)
    return bool(predicate())


def _key_event(key: Qt.Key) -> QKeyEvent:
    return QKeyEvent(QKeyEvent.Type.KeyPress, key, Qt.KeyboardModifier.NoModifier)


def _escape_event() -> QKeyEvent:
    return _key_event(Qt.Key.Key_Escape)


def _labels_text(widget) -> str:
    """All label texts of a widget, for content assertions."""
    return "\n".join(label.text() for label in widget.findChildren(QLabel))


def _buttons(dialog) -> list[QPushButton]:
    return dialog.findChildren(QPushButton)


def _button(dialog, text: str) -> QPushButton:
    for button in _buttons(dialog):
        if button.text() == text:
            return button
    raise AssertionError(f"no button labelled {text!r} in {dialog}")


@pytest.fixture()
def engine(qapp) -> FakeEngine:
    return FakeEngine()


@pytest.fixture(autouse=True)
def _clean_windows(qapp):
    """Close and destroy anything a test showed.

    Dialogs are top-level windows; a leftover one keeps the keyboard focus and
    would make an unrelated focus-sensitive test flaky.
    """
    yield
    app = QApplication.instance()
    if app is None:  # pragma: no cover - the app outlives the session
        return
    for widget in list(app.topLevelWidgets()):
        if widget is app or widget.parent() is not None:
            continue
        widget.close()
        widget.setFocus()
        widget.clearFocus()
        widget.deleteLater()
    app.processEvents()


# --------------------------------------------------------------------------
# All dialogs build without exceptions
# --------------------------------------------------------------------------


def test_about_dialog_creates(qapp):
    dialog = AboutDialog()
    assert dialog.isVisible() is False
    assert dialog.windowTitle()


def test_headphone_check_dialog_creates(qapp):
    dialog = HeadphoneCheckDialog(HeadphoneReport(DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high"))
    assert dialog.isModal() is True
    assert dialog.windowTitle()


def test_lr_test_dialog_creates(qapp, engine):
    dialog = LrTestDialog(engine)
    assert dialog.isModal() is True
    assert dialog.asking is False


def test_reference_dialog_creates(qapp):
    dialog = ReferenceDialog()
    assert dialog.isModal() is True
    assert dialog.visible_entries


# --------------------------------------------------------------------------
# Headphone check (SPEC §4.3)
# --------------------------------------------------------------------------


def test_continue_anyway_is_never_disabled(qapp):
    """SPEC §4.3: the button must always work — it is not a gate."""
    for verdict, device, confidence in (
        (DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high"),
        (DeviceClass.UNKNOWN, None, "low"),
        (DeviceClass.VIRTUAL, None, "low"),
        (DeviceClass.HEADPHONES, HEADPHONES_DEVICE, "high"),
    ):
        dialog = HeadphoneCheckDialog(HeadphoneReport(verdict, device, confidence))
        assert dialog.continue_button_enabled is True
        assert _button(dialog, "Continue anyway").isEnabled() is True


def test_continue_anyway_sets_acknowledged(qapp):
    dialog = HeadphoneCheckDialog(HeadphoneReport(DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high"))
    assert dialog.acknowledged is False

    _button(dialog, "Continue anyway").click()
    assert dialog.acknowledged is True
    assert dialog.result() == HeadphoneCheckDialog.DialogCode.Accepted


def test_retry_keeps_continue_enabled(qapp):
    dialog = HeadphoneCheckDialog(HeadphoneReport(DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high"))
    _button(dialog, "Retry check").click()
    assert dialog.continue_button_enabled is True
    assert isinstance(dialog.report(), HeadphoneReport)


def test_escape_does_not_acknowledge(qapp):
    dialog = HeadphoneCheckDialog(HeadphoneReport(DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high"))
    dialog.reject()
    assert dialog.acknowledged is False


def test_fake_headphone_report_shows_verdict(qapp):
    report = HeadphoneReport(DeviceClass.HEADPHONES, HEADPHONES_DEVICE, "high")
    dialog = HeadphoneCheckDialog(report, detect_now=False)

    assert dialog.is_headphones is True
    assert dialog.channels_swapped is False
    text = _labels_text(dialog)
    assert "Headphones detected" in text
    assert "AirPods Pro" in text
    assert "High" in text


def test_speaker_report_shows_speakers_warning(qapp):
    report = HeadphoneReport(DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high")
    dialog = HeadphoneCheckDialog(report, detect_now=False)

    assert dialog.is_headphones is False
    assert "Speakers detected" in dialog.status_text
    # Icon and words, never colour alone (SPEC §7.2).
    assert any(icon in dialog.status_text for icon in ("⚠", "✓", "?", "◐"))


def test_explains_why_headphones_are_needed(qapp):
    dialog = HeadphoneCheckDialog(HeadphoneReport(DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high"))
    text = _labels_text(dialog)
    assert "only work when each ear receives its own tone" in text
    assert "mix in the air" in text
    # The escape hatch is a real, enabled button (SPEC §4.3).
    assert _button(dialog, "Continue anyway").isEnabled() is True
    assert _button(dialog, "Retry check").isEnabled() is True


def test_lr_result_swapped_is_remembered(qapp):
    report = HeadphoneReport(DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high")
    dialog = HeadphoneCheckDialog(report, detect_now=False)

    dialog.set_lr_result(LrTestResult.RIGHT_THEN_LEFT)

    assert dialog.channels_swapped is True
    assert dialog.lr_result is LrTestResult.RIGHT_THEN_LEFT
    assert dialog.is_headphones is True
    assert "swapped" in _labels_text(dialog)


@pytest.mark.parametrize(
    "result, is_headphones, swapped",
    [
        (LrTestResult.LEFT_THEN_RIGHT, True, False),
        (LrTestResult.RIGHT_THEN_LEFT, True, True),
        (LrTestResult.INDETERMINATE, False, False),
    ],
)
def test_set_lr_result_matches_the_contract(qapp, result, is_headphones, swapped):
    """The dialog must expose exactly what HeadphoneReport exposes."""
    dialog = HeadphoneCheckDialog(
        HeadphoneReport(DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high"), detect_now=False
    )
    dialog.set_lr_result(result)

    assert dialog.is_headphones is is_headphones
    assert dialog.channels_swapped is swapped
    assert dialog.report().channels_swapped is swapped
    assert dialog.lr_result is result


def test_broken_detection_does_not_crash(qapp, monkeypatch):
    import binaural.ui.dialogs.headphone_check as module

    def boom(*_args, **_kwargs):
        raise RuntimeError("no audio subsystem")

    monkeypatch.setattr(module, "detect", boom)
    dialog = HeadphoneCheckDialog(None)

    assert isinstance(dialog.report(), HeadphoneReport)
    assert dialog.continue_button_enabled is True


def test_report_is_callable_for_main_window(qapp):
    """``main_window.py`` calls ``dialog.report()``; keep that contract."""
    dialog = HeadphoneCheckDialog(
        HeadphoneReport(DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high"), detect_now=False
    )
    assert dialog.report() is dialog.headphone_report
    assert isinstance(dialog.report(), HeadphoneReport)


def test_dialogs_are_discoverable_from_the_dialogs_package(qapp):
    """``main_window.py`` resolves the classes by name from this package."""
    import binaural.ui.dialogs as dialogs

    for name in ("HeadphoneCheckDialog", "ReferenceDialog", "AboutDialog"):
        assert isinstance(getattr(dialogs, name), type)
    assert issubclass(dialogs.ReferenceDialog, QDialog)


# --------------------------------------------------------------------------
# L/R test (SPEC §4.2)
# --------------------------------------------------------------------------


def test_play_test_starts_the_sequence(qapp, engine):
    dialog = LrTestDialog(engine, tone_seconds=0.01, gap_seconds=0.01)
    dialog.show()
    dialog.start_test()

    assert dialog.sequence is not None
    assert dialog.sequence.step == "left"
    # Icon + words, so the step is legible without colour (SPEC §7.2).
    assert "Playing in LEFT ear…" in dialog.step_text
    assert _wait_until(lambda: dialog.asking)
    assert "What did you hear?" in dialog.step_text


def test_lr_steps_have_icon_and_words(qapp, engine):
    """Every step states itself in words; colour is never the only signal."""
    dialog = LrTestDialog(engine, tone_seconds=0.01, gap_seconds=0.01)
    dialog.show()

    dialog.start_test()
    texts: list[str] = []
    dialog.sequence.step_changed.connect(lambda _step: texts.append(dialog.step_text))
    assert _wait_until(lambda: dialog.asking)

    # "Playing in LEFT ear…" -> "Pause…" -> "Playing in RIGHT ear…" -> question
    assert len(texts) == 3
    assert "Pause…" in texts[0]
    assert "Playing in RIGHT ear…" in texts[1]
    text = dialog.step_text
    assert "What did you hear?" in text
    # Every rendered step line starts with a marker character, never colour only.
    assert text.strip()[0] in "\u25c0\u25b6\u2014?\u2713\u25cb"
    assert all(line.strip() for line in texts)


def test_sequence_visits_every_step(qapp, engine):
    dialog = LrTestDialog(engine, tone_seconds=0.01, gap_seconds=0.01)
    steps: list[str] = []
    dialog.show()
    dialog.start_test()
    dialog.sequence.step_changed.connect(steps.append)
    assert _wait_until(lambda: dialog.asking)

    assert steps == ["pause", "right", "answer"]
    assert [event[0] for event in engine.events if isinstance(event, tuple)] == ["left", "right"]


@pytest.mark.parametrize(
    "result, text",
    [
        (LrTestResult.LEFT_THEN_RIGHT, "Left → Right"),
        (LrTestResult.RIGHT_THEN_LEFT, "Right → Left"),
        (LrTestResult.INDETERMINATE, "Both at once / Can't tell"),
    ],
)
def test_three_answer_buttons(qapp, engine, result, text):
    dialog = LrTestDialog(engine)
    button = dialog.answer_button(result)

    assert button.text() == text
    assert button.isEnabled() is True
    assert button.minimumHeight() >= MIN_TOUCH_PX


def test_answer_buttons_are_hidden_until_the_question(qapp, engine):
    dialog = LrTestDialog(engine)
    for result in LrTestResult:
        assert dialog.answer_button(result).isHidden() is True
    assert dialog.asking is False


def test_answer_left_then_right_confirms_channels(qapp, engine):
    dialog = LrTestDialog(engine)
    dialog.answer(LrTestResult.LEFT_THEN_RIGHT)

    assert dialog.lr_result is LrTestResult.LEFT_THEN_RIGHT
    assert dialog.channels_swapped is False
    assert dialog.is_headphones is True
    assert dialog.result() == LrTestDialog.DialogCode.Accepted


def test_answer_right_then_left_marks_channels_swapped(qapp, engine):
    dialog = LrTestDialog(engine)
    dialog.answer_button(LrTestResult.RIGHT_THEN_LEFT).click()

    assert dialog.lr_result is LrTestResult.RIGHT_THEN_LEFT
    assert dialog.channels_swapped is True
    assert dialog.is_headphones is True
    assert "swapped" in _labels_text(dialog)


def test_answer_indeterminate_means_speakers(qapp, engine):
    dialog = LrTestDialog(engine)
    dialog.answer(LrTestResult.INDETERMINATE)

    assert dialog.lr_result is LrTestResult.INDETERMINATE
    assert dialog.channels_swapped is False
    assert dialog.is_headphones is False


def test_answered_signal_emits_once(qapp, engine):
    dialog = LrTestDialog(engine)
    seen: list[object] = []
    dialog.answered.connect(seen.append)
    dialog.answer(LrTestResult.LEFT_THEN_RIGHT)
    dialog.answer(LrTestResult.RIGHT_THEN_LEFT)

    assert seen == [LrTestResult.LEFT_THEN_RIGHT]


def test_close_stops_the_sequence(qapp, engine):
    """A tone must never outlive the dialog."""
    dialog = LrTestDialog(engine, tone_seconds=0.01, gap_seconds=0.01)
    dialog.show()
    dialog.start_test()
    assert dialog.sequence.step == "left"

    dialog.close()
    assert dialog.sequence.step == "idle"
    assert engine.running is False
    assert engine.events.count("stop") >= 1


def test_reject_stops_the_sequence(qapp, engine):
    dialog = LrTestDialog(engine, tone_seconds=0.01, gap_seconds=0.01)
    dialog.show()
    dialog.start_test()

    dialog.reject()
    assert dialog.sequence.step == "idle"
    assert engine.running is False


def test_answer_stops_the_sequence(qapp, engine):
    dialog = LrTestDialog(engine, tone_seconds=0.01, gap_seconds=0.01)
    dialog.show()
    dialog.start_test()

    dialog.answer(LrTestResult.LEFT_THEN_RIGHT)
    assert dialog.sequence.step == "idle"
    assert engine.running is False


def test_missing_engine_shows_error_text(qapp):
    dialog = LrTestDialog(None)
    dialog.start_test()

    assert dialog.has_error is True
    assert "audio output" in dialog.error_text
    assert dialog.sequence is None


def test_broken_engine_shows_error_text(qapp):
    dialog = LrTestDialog(BrokenEngine())
    dialog.show()
    dialog.start_test()  # must not raise

    assert dialog.has_error is True
    assert dialog.error_text


def test_engine_error_signal_is_surfaced(qapp, engine):
    dialog = LrTestDialog(engine)
    dialog.show()
    engine.error.emit("Device disappeared")

    assert dialog.has_error is True
    assert "Device disappeared" in dialog.error_text


def test_answer_before_play_is_still_recorded(qapp, engine):
    dialog = LrTestDialog(engine)
    dialog.answer(LrTestResult.RIGHT_THEN_LEFT)

    assert dialog.lr_result is LrTestResult.RIGHT_THEN_LEFT
    assert dialog.channels_swapped is True


# --------------------------------------------------------------------------
# Reference (SPEC §6.12, §6.13)
# --------------------------------------------------------------------------


def test_reference_shows_every_category_with_counts(qapp):
    dialog = ReferenceDialog()
    ids = dialog.category_ids()
    counts = dialog.category_counts()

    assert ids[0] == ""  # "All categories" first
    assert "brainwave" in ids and "solfeggio" in ids and "healing" in ids
    assert len(ids) == len(counts) + 1
    assert all(count > 0 for count in counts.values())
    # Registry order, not alphabetical (SPEC §6.1).
    assert ids[1:4] == ["brainwave", "schumann", "planetary"]


def test_reference_sidebar_shows_icon_and_count(qapp):
    dialog = ReferenceDialog()
    texts = [dialog.category_list.item(row).text() for row in range(dialog.category_list.count())]

    assert any(text.startswith("\U0001F9E0") for text in texts)  # 🧠
    brainwave = next(text for text in texts if "Brainwave" in text)
    assert brainwave.endswith(f"({dialog.category_counts()['brainwave']})")


def test_reference_lists_all_entries_by_default(qapp):
    dialog = ReferenceDialog()
    assert len(dialog.visible_entries) == sum(dialog.category_counts().values())
    assert dialog.evidence_filter is None  # nothing hidden by default


def test_reference_search_filters_entries(qapp):
    dialog = ReferenceDialog()

    dialog.set_query("alpha")
    ids = dialog.visible_entry_ids
    assert ids, "search must find something"
    assert all("alpha" in entry.label.lower() or entry.id in ids for entry in dialog.visible_entries)
    assert len(ids) < sum(dialog.category_counts().values())

    dialog.set_query("7.83")
    assert "schumann-7-83" in dialog.visible_entry_ids

    dialog.set_query("no-such-frequency")
    assert dialog.visible_entries == []


def test_reference_category_filter(qapp):
    dialog = ReferenceDialog()
    dialog.select_category("solfeggio")

    assert dialog.selected_category == "solfeggio"
    assert {entry.category for entry in dialog.visible_entries} == {"solfeggio"}
    assert len(dialog.visible_entries) == dialog.category_counts()["solfeggio"]

    dialog.select_category(None)
    assert dialog.selected_category is None
    assert len(dialog.visible_entries) == sum(dialog.category_counts().values())


def test_reference_search_within_category(qapp):
    dialog = ReferenceDialog()
    dialog.select_category("solfeggio")
    dialog.set_query("528")

    assert len(dialog.visible_entries) == 1
    assert dialog.visible_entries[0].id == "solfeggio-528"


def test_reference_sorts_ranges_first_then_by_beat(qapp):
    dialog = ReferenceDialog()
    dialog.select_category("brainwave")
    entries = dialog.visible_entries

    ranged = [index for index, entry in enumerate(entries) if entry.is_range]
    ranged_only = [index for index, entry in enumerate(entries) if not entry.is_range]
    assert ranged, "brainwave has range records"
    assert max(ranged) < min(ranged_only), "ranges must come first"

    keys = [entry.sort_key for entry in entries]
    assert keys == sorted(keys)


def test_reference_evidence_filter_hides_nothing_by_default(qapp):
    dialog = ReferenceDialog()
    total = sum(dialog.category_counts().values())

    assert len(dialog.visible_entries) == total

    dialog.set_evidence("well-studied")
    shown = dialog.visible_entries
    assert shown and all(entry.evidence == "well-studied" for entry in shown)
    assert len(shown) < total

    dialog.set_evidence(None)
    assert len(dialog.visible_entries) == total


def test_reference_card_shows_data(qapp):
    dialog = ReferenceDialog()
    entry = next(e for e in dialog.visible_entries if e.id == "brainwave-alpha")
    dialog.select_category("brainwave")
    dialog.set_query("Alpha 8")

    card = dialog.entry_card("brainwave-alpha")
    assert card is not None
    text = _labels_text(card)
    assert "Alpha 8–13 Hz" in text
    assert entry.frequency_text() in text
    assert entry.badge in text
    assert entry.source.split("(")[0].strip()[:20] in text
    # The Russian effect stays available on hover.
    assert entry.effect_ru != ""
    assert entry.effect_en in text


def test_reference_apply_emits_pair_from_beat(qapp):
    dialog = ReferenceDialog()
    emitted: list[tuple[float, float]] = []
    dialog.apply_frequencies.connect(lambda left, right: emitted.append((left, right)))

    dialog.select_category("brainwave")
    dialog.set_query("Alpha 8")
    assert "brainwave-alpha" in dialog.visible_entry_ids
    card = dialog.entry_card("brainwave-alpha")
    _button(card, "Apply").click()

    assert len(emitted) == 1
    left, right = emitted[0]
    entry = next(e for e in dialog.visible_entries if e.id == "brainwave-alpha")
    # "Alpha 8–13 Hz" is a range: Apply realises its middle, 10.5 Hz.
    assert entry.is_range is True
    expected_beat = (entry.beat_min + entry.beat_max) / 2
    assert left == pytest.approx(pair_from_beat(expected_beat, entry.carrier_hz)[0])
    assert right == pytest.approx(pair_from_beat(expected_beat, entry.carrier_hz)[1])
    assert beat_frequency(left, right) == pytest.approx(expected_beat)


def test_reference_apply_for_range_uses_midpoint(qapp):
    dialog = ReferenceDialog()
    emitted: list[tuple[float, float]] = []
    dialog.apply_frequencies.connect(lambda left, right: emitted.append((left, right)))

    entry = next(e for e in search("Delta") if e.is_range)
    dialog.apply_entry(entry)

    assert emitted == [frequencies_for(entry)]
    left, right = emitted[0]
    midpoint = (entry.beat_min + entry.beat_max) / 2
    assert beat_frequency(left, right) == pytest.approx(midpoint)


def test_reference_apply_for_tonal_entry_uses_carrier(qapp):
    dialog = ReferenceDialog()
    emitted: list[tuple[float, float]] = []
    dialog.apply_frequencies.connect(lambda left, right: emitted.append((left, right)))

    entry = next(e for e in dialog.visible_entries if e.is_tonal)
    left, right = dialog.apply_entry(entry)

    assert emitted == [(left, right)]
    # A tonal record holds a tone, not a difference: it becomes the carrier and
    # the beat stays small, so "528 Hz" is not played as a 528 Hz difference.
    assert (left + right) / 2 == pytest.approx(entry.beat_hz, abs=0.01)
    assert beat_frequency(left, right) == pytest.approx(10.0)


def test_reference_apply_respects_the_audible_range(qapp):
    dialog = ReferenceDialog()
    emitted: list[tuple[float, float]] = []
    dialog.apply_frequencies.connect(lambda left, right: emitted.append((left, right)))

    for entry in dialog.visible_entries:
        left, right = dialog.apply_entry(entry)
        assert 1.0 <= left <= 20000.0, entry.id
        assert 1.0 <= right <= 20000.0, entry.id

    assert len(emitted) == sum(dialog.category_counts().values())


def test_reference_apply_button_on_every_card(qapp):
    dialog = ReferenceDialog()
    dialog.select_category("solfeggio")
    for entry in dialog.visible_entries:
        card = dialog.entry_card(entry.id)
        assert card is not None
        button = _button(card, "Apply")
        assert button.isEnabled() is True
        assert button.minimumHeight() >= MIN_TOUCH_PX


def test_reference_contains_disclaimer(qapp):
    dialog = ReferenceDialog()
    assert "not a medical device" in dialog.disclaimer_text
    assert "epilepsy" in dialog.disclaimer_text
    assert dialog.disclaimer_visible is True


def test_reference_disclaimer_can_be_hidden(qapp):
    dialog = ReferenceDialog()
    dialog.set_disclaimer_visible(False)
    assert dialog.disclaimer_visible is False
    dialog.set_disclaimer_visible(True)
    assert dialog.disclaimer_visible is True


def test_reference_card_apply_button_is_per_card(qapp):
    """Each card owns its own Apply button, so a click cannot hit a neighbour."""
    dialog = ReferenceDialog()
    dialog.select_category("solfeggio")
    dialog.set_query("528")

    card = dialog.entry_card("solfeggio-528")
    assert card is not None
    button = _button(card, "Apply")
    emitted: list[tuple[float, float]] = []
    dialog.apply_frequencies.connect(lambda left, right: emitted.append((left, right)))

    button.click()
    entry = next(e for e in dialog.visible_entries if e.id == "solfeggio-528")
    assert emitted == [frequencies_for(entry)]
    assert button.toolTip()  # explains what Apply will set


def test_reference_is_keyboard_reachable(qapp):
    dialog = ReferenceDialog()
    dialog.show()

    assert dialog.search_field.focusPolicy() & Qt.FocusPolicy.TabFocus
    assert dialog.category_list.focusPolicy() & Qt.FocusPolicy.TabFocus
    assert dialog.evidence_combo.focusPolicy() & Qt.FocusPolicy.TabFocus


def test_reference_escape_closes(qapp):
    dialog = ReferenceDialog()
    dialog.show()
    dialog.reject()
    assert dialog.result() == ReferenceDialog.DialogCode.Rejected


# --------------------------------------------------------------------------
# About (SPEC §6.13)
# --------------------------------------------------------------------------


def test_about_contains_version(qapp):
    dialog = AboutDialog()
    assert __version__ in dialog.version_text
    assert dialog.version == __version__


def test_about_contains_github_link(qapp):
    dialog = AboutDialog()
    assert dialog.project_url == "https://github.com/zeroscrypt/binaural"
    assert dialog.project_url in _labels_text(dialog)


def test_about_link_reaches_the_browser(qapp, monkeypatch):
    """The URL is shown, selectable and openable without a copy-paste."""
    dialog = AboutDialog()
    label = next(
        label
        for label in dialog.findChildren(QLabel)
        if "github.com" in label.text()
    )
    opened: list[str] = []
    monkeypatch.setattr("binaural.ui.dialogs.open_url", opened.append)

    button = _button(dialog, "Open project page")
    button.click()

    assert opened == ["https://github.com/zeroscrypt/binaural"]
    assert label.openExternalLinks() is True
    assert label.toolTip() == dialog.project_url


def test_about_contains_full_disclaimer(qapp):
    dialog = AboutDialog()
    text = dialog.disclaimer_text

    assert "not a medical device" in text
    assert "diagnosis, treatment or prevention" in text
    assert "epilepsy" in text and "pacemaker" in text
    assert "pregnancy" in text
    assert "photosensitive" in text
    assert "consulting a doctor" in text
    assert "comfortable level" in text


def test_about_contains_mit_licence(qapp):
    dialog = AboutDialog()
    text = _labels_text(dialog)

    assert "MIT License" in text
    assert "Copyright (c) 2026 Dmitriy Solontsov" in text
    assert "without warranty of any kind" in text


# --------------------------------------------------------------------------
# Shared design rules (SPEC §7.1, §7.2)
# --------------------------------------------------------------------------


@pytest.mark.parametrize("dark", [False, True])
def test_theme_tokens_meet_contrast_rules(qapp, dark):
    """SPEC §7.2 in both themes, using the theme module when it is present."""
    from binaural.ui.dialogs import _resolve

    theme = _resolve(dark)
    background = theme.background

    assert contrast_ratio(theme.foreground, background) >= MIN_CONTRAST
    assert contrast_ratio(theme.muted, background) >= MIN_CONTRAST
    assert contrast_ratio(theme.warning_text, background) >= MIN_CONTRAST
    assert contrast_ratio(theme.destructive_text, background) >= MIN_CONTRAST
    # A filled button must clear the bar against its own fill, not against accent.
    assert contrast_ratio(theme.on_accent, theme.accent_fill) >= MIN_CONTRAST


def test_dialogs_use_the_shared_theme(qapp):
    """Dialogs inherit ui/theme.py when it exists, and work without it."""
    from binaural.ui.dialogs import _resolve

    theme = resolve_theme()
    dialog = ReferenceDialog()
    assert theme.background in dialog.styleSheet()


def test_dialogs_work_without_theme_module(qapp, monkeypatch):
    """theme.py is optional: the local SPEC fallbacks must carry the dialogs."""
    import binaural.ui.dialogs as dialogs

    def no_theme():
        return None

    monkeypatch.setattr(dialogs, "_theme_module", no_theme)
    monkeypatch.setattr(dialogs, "_resolve", dialogs._resolve.__wrapped__)
    monkeypatch.setattr(dialogs, "resolve_theme", lambda widget=None: dialogs._resolve(False))

    dialog = AboutDialog()
    assert "#FAF5FF" in dialog.styleSheet()  # SPEC §7.1 light background
    assert dialog.disclaimer_text


def test_dialogs_work_without_theme_module_in_dark_mode(qapp, monkeypatch):
    """The dark fallback is picked from the palette, not hardcoded light."""
    import binaural.ui.dialogs as dialogs

    monkeypatch.setattr(dialogs, "_theme_module", lambda: None)
    monkeypatch.setattr(dialogs, "_resolve", dialogs._resolve.__wrapped__)

    dark = dialogs._resolve(True)
    assert dark.is_dark is True
    assert dark.background == "#151221"
    assert contrast_ratio(dark.foreground, dark.background) >= MIN_CONTRAST


def test_dialogs_use_minimum_touch_targets(qapp):
    for dialog in (AboutDialog(), HeadphoneCheckDialog(None), LrTestDialog(None), ReferenceDialog()):
        for button in _buttons(dialog):
            assert button.minimumHeight() >= MIN_TOUCH_PX, button.text()


def test_dialogs_keep_a_focus_ring(qapp):
    dialog = ReferenceDialog()
    sheet = dialog.styleSheet()

    assert ":focus" in sheet, "focus rings must be styled, not removed"
    assert "QPushButton:focus" in sheet
    assert sheet.count(":focus") >= 4
    # Every interactive element class gets a ring.
    for selector in ("QLineEdit:focus", "QComboBox:focus", "QListWidget:focus"):
        assert selector in sheet


def test_dialogs_are_escapable(qapp, engine):
    """Escape closes every modal (SPEC §7.2)."""
    for dialog in (
        AboutDialog(),
        HeadphoneCheckDialog(HeadphoneReport(DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high")),
        LrTestDialog(engine),
        ReferenceDialog(),
    ):
        dialog.show()
        assert dialog.isModal() is True
        dialog.keyPressEvent(_escape_event())
        assert dialog.result() == dialog.DialogCode.Rejected
        assert dialog.isVisible() is False


def _tab_focusables(dialog) -> list:
    """Widgets Tab actually visits, in chain order.

    ``nextInFocusChain`` walks every widget, including the read-only labels
    between the controls, so the non-focusable ones are filtered out here.
    """
    seen: list = []
    widget = dialog
    while True:
        widget = widget.nextInFocusChain()
        if widget is None or widget is dialog:
            return seen
        if widget.focusPolicy() & Qt.FocusPolicy.TabFocus:
            seen.append(widget)


def _tab_next(dialog, widget):
    """The widget Tab moves to from ``widget``."""
    order = _tab_focusables(dialog)
    index = order.index(widget)
    return order[(index + 1) % len(order)]


def _platform_grants_focus(qapp) -> bool:
    """False on plugins like ``minimal`` that have no window manager.

    Focus handling is still implemented there; it just cannot be observed.
    """
    probe = QPushButton("probe")
    probe.show()
    QApplication.processEvents()
    granted = QApplication.focusWidget() is not None
    probe.hide()
    probe.deleteLater()
    return granted


def test_dialogs_start_focused_on_an_action(qapp, engine):
    """Focus must land on a real control, not on read-only body text."""
    if not _platform_grants_focus(qapp):
        pytest.skip("The Qt platform plugin does not grant keyboard focus")

    dialogs = {
        "AboutDialog": AboutDialog(),
        "ReferenceDialog": ReferenceDialog(),
        "LrTestDialog": LrTestDialog(engine),
        "HeadphoneCheckDialog": HeadphoneCheckDialog(
            HeadphoneReport(DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high")
        ),
    }

    for name, dialog in dialogs.items():
        dialog.show()
        QApplication.processEvents()
        focus = QApplication.focusWidget()

        # Focus must be on a real control, never on read-only body text.
        assert focus is not None, name
        assert isinstance(focus, (QPushButton, QLineEdit)), f"{name}: {type(focus).__name__}"


def test_reference_starts_focused_on_search(qapp):
    if not _platform_grants_focus(qapp):
        pytest.skip("The Qt platform plugin does not grant keyboard focus")

    dialog = ReferenceDialog()
    dialog.show()
    QApplication.processEvents()
    # Search first: it is the most common reason to open the reference.
    assert QApplication.focusWidget() is dialog.search_field


def test_focus_order_follows_the_task(qapp, engine):
    """Tab order is explicit, not left to widget creation order."""
    reference = ReferenceDialog()
    assert _tab_next(reference, reference.search_field) is reference.evidence_combo
    assert _tab_next(reference, reference.evidence_combo) is reference.category_list
    assert _tab_next(reference, reference.category_list) is reference._disclaimer_button

    lr = LrTestDialog(engine)
    assert _tab_next(lr, lr._play_button) is lr._close_button

    headphone = HeadphoneCheckDialog(
        HeadphoneReport(DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high")
    )
    assert _tab_next(headphone, headphone._lr_button) is headphone._retry_button
    assert _tab_next(headphone, headphone._retry_button) is headphone._continue_button


def test_reference_navigates_with_arrow_keys(qapp):
    """Arrow keys move the category selection (SPEC §7.2)."""
    dialog = ReferenceDialog()
    dialog.show()
    dialog.category_list.setFocus()
    dialog.category_list.setCurrentRow(0)

    for expected in ("brainwave", "schumann", "planetary"):
        QApplication.sendEvent(
            dialog.category_list, _key_event(Qt.Key.Key_Down)
        )
        assert dialog.selected_category == expected
