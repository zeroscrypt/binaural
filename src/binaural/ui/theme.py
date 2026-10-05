"""Design tokens, palettes and stylesheets (SPEC §7.1).

Single source of truth for colour, type and rhythm. ``LIGHT``/``DARK`` hold the
exact tokens from SPEC §7.1 plus a few derived tokens that exist only so text
stays above the 4.5:1 contrast floor on the app background.

Typography uses the platform UI font (SF on macOS, Inter/DejaVu on Linux) — no
font file is shipped, so the app looks native on both.
"""

from __future__ import annotations

import os
import subprocess
import sys
from functools import lru_cache

from PySide6.QtCore import QSettings, Qt
from PySide6.QtGui import QColor, QFont, QPalette
from PySide6.QtWidgets import QApplication, QWidget

__all__ = [
    "TOKENS",
    "LIGHT",
    "DARK",
    "RADIUS",
    "RADIUS_SM",
    "SPACE_XS",
    "SPACE_SM",
    "SPACE_MD",
    "SPACE_LG",
    "SPACE_XL",
    "FONT_SIZES",
    "FONT_WEIGHTS",
    "ENV_REDUCED_MOTION",
    "tokens",
    "color",
    "font",
    "font_family",
    "build_palette",
    "build_stylesheet",
    "apply_theme",
    "prefers_dark",
    "reduced_motion",
    "animations_enabled",
]

_CONTEXT = "Theme"

#: Environment override, handy for tests and for users who want no motion at all.
ENV_REDUCED_MOTION = "BINAURAL_REDUCED_MOTION"

#: token -> (light, dark), exactly as in SPEC §7.1.
TOKENS: dict[str, tuple[str, str]] = {
    "primary": ("#7C3AED", "#A78BFA"),  # left channel, main accents
    "secondary": ("#8B5CF6", "#C4B5FD"),  # right channel
    "accent": ("#059669", "#34D399"),  # play button, confirmations
    "background": ("#FAF5FF", "#151221"),
    "surface": ("#FFFFFF", "#1E1A2E"),
    "foreground": ("#0F172A", "#F1EDFF"),
    "muted-fg": ("#475569", "#A5A0BE"),
    "border": ("#EFE7FC", "#322B4A"),
    "warning": ("#D97706", "#FBBF24"),
    "destructive": ("#DC2626", "#F87171"),
    "ring": ("#7C3AED", "#A78BFA"),
}

# Derived tokens. They never replace a SPEC token, they only make text that
# sits on `background` reach WCAG AA (4.5:1).
_DERIVED_LIGHT: dict[str, str] = {
    "surface-alt": "#F4EEFF",  # toolbars, subtle fills
    "accent-strong": "#047857",  # filled button background
    "warning-text": "#92400E",  # warning copy on background
    "destructive-strong": "#B91C1C",
    "on-accent": "#FFFFFF",  # text on a filled accent button
    "focus-soft": "#EFE7FC",
    # secondary (#8B5CF6) is only 3.9:1 on white; copy needs a darker shade
    # while the 42px display number may keep the SPEC colour.
    "secondary-text": "#6D3FD4",
}

_DERIVED_DARK: dict[str, str] = {
    "surface-alt": "#262138",
    "accent-strong": "#34D399",
    "warning-text": "#FBBF24",
    "destructive-strong": "#F87171",
    "on-accent": "#06251A",
    "focus-soft": "#322B4A",
    "secondary-text": "#C4B5FD",
}

LIGHT: dict[str, str] = {name: pair[0] for name, pair in TOKENS.items()} | _DERIVED_LIGHT
DARK: dict[str, str] = {name: pair[1] for name, pair in TOKENS.items()} | _DERIVED_DARK

# Form and rhythm (SPEC §7.1).
RADIUS = 12
RADIUS_SM = 10
SPACE_XS = 4
SPACE_SM = 8
SPACE_MD = 12
SPACE_LG = 16
SPACE_XL = 24

FONT_SIZES: dict[str, int] = {
    "display": 42,
    "metric": 26,
    "title": 16,
    "body": 13,
    "caption": 11,
}

FONT_WEIGHTS: dict[str, QFont.Weight] = {
    "display": QFont.Weight.Bold,
    "metric": QFont.Weight.DemiBold,
    "title": QFont.Weight.DemiBold,
    "body": QFont.Weight.Normal,
    "caption": QFont.Weight.Normal,
}


def tr(text: str) -> str:
    from ..i18n import tr as _tr

    return _tr(text, context=_CONTEXT)


# --------------------------------------------------------------------- tokens


def tokens(dark: bool) -> dict[str, str]:
    """The full token map for one theme."""
    return dict(DARK if dark else LIGHT)


def color(name: str, dark: bool | None = None) -> str:
    """One token by role; ``dark`` defaults to the app's current colour scheme."""
    table = DARK if (prefers_dark() if dark is None else dark) else LIGHT
    try:
        return table[name]
    except KeyError:  # a typo must not black out the UI
        return table["foreground"]


def qcolor(name: str, dark: bool | None = None) -> QColor:
    return QColor(color(name, dark))


# ----------------------------------------------------------------- typography


def font_family() -> str:
    """Family of the platform UI font (``.AppleSystemUIFont`` on macOS).

    Returned through QFont, never hard-coded: QSS cannot resolve the macOS
    private family name, so sizes and weights are applied programmatically.
    """
    app = QApplication.instance()
    base = app.font() if app is not None else QFont()
    family = base.family().strip()
    return family or QFont().family()


def font(role: str) -> QFont:
    """A QFont for a type role: ``display``/``metric``/``title``/``body``/``caption``."""
    result = QFont(font_family())
    result.setPixelSize(FONT_SIZES.get(role, FONT_SIZES["body"]))
    weight = FONT_WEIGHTS.get(role)
    if weight is not None:
        result.setWeight(weight)
    return result


# -------------------------------------------------------------------- palette


def build_palette(dark: bool) -> QPalette:
    """QPalette matching the tokens, so native dialogs inherit the theme."""
    t = tokens(dark)
    palette = QPalette()
    window = QColor(t["background"])
    surface = QColor(t["surface"])
    text = QColor(t["foreground"])
    muted = QColor(t["muted-fg"])

    role = QPalette.ColorRole
    group = QPalette.ColorGroup
    roles = {
        role.Window: window,
        role.WindowText: text,
        role.Base: surface,
        role.AlternateBase: QColor(t["surface-alt"]),
        role.Text: text,
        role.Button: surface,
        role.ButtonText: text,
        role.BrightText: QColor("#FFFFFF"),
        role.Highlight: QColor(t["primary"]),
        role.HighlightedText: QColor("#FFFFFF"),
        role.ToolTipBase: surface,
        role.ToolTipText: text,
        role.PlaceholderText: muted,
        role.Link: QColor(t["primary"]),
        role.Light: QColor(t["surface"]),
        role.Mid: QColor(t["border"]),
        role.Dark: QColor(t["background"]),
        role.Shadow: QColor(t["border"]),
    }
    for colour_role, colour in roles.items():
        palette.setColor(colour_role, colour)
        palette.setColor(group.Disabled, colour_role, colour)
    return palette


# ----------------------------------------------------------------- stylesheet


def build_stylesheet(dark: bool) -> str:
    """The full QSS for one theme."""
    t = tokens(dark)
    radius = "%dpx" % RADIUS
    radius_sm = "%dpx" % RADIUS_SM
    # Qt adds padding to min-height, so 28 + 2*8 == the 44px minimum target.
    min_h = 28

    template = """
QWidget {
    color: %(foreground)s;
    background: transparent;
    font-size: %(body_size)spx;
}
QMainWindow, QDialog {
    background: %(background)s;
}
QMainWindow::separator {
    background: %(border)s;
    width: 1px;
    height: 1px;
}

/* --- type roles ------------------------------------------------------- */
QLabel { background: transparent; }
QLabel[role="display"] { font-size: %(display_size)spx; font-weight: 700; }
QLabel[role="metric"]  { font-size: %(metric_size)spx; font-weight: 600; }
QLabel[role="title"]   { font-size: %(title_size)spx; font-weight: 600; }
QLabel[role="body"]    { font-size: %(body_size)spx; }
QLabel[role="caption"] { font-size: %(caption_size)spx; color: %(muted_fg)s; }

/* --- cards ------------------------------------------------------------ */
QFrame#card {
    background: %(surface)s;
    border: 1px solid %(border)s;
    border-radius: %(radius)s;
}
QFrame#panel {
    background: %(surface)s;
    border: 1px solid %(border)s;
    border-radius: %(radius)s;
}
QFrame#hint {
    background: transparent;
    border: none;
}
QFrame#separator {
    background: %(border)s;
    border: none;
    max-height: 1px;
}

/* --- buttons ---------------------------------------------------------- */
QPushButton {
    background: %(surface)s;
    color: %(foreground)s;
    border: 1px solid %(border)s;
    border-radius: %(radius_sm)s;
    padding: 8px 16px;
    min-height: %(min_h)spx;
    min-width: %(min_h)spx;
}
QPushButton:hover {
    background: %(surface_alt)s;
    border-color: %(primary)s;
}
QPushButton:pressed {
    background: %(border)s;
}
QPushButton:disabled {
    color: %(muted_fg)s;
    background: %(surface_alt)s;
    border-color: %(border)s;
}
QPushButton:focus {
    border: 2px solid %(ring)s;
    outline: 2px solid %(ring)s;
    outline-offset: 1px;
}
QPushButton#primary {
    background: %(accent_strong)s;
    color: %(on_accent)s;
    border: 1px solid %(accent_strong)s;
    font-size: %(title_size)spx;
    font-weight: 600;
    padding: 8px 22px;
}
QPushButton#primary:hover { background: %(accent)s; border-color: %(accent)s; }
QPushButton#primary:focus { border: 2px solid %(ring)s; outline: 2px solid %(ring)s; }
QPushButton#chip {
    padding: 8px 14px;
    font-size: %(body_size)spx;
    border-radius: %(radius_sm)s;
}
QPushButton#chip:checked {
    color: %(primary)s;
    border-color: %(primary)s;
    background: %(focus_soft)s;
}
QPushButton#ghost {
    background: transparent;
    border: 1px solid transparent;
    padding: 8px 12px;
}
QPushButton#ghost:hover { background: %(surface_alt)s; border-color: %(border)s; }

/* --- inputs ----------------------------------------------------------- */
QLineEdit, QAbstractSpinBox, QSpinBox, QDoubleSpinBox, QComboBox {
    background: %(surface)s;
    color: %(foreground)s;
    border: 1px solid %(border)s;
    border-radius: %(radius_sm)s;
    padding: 8px 10px;
    min-height: %(min_h)spx;
    selection-background-color: %(primary)s;
    selection-color: #FFFFFF;
}
QLineEdit:hover, QDoubleSpinBox:hover { border-color: %(muted_fg)s; }
QLineEdit:focus, QAbstractSpinBox:focus, QDoubleSpinBox:focus, QComboBox:focus {
    border: 2px solid %(ring)s;
    outline: 2px solid %(ring)s;
    outline-offset: 1px;
}
QLineEdit:disabled, QDoubleSpinBox:disabled { color: %(muted_fg)s; }
/* The stepper buttons are hidden in QSS: Qt's native arrows render as tiny
   dark blobs against a custom background on macOS. FreqControl draws its own
   triangles in _FreqSpinBox.paintEvent, which stays readable in both themes. */
QAbstractSpinBox::up-button, QDoubleSpinBox::up-button,
QSpinBox::up-button, QAbstractSpinBox::down-button, QDoubleSpinBox::down-button {
    subcontrol-origin: border;
    subcontrol-position: top right;
    background: transparent;
    border: none;
    width: 0px;
    height: 0px;
}
QAbstractSpinBox::up-arrow, QDoubleSpinBox::up-arrow,
QSpinBox::up-arrow, QAbstractSpinBox::down-arrow, QDoubleSpinBox::down-arrow {
    image: none;
    width: 0px;
    height: 0px;
}

/* --- sliders ---------------------------------------------------------- */
QSlider {
    background: transparent;
    margin: 10px 2px;
}
QSlider::groove:horizontal {
    height: 6px;
    background: %(border)s;
    border-radius: 3px;
}
QSlider::sub-page:horizontal {
    background: %(primary)s;
    border-radius: 3px;
}
QSlider::handle:horizontal {
    background: %(surface)s;
    border: 2px solid %(primary)s;
    width: 18px;
    height: 18px;
    margin: -6px 0;
    border-radius: 9px;
}
QSlider::handle:horizontal:hover { background: %(focus_soft)s; }
QSlider:focus {
    outline: 2px solid %(ring)s;
    outline-offset: 2px;
    border-radius: %(radius_sm)s;
}
QSlider::groove:horizontal:focus { background: %(focus_soft)s; }

/* --- tool bar / status bar -------------------------------------------- */
QToolBar {
    background: %(surface_alt)s;
    border: none;
    border-bottom: 1px solid %(border)s;
    padding: 8px 12px;
    spacing: 8px;
}
QToolBar::separator {
    background: %(border)s;
    width: 1px;
    margin: 6px 8px;
}
QStatusBar {
    background: %(surface)s;
    border-top: 1px solid %(border)s;
}
QStatusBar::item { border: none; }
QToolButton {
    color: %(foreground)s;
    background: transparent;
    border: 1px solid transparent;
    border-radius: %(radius_sm)s;
    padding: 8px 12px;
    min-height: %(min_h)spx;
}
QToolButton:hover { background: %(focus_soft)s; border-color: %(border)s; }
QToolButton:focus { border: 2px solid %(ring)s; outline: 2px solid %(ring)s; }

/* --- menus, tooltips, scrollbars -------------------------------------- */
QMenu {
    background: %(surface)s;
    border: 1px solid %(border)s;
    border-radius: %(radius_sm)s;
    padding: 6px;
}
QMenu::item { padding: 8px 20px; border-radius: %(radius_sm)s; min-height: 24px; }
QMenu::item:selected { background: %(focus_soft)s; color: %(foreground)s; }
QMenu::item:disabled { color: %(muted_fg)s; }
QMenuBar { background: transparent; }
QMenuBar::item { padding: 6px 10px; border-radius: %(radius_sm)s; }
QMenuBar::item:selected { background: %(focus_soft)s; }
QToolTip {
    background: %(surface)s;
    color: %(foreground)s;
    border: 1px solid %(border)s;
    padding: 6px 8px;
}
QScrollBar:vertical { background: transparent; width: 12px; margin: 2px; }
QScrollBar::handle:vertical {
    background: %(border)s;
    border-radius: 5px;
    min-height: 32px;
}
QScrollBar:horizontal { background: transparent; height: 12px; margin: 2px; }
QScrollBar::handle:horizontal {
    background: %(border)s;
    border-radius: 5px;
    min-width: 32px;
}
QScrollBar::add-line, QScrollBar::sub-line { height: 0; width: 0; }
QScrollBar::add-page, QScrollBar::sub-page { background: transparent; }
QCheckBox { spacing: 8px; min-height: 24px; }
QCheckBox::indicator {
    width: 18px; height: 18px;
    border: 1px solid %(border)s;
    border-radius: 4px;
    background: %(surface)s;
}
QCheckBox::indicator:checked { background: %(primary)s; border-color: %(primary)s; }
QCheckBox:focus { outline: 2px solid %(ring)s; outline-offset: 1px; }
"""

    values = {
        "foreground": t["foreground"],
        "background": t["background"],
        "surface": t["surface"],
        "surface_alt": t["surface-alt"],
        "border": t["border"],
        "muted_fg": t["muted-fg"],
        "primary": t["primary"],
        "secondary": t["secondary"],
        "accent": t["accent"],
        "accent_strong": t["accent-strong"],
        "warning": t["warning"],
        "warning_text": t["warning-text"],
        "destructive": t["destructive-strong"],
        "ring": t["ring"],
        "focus_soft": t["focus-soft"],
        "on_accent": t["on-accent"],
        "radius": radius,
        "radius_sm": radius_sm,
        "min_h": min_h,
        "display_size": FONT_SIZES["display"],
        "metric_size": FONT_SIZES["metric"],
        "title_size": FONT_SIZES["title"],
        "body_size": FONT_SIZES["body"],
        "caption_size": FONT_SIZES["caption"],
    }
    # `#` inside colours is fine for %-formatting, but the `%(name)s` keys with
    # a dash would break, so the map is built with valid identifiers only.
    return template % values


# ------------------------------------------------------------------ application


def prefers_dark(app: QApplication | None = None) -> bool:
    """True when the OS asks for a dark colour scheme."""
    application = app or QApplication.instance()
    if application is None:
        return False
    try:
        hints = application.styleHints()
        scheme = hints.colorScheme()
    except Exception:
        return False
    return scheme == Qt.ColorScheme.Dark


def apply_theme(app: QApplication, dark: bool | None = None) -> bool:
    """Palette + stylesheet + UI font for the whole app. Returns ``dark``."""
    if dark is None:
        dark = prefers_dark(app)
    app.setPalette(build_palette(dark))
    app.setStyleSheet(build_stylesheet(dark))
    base = QFont(font_family())
    app.setFont(base)
    return dark


# ---------------------------------------------------------------- reduced motion


@lru_cache(maxsize=1)
def _platform_reduce_motion() -> bool:
    """Ask the OS whether animation is unwanted. Never raises."""
    try:
        app = QApplication.instance()
        if app is not None:
            # Qt 6.9+ exposes this directly; older builds do not have it.
            getter = getattr(app.styleHints(), "animationsEnabled", None)
            if callable(getter):
                return not bool(getter())

        if sys.platform == "darwin":
            out = subprocess.run(
                ["defaults", "read", "com.apple.universalaccess", "reduceMotion"],
                capture_output=True,
                text=True,
                timeout=1.5,
                check=False,
            )
            return out.returncode == 0 and out.stdout.strip() == "1"

        # KDE/GNOME on Linux.
        try:
            kde = QSettings("KDE", "Kde")
            factor = str(kde.value("AnimationDurationFactor", "1"))
            if factor.strip() in {"0", "0.0"}:
                return True
            gnome = QSettings("org.gnome.desktop.interface", "interface")
            return str(gnome.value("enable-animations", "true")).lower() in {
                "false",
                "0",
            }
        except Exception:
            return False
    except Exception:
        return False


def reduced_motion() -> bool:
    """True when the beat pulse must stay static (SPEC §7.2)."""
    override = os.environ.get(ENV_REDUCED_MOTION, "").strip().lower()
    if override in {"1", "true", "yes", "on"}:
        return True
    if override in {"0", "false", "no", "off"}:
        return False
    return _platform_reduce_motion()


def animations_enabled() -> bool:
    """Inverse of :func:`reduced_motion`, for call sites that read better that way."""
    return not reduced_motion()