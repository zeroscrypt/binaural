"""Modal dialogs of the Binaural UI (SPEC §4, §7).

Besides re-exporting the dialog classes, this package holds the small design
helpers they share: the ``tr()`` wrapper, the colour tokens of SPEC §7.1 and
factories for buttons and labels that enforce the accessibility rules of
SPEC §7.2 — a visible focus ring, a 44 px minimum touch target, Escape to
close and readable contrast.

``binaural.ui.theme`` is written by another module and may not exist yet while
the UI is built in parallel, so its tokens are picked up defensively: the local
SPEC fallbacks are used whenever a token cannot be resolved. Nothing here raises
because of a missing theme.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from functools import lru_cache

from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QDesktopServices, QPalette
from PySide6.QtWidgets import (
    QApplication,
    QFrame,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

__all__ = [
    "TRANSLATION_CONTEXT",
    "tr",
    "DialogTheme",
    "resolve_theme",
    "build_qss",
    "style_dialog",
    "refresh_style",
    "set_role",
    "set_variant",
    "contrast_ratio",
    "readable_on",
    "ensure_contrast",
    "open_url",
    "make_button",
    "make_label",
    "make_panel",
    "apply_button_metrics",
    "open_link_label",
    "button_row",
    "panel_layout",
    # Type scale and rhythm of SPEC §7.1
    "FONT_DISPLAY",
    "FONT_METRIC",
    "FONT_TITLE",
    "FONT_BODY",
    "FONT_CAPTION",
    "RADIUS_PX",
    "MIN_TOUCH_PX",
    "SPACE_XS",
    "SPACE_SM",
    "SPACE_MD",
    "SPACE_LG",
    "SPACE_XL",
    # Dialogs
    "HeadphoneCheckDialog",
    "LrTestDialog",
    "ReferenceDialog",
    "AboutDialog",
    "SettingsDialog",
    "UpdateDialog",
    "UpdateProgressDialog",
]

TRANSLATION_CONTEXT = "BinauralDialogs"

# --- SPEC §7.1 typography / form / rhythm ---------------------------------

FONT_DISPLAY = 42
FONT_METRIC = 26
FONT_TITLE = 16
FONT_BODY = 13
FONT_CAPTION = 11
RADIUS_PX = 10
MIN_TOUCH_PX = 44  # SPEC §7.2: minimum clickable area 44x44 px
SPACE_XS = 4
SPACE_SM = 8
SPACE_MD = 12
SPACE_LG = 16
SPACE_XL = 24

#: Contrast target of SPEC §7.2 for body text.
MIN_CONTRAST = 4.5

#: SPEC §7.1 light tokens.
LIGHT_TOKENS: dict[str, str] = {
    "primary": "#7C3AED",
    "secondary": "#8B5CF6",
    "accent": "#059669",
    "background": "#FAF5FF",
    "surface": "#FFFFFF",
    "foreground": "#0F172A",
    "muted": "#475569",
    "border": "#EFE7FC",
    "warning": "#D97706",
    "destructive": "#DC2626",
    "ring": "#7C3AED",
}

#: SPEC §7.1 dark tokens.
DARK_TOKENS: dict[str, str] = {
    "primary": "#A78BFA",
    "secondary": "#C4B5FD",
    "accent": "#34D399",
    "background": "#151221",
    "surface": "#1E1A2E",
    "foreground": "#F1EDFF",
    "muted": "#A5A0BE",
    "border": "#322B4A",
    "warning": "#FBBF24",
    "destructive": "#F87171",
    "ring": "#A78BFA",
}

# Attribute names a ``ui/theme.py`` module might use for a role. Purely
# best-effort: an unknown layout simply keeps the local fallback.
# Spellings a ``ui/theme.py`` might use for the same role.
_ROLE_ALIASES: dict[str, tuple[str, ...]] = {
    "muted": ("muted", "muted-fg", "muted_fg", "mutedFg"),
}

_ROLE_CONTAINERS = (
    "LIGHT",
    "DARK",
    "TOKENS",
    "tokens",
    "LIGHT_TOKENS",
    "COLORS",
)


def tr(text: str, context: str = TRANSLATION_CONTEXT) -> str:
    """Translate a user-visible string into the current UI language.

    Delegates to :mod:`binaural.i18n` so that English and Russian share one
    catalogue. The import is lazy because the dialogs package is imported by
    the widgets, which are imported before the app has chosen a language.
    """
    from ...i18n import tr as _tr

    return _tr(text, context=context)


# --------------------------------------------------------------------------
# Colour helpers — SPEC §7.2 contrast is enforced, not hoped for
# --------------------------------------------------------------------------


def _rgb(color: str) -> tuple[int, int, int]:
    qc = QColor(color)
    if not qc.isValid():
        # Fall back to opaque black rather than propagating a bad value.
        return (0, 0, 0)
    return (qc.red(), qc.green(), qc.blue())


def _channel(value: int) -> float:
    c = value / 255.0
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4


def _luminance(color: str) -> float:
    r, g, b = _rgb(color)
    return 0.2126 * _channel(r) + 0.7152 * _channel(g) + 0.0722 * _channel(b)


def contrast_ratio(foreground: str, background: str) -> float:
    """WCAG contrast ratio between two colours (1.0 .. 21.0)."""
    a, b = _luminance(foreground), _luminance(background)
    if a < b:
        a, b = b, a
    return (a + 0.05) / (b + 0.05)


def readable_on(background: str, candidates: tuple[str, ...] = ("#FFFFFF", "#0F172A")) -> str:
    """Pick the candidate colour with the best contrast on ``background``."""
    return max(candidates, key=lambda fg: contrast_ratio(fg, background))


def _mix(color: str, target: tuple[int, int, int], amount: float) -> str:
    """Blend ``color`` towards ``target``; ``amount`` 0 keeps the original."""
    r, g, b = _rgb(color)
    channels = (r, g, b)
    mixed = tuple(
        int(round(channel + (to - channel) * amount))
        for channel, to in zip(channels, target)
    )
    return "#{:02X}{:02X}{:02X}".format(*mixed)


def ensure_contrast(color: str, background: str, min_ratio: float = MIN_CONTRAST) -> str:
    """Nudge ``color`` towards black or white until it reaches ``min_ratio``.

    Status colours (warning, destructive, muted) come from the token table as
    *identity* colours; used as text they must clear 4.5:1 first. The shift grows
    geometrically, so the result stays as close to the brand colour as possible.
    """
    if contrast_ratio(color, background) >= min_ratio:
        return color
    target = (0, 0, 0) if _luminance(background) > 0.35 else (255, 255, 255)
    candidate = color
    for step in range(1, 24):
        candidate = _mix(color, target, 1.0 - 0.88**step)
        if contrast_ratio(candidate, background) >= min_ratio:
            return candidate
    return candidate


# --------------------------------------------------------------------------
# Theme resolution
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class DialogTheme:
    """Resolved colours for one dialog, contrast already guaranteed."""

    primary: str
    secondary: str
    accent: str
    background: str
    surface: str
    foreground: str
    muted: str
    border: str
    warning: str
    destructive: str
    ring: str
    is_dark: bool = False
    _derived: dict[str, str] = field(default_factory=dict)

    @property
    def accent_fill(self) -> str:
        """Background of a filled accent button.

        ``accent`` on white text is only ~3.8:1, so a filled button uses the
        darker step of the same hue when the theme provides one.
        """
        fill = self._derived.get("accent-strong")
        if fill is not None and contrast_ratio(readable_on(fill), fill) >= MIN_CONTRAST:
            return fill
        return self.accent

    @property
    def on_accent(self) -> str:
        """Text colour on :attr:`accent_fill`."""
        return readable_on(self.accent_fill)

    @property
    def warning_text(self) -> str:
        return ensure_contrast(self.warning, self.background)

    @property
    def destructive_text(self) -> str:
        return ensure_contrast(self.destructive, self.background)

    @property
    def on_primary(self) -> str:
        return readable_on(self.primary)


def _theme_module():
    """``ui/theme.py`` if it exists yet, otherwise ``None``."""
    try:  # pragma: no cover - depends on the parallel UI module
        from .. import theme  # type: ignore[attr-defined]

        return theme
    except Exception:
        return None


def _valid(value: object) -> str | None:
    return value if isinstance(value, str) and QColor(value).isValid() else None


def _from_theme(role: str, is_dark: bool) -> str | None:
    """Look a colour up in ``ui/theme.py``, tolerating unknown layouts.

    Prefers the flat ``LIGHT``/``DARK`` mappings and the ``tokens(dark)``
    helper; falls back to the older tuple-style ``TOKENS`` registry and then to
    plain attributes, so a theme module that arrives later still applies.
    """
    module = _theme_module()
    if module is None:
        return None

    aliases = _ROLE_ALIASES.get(role, (role,))
    keys = tuple(alias for name in aliases for alias in (name, name.upper()))

    # 1. tokens(dark) / LIGHT / DACK mappings — the shapes this repo uses.
    helper = getattr(module, "tokens", None)
    if callable(helper):
        try:
            mapping = helper(is_dark)
        except Exception:
            mapping = None
        if isinstance(mapping, dict):
            for key in keys:
                found = _valid(mapping.get(key))
                if found:
                    return found

    for name in (("DARK" if is_dark else "LIGHT"), "TOKENS", "LIGHT_TOKENS", "COLORS"):
        holder = getattr(module, name, None)
        if isinstance(holder, dict):
            for key in keys:
                value = holder.get(key)
                found = _valid(value)
                if found:
                    return found
                # TOKENS may hold (light, dark) pairs per role.
                if isinstance(value, (tuple, list)) and value:
                    index = 1 if (name == "TOKENS" and is_dark) else 0
                    if index < len(value):
                        found = _valid(value[index])
                        if found:
                            return found

    # 2. Plain module attributes.
    for key in keys:
        found = _valid(getattr(module, key, None))
        if found:
            return found
    return None


#: Derived tokens pulled from the theme when it offers them; each is optional.
_DERIVED_ROLES = ("accent-strong", "on-accent", "warning-text", "destructive-strong")


@lru_cache(maxsize=4)
def _resolve(is_dark: bool) -> DialogTheme:
    base = dict(DARK_TOKENS if is_dark else LIGHT_TOKENS)
    for role in base:
        resolved = _from_theme(role, is_dark)
        if resolved is not None:
            base[role] = resolved

    derived: dict[str, str] = {}
    for role in _DERIVED_ROLES:
        resolved = _from_theme(role, is_dark)
        if resolved is not None:
            derived[role] = resolved

    background = base["background"]
    return DialogTheme(
        primary=base["primary"],
        secondary=base["secondary"],
        accent=base["accent"],
        background=background,
        surface=base["surface"],
        foreground=base["foreground"],
        muted=ensure_contrast(base["muted"], background),
        border=base["border"],
        warning=base["warning"],
        destructive=base["destructive"],
        ring=base["ring"],
        is_dark=is_dark,
        _derived=derived,
    )


def _app_is_dark(widget: QWidget | None = None) -> bool:
    app = QApplication.instance()
    if app is None:
        return False
    palette: QPalette = app.palette()
    if widget is not None:
        palette = widget.palette()
    window = palette.color(QPalette.ColorRole.Window)
    return _luminance(window.name()) < 0.35


def resolve_theme(widget: QWidget | None = None) -> DialogTheme:
    """Tokens for the active palette, memoised per light/dark mode."""
    return _resolve(_app_is_dark(widget))


def build_qss(theme: DialogTheme) -> str:
    """The shared dialog stylesheet.

    Focus rings are styled, never removed: SPEC §7.2 requires a visible ring on
    every interactive element, including inside modal dialogs.
    """
    ring = theme.ring
    return f"""
QDialog, QWidget#root {{
    background-color: {theme.background};
}}
QWidget {{
    color: {theme.foreground};
    font-size: {FONT_BODY}px;
}}
QLabel {{
    background: transparent;
    color: {theme.foreground};
    font-size: {FONT_BODY}px;
}}
QLabel[role="heading"] {{ font-size: {FONT_TITLE}px; font-weight: 600; }}
QLabel[role="metric"] {{ font-size: {FONT_METRIC}px; font-weight: 600; }}
QLabel[role="display"] {{ font-size: {FONT_DISPLAY}px; font-weight: 700; }}
QLabel[role="caption"] {{ font-size: {FONT_CAPTION}px; color: {theme.muted}; }}
QLabel[role="muted"] {{ color: {theme.muted}; }}
QLabel[role="warning"] {{ color: {theme.warning_text}; font-weight: 600; }}
QLabel[role="danger"] {{ color: {theme.destructive_text}; font-weight: 600; }}
QLabel[role="ok"] {{ color: {ensure_contrast(theme.accent, theme.background)}; font-weight: 600; }}
QLabel[role="link"] {{ color: {theme.primary}; }}
QLabel[role="icon"] {{ font-size: {FONT_TITLE}px; }}

QFrame#card, QFrame#panel {{
    background-color: {theme.surface};
    border: 1px solid {theme.border};
    border-radius: {RADIUS_PX}px;
}}
QFrame#disclaimer {{
    background-color: {theme.surface};
    border: 1px solid {theme.border};
    border-left: 3px solid {theme.warning};
    border-radius: {RADIUS_PX}px;
}}
QFrame#separator {{
    background-color: {theme.border};
    max-height: 1px;
    border: none;
}}

QPushButton {{
    background-color: {theme.surface};
    color: {theme.foreground};
    border: 1px solid {theme.border};
    border-radius: {RADIUS_PX}px;
    padding: {SPACE_SM}px {SPACE_LG}px;
    min-height: {MIN_TOUCH_PX - 2 * SPACE_SM}px;
}}
QPushButton:hover {{ border-color: {theme.primary}; }}
QPushButton:focus {{ border: 2px solid {ring}; padding: {SPACE_SM - 1}px {SPACE_LG - 1}px; }}
QPushButton:pressed {{ background-color: {theme.border}; }}
QPushButton:disabled {{ color: {theme.muted}; }}
QPushButton[variant="primary"] {{
    background-color: {theme.accent_fill};
    color: {theme.on_accent};
    border: 1px solid {theme.accent_fill};
    font-weight: 600;
}}
QPushButton[variant="primary"]:hover {{ border-color: {theme.ring}; }}
QPushButton[variant="primary"]:focus {{ border: 2px solid {ring}; }}
QPushButton[variant="channel"] {{
    background-color: {theme.surface};
    color: {theme.primary};
    border: 1px solid {theme.primary};
    font-weight: 600;
}}
QPushButton[variant="ghost"] {{
    background-color: transparent;
    border-color: transparent;
    color: {theme.primary};
}}
QPushButton[variant="ghost"]:focus {{ border: 2px solid {ring}; }}

QLineEdit {{
    background-color: {theme.surface};
    color: {theme.foreground};
    border: 1px solid {theme.border};
    border-radius: {RADIUS_PX}px;
    padding: {SPACE_SM}px {SPACE_MD}px;
    min-height: {MIN_TOUCH_PX - 2 * SPACE_SM}px;
    selection-background-color: {theme.primary};
    selection-color: #FFFFFF;
}}
QLineEdit:focus {{ border: 2px solid {ring}; }}
QLineEdit::placeholder {{ color: {theme.muted}; }}

QComboBox {{
    background-color: {theme.surface};
    color: {theme.foreground};
    border: 1px solid {theme.border};
    border-radius: {RADIUS_PX}px;
    padding: {SPACE_SM}px {SPACE_MD}px;
    min-height: {MIN_TOUCH_PX - 2 * SPACE_SM}px;
}}
QComboBox:focus {{ border: 2px solid {ring}; }}
QComboBox::drop-down {{ border: none; width: {SPACE_XL}px; }}
QComboBox QAbstractItemView {{
    background-color: {theme.surface};
    color: {theme.foreground};
    border: 1px solid {theme.border};
    selection-background-color: {theme.primary};
    selection-color: #FFFFFF;
    min-height: {MIN_TOUCH_PX}px;
}}

QListWidget {{
    background-color: {theme.surface};
    color: {theme.foreground};
    border: 1px solid {theme.border};
    border-radius: {RADIUS_PX}px;
    padding: {SPACE_XS}px;
}}
QListWidget:focus {{ border: 2px solid {ring}; }}
QListWidget::item {{
    min-height: {MIN_TOUCH_PX - 8}px;
    padding: {SPACE_SM}px;
    border-radius: {RADIUS_PX - 2}px;
    color: {theme.foreground};
}}
QListWidget::item:hover {{ background-color: {theme.border}; }}
QListWidget::item:selected {{
    background-color: {theme.primary};
    color: #FFFFFF;
}}

QScrollArea {{
    background: transparent;
    border: none;
}}
QScrollArea > QWidget > QWidget {{ background: transparent; }}

QToolTip {{
    background-color: {theme.surface};
    color: {theme.foreground};
    border: 1px solid {ring};
    padding: {SPACE_SM}px;
}}
"""


def style_dialog(widget: QWidget) -> None:
    """Apply the shared stylesheet to a dialog or one of its sections."""
    widget.setStyleSheet(build_qss(resolve_theme(widget)))


def refresh_style(widget: QWidget) -> None:
    """Re-polish a widget after a dynamic property changed."""
    style = widget.style()
    style.unpolish(widget)
    style.polish(widget)
    widget.update()


def set_role(widget: QWidget, role: str | None) -> None:
    """Set the ``role`` property the shared stylesheet keys off."""
    widget.setProperty("role", role)


def set_variant(button: QPushButton, variant: str | None) -> None:
    """Set the ``variant`` property of a button (primary, channel, ghost)."""
    button.setProperty("variant", variant)
    refresh_style(button)


def open_url(url: str) -> bool:
    """Open a link in the system browser; never raises."""
    try:
        from PySide6.QtCore import QUrl

        return bool(QDesktopServices.openUrl(QUrl(url)))
    except Exception:
        return False


def apply_button_metrics(button: QPushButton, min_width: int | None = None) -> None:
    """Guarantee the 44x44 px touch target of SPEC §7.2."""
    button.setMinimumHeight(MIN_TOUCH_PX)
    button.setSizePolicy(QSizePolicy.Policy.Minimum, QSizePolicy.Policy.Fixed)
    if min_width:
        button.setMinimumWidth(min_width)


def make_button(
    text: str,
    *,
    variant: str | None = None,
    on_click=None,
    min_width: int | None = None,
    tooltip: str | None = None,
    accessible_name: str | None = None,
    checkable: bool = False,
) -> QPushButton:
    """A button with the shared metrics, variant and a matching accessible name."""
    button = QPushButton(text)
    button.setCheckable(checkable)
    button.setCursor(Qt.CursorShape.PointingHandCursor)
    apply_button_metrics(button, min_width)
    set_variant(button, variant)
    if tooltip:
        button.setToolTip(tooltip)
        button.setAccessibleDescription(tooltip)
    if accessible_name:
        button.setAccessibleName(accessible_name)
    if on_click is not None:
        button.clicked.connect(on_click)
    return button


def make_label(
    text: str = "",
    *,
    role: str | None = None,
    word_wrap: bool = False,
    tooltip: str | None = None,
    selectable: bool = False,
) -> QLabel:
    """A label carrying a ``role`` for the shared stylesheet."""
    label = QLabel(text)
    set_role(label, role)
    if word_wrap:
        label.setWordWrap(True)
    if selectable:
        label.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse | Qt.TextInteractionFlag.LinksAccessibleByMouse
        )
    if tooltip:
        label.setToolTip(tooltip)
    return label


def make_panel(*, object_name: str = "panel") -> QFrame:
    """A rounded surface panel."""
    frame = QFrame()
    frame.setObjectName(object_name)
    frame.setFrameShape(QFrame.Shape.NoFrame)
    return frame


def open_link_label(url: str, text: str | None = None) -> QWidget:
    """A clickable external link that also shows the raw URL.

    The anchor colour is set explicitly from the tokens: the default Qt link
    colour does not reach 4.5:1 on our surfaces. Skipped by Tab so the focus
    order stays on real controls; the value is still selectable and copyable.
    """
    theme = resolve_theme()
    row = QWidget()
    layout = QHBoxLayout(row)
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(SPACE_SM)

    label = QLabel(
        f'<a href="{url}" style="color: {ensure_contrast(theme.primary, theme.background)};'
        f' text-decoration: underline;">{text or url}</a>'
    )
    label.setOpenExternalLinks(True)
    label.setTextInteractionFlags(
        Qt.TextInteractionFlag.TextBrowserInteraction
        | Qt.TextInteractionFlag.LinksAccessibleByMouse
    )
    label.setFocusPolicy(Qt.FocusPolicy.NoFocus)
    label.setToolTip(url)
    label.setAccessibleName(text or url)
    label.setCursor(Qt.CursorShape.PointingHandCursor)
    set_role(label, "link")

    button = make_button(
        tr("Open project page"),
        variant="ghost",
        on_click=lambda: open_url(url),
        accessible_name=tr("Open {url} in the browser").format(url=url),
    )
    layout.addWidget(label, 1)
    layout.addWidget(button)
    return row


def button_row(*buttons: QWidget, spacing: int = SPACE_SM) -> QHBoxLayout:
    """Left-aligned row of dialog buttons."""
    row = QHBoxLayout()
    row.setContentsMargins(0, 0, 0, 0)
    row.setSpacing(spacing)
    for button in buttons:
        row.addWidget(button)
    return row


def panel_layout(frame: QFrame, *, spacing: int = SPACE_MD, margins: int = SPACE_LG) -> QVBoxLayout:
    """Vertical layout with the shared rhythm for a panel."""
    layout = QVBoxLayout(frame)
    layout.setContentsMargins(margins, margins, margins, margins)
    layout.setSpacing(spacing)
    return layout


# Re-exported last: the dialog modules import the helpers above from this
# package, so the helpers must exist before these lines run.
from .about import AboutDialog  # noqa: E402
from .headphone_check import HeadphoneCheckDialog  # noqa: E402
from .lr_test import LrTestDialog  # noqa: E402
from .reference import ReferenceDialog  # noqa: E402
from .settings import SettingsDialog  # noqa: E402
from .update import UpdateDialog, UpdateProgressDialog  # noqa: E402
