"""Qt entry point: ``binaural.app:main``.

Startup order matters (SPEC §4): create the app, show the window, then run the
headphone check as a queued callback so the window paints first.
"""

from __future__ import annotations

import sys

from PySide6.QtCore import QCoreApplication, QSettings, QTimer
from PySide6.QtWidgets import QApplication

from . import i18n
from .audio.headphones import HeadphoneReport, detect
from .core.engine import AudioEngine
from .core.oscillator import StereoOscillator
from .ui import theme
from .ui.main_window import MainWindow
from .ui.tray import TrayController

__all__ = ["main"]


def _run_headphone_check(window: MainWindow) -> None:
    """Show the startup check and feed the result back into the window.

    Never fatal: the dialog is optional and the detection degrades to UNKNOWN,
    which the status indicator renders as "Unknown device" (SPEC §4). The check
    is repeated every start — the user may have plugged in headphones since.
    """
    try:
        dialog_class = window._dialog_class("HeadphoneCheckDialog")  # noqa: SLF001
        if dialog_class is None:
            window.set_headphone_report(detect())
            return
        dialog = dialog_class(None, window._engine, window)  # noqa: SLF001
        dialog.exec()
        report = dialog.report()
        if isinstance(report, HeadphoneReport):
            window.set_headphone_report(report)
    except Exception:
        try:
            window.set_headphone_report(detect())
        except Exception:
            pass


def main(argv: list[str] | None = None) -> int:
    """Run the application. Returns the process exit code."""
    args = list(sys.argv if argv is None else argv)

    app = QApplication.instance()
    owns_app = app is None
    if app is None:
        app = QApplication(args)

    QCoreApplication.setOrganizationName("binaural")
    QCoreApplication.setApplicationName("binaural")
    QCoreApplication.setApplicationVersion("0.1.0")
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

    if not owns_app:
        return 0
    return app.exec()


if __name__ == "__main__":  # pragma: no cover - manual launch
    sys.exit(main())