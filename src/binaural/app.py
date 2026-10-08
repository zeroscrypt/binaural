"""Qt entry point: ``binaural.app:main``.

Startup order matters (SPEC §4): create the app, show the window, then run the
headphone check as a queued callback so the window paints first.
"""

from __future__ import annotations

import sys

from PySide6.QtCore import QCoreApplication, QSettings, QTimer
from PySide6.QtWidgets import QApplication

from . import __version__, i18n
from .audio.headphones import HeadphoneReport, detect
from .core.engine import AudioEngine
from .core.oscillator import StereoOscillator
from .ui import theme
from .ui.main_window import MainWindow
from .ui.tray import TrayController

__all__ = ["UPDATE_CHECK_DELAY_MS", "main"]

#: How long after the window is up the update check starts.
#:
#: Long enough that the window has painted and the headphone dialog — which is the
#: first thing to interrupt a launch — has had its moment, so the two never open at
#: once: short enough that the check has finished before the user is deep in a
#: session.
UPDATE_CHECK_DELAY_MS = 1500


def _run_headphone_check(window: MainWindow) -> None:
    """Run the startup check of SPEC §4 and feed the result back into the window.

    Never fatal: the dialog is optional and the detection degrades to UNKNOWN,
    which the status indicator renders as "Unknown device".

    **Detection runs on every start; the dialog does not.** The user may have
    plugged in headphones since yesterday, and detection is a couple of device
    property reads — but a modal dialog on every single launch is exactly the nag
    §4.3 refuses to be. So the verdict always updates the status line, and the
    dialog opens only while the warning has not been confirmed yet (§4.3). Once it
    has, the check is re-run from *Settings* or from the Help menu.
    """
    try:
        report = detect()
        window.set_headphone_report(report)

        if report.is_headphones:
            # Nothing to warn about, and nothing to acknowledge.
            if not window.headphone_check_acknowledged():
                window.set_headphone_check_acknowledged(True)
            return

        if window.headphone_check_acknowledged():
            # Already warned once. The indicator still says "Speakers detected" for
            # as long as it is true — §4.3 wants the warning visible — but the user
            # is not nagged on every start.
            return

        dialog_class = window._dialog_class("HeadphoneCheckDialog")  # noqa: SLF001
        if dialog_class is None:
            return
        dialog = dialog_class(None, window._engine, window)  # noqa: SLF001
        dialog.exec()
        result = dialog.report()
        if isinstance(result, HeadphoneReport):
            window.set_headphone_report(result)
        window.set_headphone_check_acknowledged(bool(dialog.acknowledged()))
    except Exception:
        try:
            window.set_headphone_report(detect())
        except Exception:
            pass


def main(argv: list[str] | None = None) -> int:
    """Run the application. Returns the process exit code."""
    args = list(sys.argv if argv is None else argv)

    # The installer runs `binaural --version` to verify an install. It must answer on
    # stdout and exit; a window here would block that check until its timeout.
    if any(arg in ("--version", "-V") for arg in args[1:]):
        print(f"binaural {__version__}")
        return 0

    app = QApplication.instance()
    owns_app = app is None
    if app is None:
        app = QApplication(args)

    QCoreApplication.setOrganizationName("binaural")
    QCoreApplication.setApplicationName("binaural")
    QCoreApplication.setApplicationVersion(__version__)
    # Keep QSettings on the organisation/app pair used by core.session.
    QSettings.setDefaultFormat(QSettings.Format.IniFormat)

    # Language first: every widget below builds its captions with tr(), so the
    # choice has to land before the window exists. No listener is connected yet,
    # which is why the emitted language_changed is harmless here.
    i18n.set_language(i18n.resolve_initial_language())

    theme.apply_theme(app)

    oscillator = StereoOscillator()
    engine = AudioEngine(oscillator)
    window = MainWindow(engine, oscillator=oscillator)

    # Menu bar icon (macOS: next to the clock; Linux: system tray). It survives
    # a closed window, so only keep the process alive when the tray can bring
    # the window back — otherwise closing the last window must still quit.
    tray = TrayController(window, parent=app)
    if tray.is_available():
        app.setQuitOnLastWindowClosed(False)
    else:
        tray.dispose()

    # §4: check the headphones, but only after the window is on screen.
    window.show()
    QTimer.singleShot(0, lambda: _run_headphone_check(window))

    # The update check: the same silent background check, deferred the same way. It
    # runs on its own thread and shows a dialog only when a newer release exists; a
    # failure is silence. Deferred rather than immediate because a windowless process
    # would otherwise pop a dialog over nothing.
    QTimer.singleShot(UPDATE_CHECK_DELAY_MS, window.run_launch_update_check)

    if not owns_app:
        return 0
    return app.exec()


if __name__ == "__main__":  # pragma: no cover - manual launch
    sys.exit(main())