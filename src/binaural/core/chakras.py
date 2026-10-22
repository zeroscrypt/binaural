"""The chakra sequence: seven solfeggio steps, root to crown.

The frequencies are the solfeggio set — 396, 417, 528, 639, 741, 852, 963 Hz — and they
are **carriers**, not beats. A listener hears the carrier as the pitch and the
difference between the ears as the beat, which is the same division of labour every
other mode in the app uses.

This is the Python half of ``apple/Sources/Core/ChakraSequence.swift``. The step data is
language-free; the names and the descriptions are catalogue entries looked up through
``tr`` at the moment they are shown, so a language switch reaches them the same way it
reaches every other caption.

Where the default beat comes from
---------------------------------
The default of 21 Hz is not a round number someone picked. It was *measured*: a
reference app playing this same sequence was recorded, and its left and right channels
turned out to be identical, so the pulsing was not binaural at all — it was two tones
summed inside one ear, and the envelope of that sum pulsated at a measured 21.00 Hz in
every step after the first. That measurement is what this default reproduces, and the
number is exposed because a different figure suits a different listener: 21 Hz sits in
the alpha band, which many people find bright.
"""

from __future__ import annotations

from dataclasses import dataclass

from .difference_lock import quantized, snapped

__all__ = [
    "ChakraStep",
    "STEPS",
    "DEFAULT_BEAT_HZ",
    "DEFAULT_STEP_SECONDS",
    "STEP_SECONDS_CHOICES",
    "MIN_BEAT_HZ",
    "MAX_BEAT_HZ",
    "pair",
    "step_by_id",
    "step_index",
    "PALETTE_TOKENS",
    "palette_token",
    "step_name",
    "step_description",
    "mode_name",
    "step_caption",
    "beat_caption",
    "default_beat_note",
    "step_seconds_text",
]

_CONTEXT = "Chakras"


def tr(text: str) -> str:
    """Translate through the shared catalogue.

    The wrapper keeps the call sites identical and gives lupdate a stable context.
    """
    from ..i18n import tr as _tr

    return _tr(text, context=_CONTEXT)


@dataclass(frozen=True)
class ChakraStep:
    """One step: a solfeggio frequency and an id.

    No text is carried here. The names and the descriptions are catalogue entries, so
    they are looked up through :func:`tr` when they are shown; a second copy of the
    Russian text would be a second thing to keep in step with ``ru.py``.
    """

    id: str
    hz: float


#: The steps, earth first. The order is the whole point of the mode: the sound rises
#: from the ground through the body to the crown.
#:
#: The first step is not one of the seven chakras. The **earth** step is 174 Hz — the
#: lowest tone of the extended Solfeggio set, the one traditionally called *the
#: foundation*: grounding, stability, easing physical tension. It sits below the root the
#: way the earth sits below the body, and without it the sequence starts at the root,
#: which is already one step up the spine.
#:
#: (There is an "earth star" in some esoteric systems, but it is said to lie below the
#: soles of the feet and to have no frequency in this system at all. 174 Hz is the
#: closest thing to an earth frequency that is actually a note.)
STEPS: tuple[ChakraStep, ...] = (
    ChakraStep("earth", 174),
    ChakraStep("root", 396),
    ChakraStep("sacral", 417),
    ChakraStep("solar-plexus", 528),
    ChakraStep("heart", 639),
    ChakraStep("throat", 741),
    ChakraStep("third-eye", 852),
    ChakraStep("crown", 963),
)

#: The beat the mode starts on. 21 Hz, measured — see the module docstring.
DEFAULT_BEAT_HZ: float = 21.0

#: How long one chakra lasts before the next, in seconds.
DEFAULT_STEP_SECONDS: float = 6.0

#: The offered step durations, in seconds. The default is among them.
STEP_SECONDS_CHOICES: tuple[float, ...] = (3, 6, 10, 15, 20, 30)

#: The shortest and longest beat the mode accepts. The upper bound is roughly where a
#: binaural difference stops being heard as a beat and starts being heard as roughness;
#: the lower one keeps the difference audible against a 396 Hz carrier.
MIN_BEAT_HZ: float = 0.5
MAX_BEAT_HZ: float = 40.0


#: The colour token of each step, earth first. From the root up the order is the
#: rainbow: red, orange, yellow, green, light blue, blue, violet — the order everyone
#: already knows, so a reader can tell which chakra they are looking at from the colour
#: alone. The earth is a stone grey rather than a colour of the rainbow: it is not a
#: chakra, it is the ground the seven stand on.
PALETTE_TOKENS: tuple[str, ...] = (
    "chakra-earth",
    "chakra-root",
    "chakra-sacral",
    "chakra-solar-plexus",
    "chakra-heart",
    "chakra-throat",
    "chakra-third-eye",
    "chakra-crown",
)


def palette_token(step_id: str) -> str:
    """The theme token that carries a step's colour, or the root's if the id is unknown."""
    for index, step in enumerate(STEPS):
        if step.id == step_id:
            return PALETTE_TOKENS[index]
    return PALETTE_TOKENS[0]


def step_by_id(step_id: str) -> ChakraStep | None:
    """The step with the given id, or ``None`` when there is no such step."""
    return next((step for step in STEPS if step.id == step_id), None)


def step_index(index: int) -> int:
    """The index of a step, clamped into range.

    An out-of-range index is not an error here: the step index moves with a timer, and a
    stale value must not be able to stop the sequence.
    """
    return min(max(0, index), len(STEPS) - 1)


def pair(step: ChakraStep, beat_hz: float = DEFAULT_BEAT_HZ) -> tuple[float, float]:
    """The frequency pair that plays a step.

    The carrier is the step's own frequency and the beat is split evenly between the two
    ears, so the pitch the listener hears stays on the solfeggio frequency and only the
    beat moves — ``fL = c - b/2``, ``fR = c + b/2``, the same division
    :func:`binaural.core.oscillator.pair_from_beat` uses.

    The result is clamped to the audible range and snapped to the 0.1 Hz grid, because
    the engine only ever plays quantised frequencies.
    """
    if beat_hz != beat_hz or beat_hz in (float("inf"), float("-inf")):
        # NaN or infinity: a half-typed field is not a number, and it must not reach
        # the engine. Swift's `isFinite` check takes the same branch.
        beat = DEFAULT_BEAT_HZ
    else:
        beat = min(MAX_BEAT_HZ, max(MIN_BEAT_HZ, beat_hz))
    # Both tones have to sit on the 0.1 Hz grid *and* differ by the beat. With a
    # whole-hertz carrier and a 0.5 Hz beat the two cannot both hold: the tones would be
    # 395.75 and 396.25, and neither is on the grid. So the lower tone is placed on the
    # grid and the upper one is derived from it, which makes the difference exact and
    # moves the carrier by at most half a grid step — 0.05 Hz, inaudible.
    wanted = snapped(beat)
    left = quantized(step.hz - wanted / 2)
    right = quantized(left + wanted)
    return left, right


# --------------------------------------------------------------------------
# Captions
# --------------------------------------------------------------------------


def step_name(step_id: str) -> str:
    """The name of a step, in the current language."""
    return {
        "earth": tr("Earth"),
        "root": tr("Root"),
        "sacral": tr("Sacral"),
        "solar-plexus": tr("Solar plexus"),
        "heart": tr("Heart"),
        "throat": tr("Throat"),
        "third-eye": tr("Third eye"),
        "crown": tr("Crown"),
    }.get(step_id, step_id)


def step_description(step_id: str) -> str:
    """What a step is about, in the current language."""
    return {
        "earth": tr("Ground and stability: the body's own base."),
        "root": tr("Letting go of fear and touching ground."),
        "sacral": tr("Undoing what got stuck and opening up to change."),
        "solar-plexus": tr("The love frequency. The best known of the nine."),
        "heart": tr("Relationships, connection, forgiving others."),
        "throat": tr("Finding your words and telling the truth."),
        "third-eye": tr("Seeing clearly before you decide."),
        "crown": tr("Unity and presence, to feel whole."),
    }.get(step_id, "")


def mode_name() -> str:
    """The name of the mode."""
    return tr("Chakras")


def step_caption() -> str:
    """The caption of the step-duration control."""
    return tr("Step")


def beat_caption() -> str:
    """The caption of the beat control."""
    return tr("Beat")


def default_beat_note() -> str:
    """Why the default beat is what it is.

    The number is on screen anyway, and a number without a reason reads as an arbitrary
    constant.
    """
    return tr("The default 21 Hz sits in the alpha band.")


def step_seconds_text(seconds: float) -> str:
    """A step duration as a caption: ``6 s``."""
    return tr("%1 s", str(int(round(seconds))))
