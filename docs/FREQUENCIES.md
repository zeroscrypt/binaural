# Frequency reference

The complete reference shipped with the app: **99 entries in 9 categories**, stored as data in
[`src/binaural/data/frequencies.json`](../src/binaural/data/frequencies.json) and rendered in the
app under *Help → Frequency reference*.

Nothing here is ranked or filtered out. Categories exist only so that 99 numbers do not become an
unreadable wall.

- [How to use it in the app](#how-to-use-it-in-the-app)
- [Evidence levels](#evidence-levels)
- [Contents](#contents)
- [🧠 Brainwave Entrainment](#-brainwave-entrainment)
- [🌍 Schumann Resonance](#-schumann-resonance)
- [🪐 Planetary Frequencies](#-planetary-frequencies)
- [🎵 Solfeggio](#-solfeggio)
- [🎼 Tuning & Reference](#-tuning--reference)
- [🔬 Research & Studies](#-research--studies)
- [⚡ Rife & Therapeutic](#-rife--therapeutic)
- [🚀 Space & Consciousness](#-space--consciousness)
- [✨ Healing & Energy](#-healing--energy)
- [Disclaimer](#disclaimer)

---

## How to use it in the app

1. Open *Help → Frequency reference* (`Cmd/Ctrl+O`).
2. Pick a category from the sidebar — each shows its entry count.
3. Read the card: **name → beat frequency → `Apply` → effect text → evidence badge → source**.
4. Press **Apply**. This sets **both** frequencies at once, centred on the entry's carrier so you
   get exactly the requested beat. Press play.

Entries come in two shapes:

- **Point value** — a single beat, e.g. `Alpha 10 Hz`. Apply gives `fL = 195, fR = 205` around the
  200 Hz carrier.
- **Range** — a band such as `Alpha 8–13 Hz`. Apply uses a representative value inside the band.

The app shows `Beat` and `Carrier` live at all times, so after any `Apply` you can see exactly what
you got and adjust by hand.

## Evidence levels

Each entry carries an evidence marker. It is a **hint, not a filter** — nothing is hidden and
nothing is ordered by it.

| Marker | Level | Meaning |
|---|---|---|
| 🟢 | `well-studied` | peer-reviewed studies exist |
| 🔵 | `studied` | studies exist, but fewer |
| 🟡 | `reported` | claimed; little research |
| 🟣 | `traditional` | from traditional, esoteric or alternative practice |

Distribution across the 99 entries: 12 🟢, 8 🔵, 11 🟡, 68 🟣.

## Contents

| # | Category | Entries |
|---|---|---|
| 1 | 🧠 [Brainwave Entrainment](#-brainwave-entrainment) | 12 |
| 2 | 🌍 [Schumann Resonance](#-schumann-resonance) | 5 |
| 3 | 🪐 [Planetary Frequencies](#-planetary-frequencies) | 10 |
| 4 | 🎵 [Solfeggio](#-solfeggio) | 9 |
| 5 | 🎼 [Tuning & Reference](#-tuning--reference) | 5 |
| 6 | 🔬 [Research & Studies](#-research--studies) | 4 |
| 7 | ⚡ [Rife & Therapeutic](#-rife--therapeutic) | 40 |
| 8 | 🚀 [Space & Consciousness](#-space--consciousness) | 7 |
| 9 | ✨ [Healing & Energy](#-healing--energy) | 7 |

---

## 🧠 Brainwave Entrainment

*Entrainment by EEG brainwave band: Delta…Gamma ranges plus typical single values.*

| Entry | Beat | Effect (as described in the data) | |
|---|---|---|---|
| Delta 0.5–4 Hz | 0.5–4 | Deep sleep without dreams; tissue repair, growth hormone release, immune support, deep physical restoration | 🟢 |
| Theta 4–8 Hz | 4–8 | Meditation, REM sleep, hypnagogia; creativity, emotional processing, memory consolidation, deep relaxation, access to the subconscious | 🟢 |
| Alpha 8–13 Hz | 8–13 | Relaxed alertness; stress reduction, flow state, sustained focus without tension, serotonin support, pre-sleep state | 🟢 |
| Beta 13–30 Hz | 13–30 | Active thinking; concentration, alertness, problem solving, energy. Prolonged high beta can raise anxiety and over-arousal | 🟢 |
| Gamma 30–100 Hz | 30–100 | Higher cognitive processing; binding perception into a single whole, insight, memory retrieval, sharper awareness. 40 Hz is studied in neurodegeneration research | 🟢 |
| Delta 1.94 Hz | 1.94 | Deep-sleep point value of the delta band; physical restoration and growth hormone release | 🔵 |
| Theta 4 Hz | 4.0 | Theta entry point; meditation onset, hypnagogia, memory consolidation | 🔵 |
| Alpha 10 Hz | 10.0 | Relaxed alertness, calm focus, stress reduction — the most used alpha point value | 🟢 |
| Alpha 12 Hz | 12.0 | Upper alpha band; meditative absorption, drowsiness, pre-sleep state | 🔵 |
| Beta 14 Hz | 14.0 | First step into the beta band; light alertness, active thinking onset | 🔵 |
| Beta 20 Hz | 20.0 | Active thinking; concentration, alertness, task solving. Long exposure may raise physiological arousal | 🟢 |
| Gamma 40 Hz | 40.0 | Gamma point value used in sensory-neural stimulation research on neurodegeneration | 🟢 |

All twelve carry a carrier of 200 Hz. Source for 🟢/🔵 rows: peer-reviewed EEG literature, see
[docs/SPEC.md §2.1](SPEC.md).

---

## 🌍 Schumann Resonance

*The 7.83 Hz Earth–ionosphere resonance and its overtones.*

| Entry | Beat | Effect (as described in the data) | |
|---|---|---|---|
| Schumann 7.83 Hz | 7.83 | Fundamental Earth–ionosphere resonance; attributed sense of grounding, balance, normalisation of biorhythms | 🔵 |
| Schumann 14.3 Hz | 14.3 | First overtone of the Schumann resonance; grounding and a sense of orientation | 🟡 |
| Schumann 20.8 Hz | 20.8 | Second overtone of the Schumann resonance; grounding and a sense of orientation | 🟡 |
| Schumann 27.3 Hz | 27.3 | Third overtone of the Schumann resonance; grounding and a sense of orientation | 🟡 |
| Schumann 33.8 Hz | 33.8 | Fourth overtone of the Schumann resonance; grounding and a sense of orientation | 🟡 |

The resonance itself is a measured geophysical phenomenon; the human effects above are reported, not
established. Source: Schumann resonance measurements ([SPEC §6.4](SPEC.md)).

---

## 🪐 Planetary Frequencies

*Tones attributed to Sun, Moon and planets in sound-healing and astroacoustic practice.*

| Entry | Beat | Effect (as described in the data) | |
|---|---|---|---|
| Sun 126.22 Hz | 126.22 | Tone attributed to Sun: support, wholeness, confidence | 🟣 |
| Moon 210.42 Hz | 210.42 | Tone attributed to Moon: emotions, intuition, the feminine principle | 🟣 |
| Mercury 141.27 Hz | 141.27 | Tone attributed to Mercury: speech, communication, analytics | 🟣 |
| Venus 221.23 Hz | 221.23 | Tone attributed to Venus: harmony, relationships, love | 🟣 |
| Mars 144.72 Hz | 144.72 | Tone attributed to Mars: will, action, energy | 🟣 |
| Jupiter 183.58 Hz | 183.58 | Tone attributed to Jupiter: growth, abundance, expansion | 🟣 |
| Saturn 147.85 Hz | 147.85 | Tone attributed to Saturn: discipline, structure, boundaries | 🟣 |
| Neptune 211.44 Hz | 211.44 | Tone attributed to Neptune: dreams, spirituality, dissolution | 🟣 |
| Pluto 144.25 Hz | 144.25 | Tone attributed to Pluto: transformation, depth | 🟣 |
| Earth 194.18 Hz | 194.18 | Tone attributed to Earth: grounding, stability | 🟣 |

All ten are 🟣: these are attributions from sound-healing and astroacoustic practice, with no
research backing. Note that the beat values here exceed the usual 1–30 Hz perception range — the app
will show a hint about that. Source for every row: traditional practice / alternative medicine
literature.

---

## 🎵 Solfeggio

*The nine-tone Solfeggio series 174…963 Hz with their attributed meanings.*

| Entry | Beat | Carrier | Effect (as described in the data) | |
|---|---|---|---|---|
| 174 Hz — Foundation | 174.0 | 200 | Foundation: pain relief, a sense of safety, deep relaxation | 🟣 |
| 285 Hz — Regeneration | 285.0 | 285 | Regeneration: tissue regeneration, healing | 🟣 |
| 396 Hz — Release | 396.0 | 396 | Release: letting go of guilt and fear | 🟣 |
| 417 Hz — Change | 417.0 | 417 | Change: untying stuck situations, making change easier | 🟣 |
| 528 Hz — Miracles / Transformation | 528.0 | 528 | Miracles / Transformation: transformation, claimed "DNA repair", energy increase | 🟣 |
| 639 Hz — Connections | 639.0 | 639 | Connections: harmonising relationships, mutual understanding | 🟣 |
| 741 Hz — Expression | 741.0 | 741 | Expression: purity of consciousness, finding solutions, cleansing | 🟣 |
| 852 Hz — Order | 852.0 | 852 | Order: intuition, return to spiritual order | 🟣 |
| 963 Hz — Oneness | 963.0 | 963 | Oneness: divine consciousness, illumination | 🟣 |

The "DNA repair" wording on 528 Hz is a claim made in esoteric sources, reproduced here as a
description of that claim and not as a statement of fact. Source for every row: traditional practice
/ alternative medicine literature.

---

## 🎼 Tuning & Reference

*Tuning references: 432 vs 440 Hz, the Om tone and the 111 Hz tone.*

| Entry | Beat | Effect (as described in the data) | |
|---|---|---|---|
| 432 Hz — natural tuning | 432.0 | Alternative to the ISO 440 reference; attributed gentleness, relaxation, "oneness with nature" | 🟡 |
| 440 Hz — ISO 16 reference | 440.0 | The international standard tuning reference for A4; a neutral pitch, not a therapeutic claim | 🔵 |
| 417 Hz — Solfeggio tone | 417.0 | Solfeggio tone and pitch; attributed to untying stuck situations and easing change (see the Solfeggio category) | 🟣 |
| 136.1 Hz — Om tone | 136.1 | The "Om" tone, used as a year-of-the-Earth base; meditative ground, stability | 🟣 |
| 111 Hz — sacred frequency | 111.0 | Attributed activation and a sense of space opening up | 🟣 |

The 440 Hz row is marked 🔵 because ISO 16 is a documented standard, not because tuning at 440 Hz
has a therapeutic effect — the entry text says so explicitly.

---

## 🔬 Research & Studies

*Beats that are actual objects of peer-reviewed studies (gamma, alpha, theta, delta).*

| Entry | Beat | Effect (as described in the data) | |
|---|---|---|---|
| 40 Hz — gamma entrainment | 40.0 | Gamma stimulation; a subject of neurodegeneration research (sensory-neural stimulation) and of attention studies | 🟢 |
| 10 Hz — alpha entrainment | 10.0 | Alpha entrainment; among the most studied beats, used for relaxation and sustained attention | 🟢 |
| 4 Hz — theta entrainment | 4.0 | Theta entrainment; applied in sleep and meditation studies | 🔵 |
| 2 Hz — delta entrainment | 2.0 | Delta entrainment; low-frequency work in sleep studies | 🔵 |

This is the category to start from if you want the shortest distance between a frequency and actual
literature. Note that 🟢 means the beat is studied, not that the listed outcome is guaranteed. See
[docs/SCIENCE.md](SCIENCE.md).

---

## ⚡ Rife & Therapeutic

*Numeric therapeutic frequencies attributed to Royal Rife, grouped by purpose.*

All 40 entries are 🟣 traditional. `effect` text repeats what Rife's frequency sets are *listed* as;
none of it is clinically supported.

| Entry | Beat | Effect (as described in the data) | |
|---|---|---|---|
| Rife 72 Hz | 72.0 | Listed in Rife's infection sets as an antibacterial / antiviral frequency (foundation antibacterial tone) | 🟣 |
| Rife 76 Hz | 76.0 | Listed in Rife's infection sets as an antibacterial / antiviral frequency (general infection set) | 🟣 |
| Rife 80 Hz | 80.0 | Listed in Rife's infection sets as an antibacterial / antiviral frequency (microbial set) | 🟣 |
| Rife 83 Hz | 83.0 | Listed in Rife's infection sets as an antibacterial / antiviral frequency (microbial set) | 🟣 |
| Rife 87 Hz | 87.0 | Listed in Rife's infection sets as an antibacterial / antiviral frequency (general bacterial set) | 🟣 |
| Rife 100 Hz | 100.0 | Listed in Rife's infection sets as an antibacterial / antiviral frequency (broad infection set) | 🟣 |
| Rife 101 Hz | 101.0 | Listed in Rife's infection sets as an antibacterial / antiviral frequency (broad infection set) | 🟣 |
| Rife 105 Hz | 105.0 | Listed in Rife's infection sets as an antibacterial / antiviral frequency (bacterial set) | 🟣 |
| Rife 115 Hz | 115.0 | Listed in Rife's infection sets as an antibacterial / antiviral frequency (fungal and yeast set) | 🟣 |
| Rife 120 Hz | 120.0 | Listed in Rife's infection sets as an antibacterial / antiviral frequency (broad-spectrum infection set) | 🟣 |
| Rife 127 Hz | 127.0 | Listed in Rife's infection sets as an antibacterial / antiviral frequency (viral set) | 🟣 |
| Rife 140 Hz | 140.0 | Listed in Rife's infection sets as an antibacterial / antiviral frequency (viral and infection set) | 🟣 |
| Rife 152 Hz | 152.0 | Listed in Rife's inflammation sets as an anti-inflammatory frequency (general inflammation set) | 🟣 |
| Rife 155 Hz | 155.0 | Listed in Rife's inflammation sets as an anti-inflammatory frequency (inflammation and swelling set) | 🟣 |
| Rife 160 Hz | 160.0 | Listed in Rife's inflammation sets as an anti-inflammatory frequency (inflammation of soft tissue set) | 🟣 |
| Rife 165 Hz | 165.0 | Listed in Rife's inflammation sets as an anti-inflammatory frequency (chronic inflammation set) | 🟣 |
| Rife 212 Hz | 212.0 | Listed in Rife's inflammation sets as an anti-inflammatory frequency (inflammation set) | 🟣 |
| Rife 230 Hz | 230.0 | Listed in Rife's inflammation sets as an anti-inflammatory frequency (inflammatory process set) | 🟣 |
| Rife 174 Hz | 174.0 | Listed in Rife's pain sets as an analgesic frequency (general analgesic set) | 🟣 |
| Rife 176 Hz | 176.0 | Listed in Rife's pain sets as an analgesic frequency (pain and discomfort set) | 🟣 |
| Rife 180 Hz | 180.0 | Listed in Rife's pain sets as an analgesic frequency (pain and tension set) | 🟣 |
| Rife 190 Hz | 190.0 | Listed in Rife's pain sets as an analgesic frequency (pain relief set) | 🟣 |
| Rife 200 Hz | 200.0 | Listed in Rife's pain sets as an analgesic frequency (pain and inflammation set) | 🟣 |
| Rife 250 Hz | 250.0 | Listed in Rife's pain sets as an analgesic frequency (recovery and pain set) | 🟣 |
| Rife 141 Hz | 141.0 | Listed in Rife's nervous-system sets as a calming / support frequency (nervous system calming set) | 🟣 |
| Rife 144 Hz | 144.0 | Listed in Rife's nervous-system sets as a calming / support frequency (nervous tension set) | 🟣 |
| Rife 148 Hz | 148.0 | Listed in Rife's nervous-system sets as a calming / support frequency (nervous system support set) | 🟣 |
| Rife 154 Hz | 154.0 | Listed in Rife's nervous-system sets as a calming / support frequency (fatigue and nerves set) | 🟣 |
| Rife 186 Hz | 186.0 | Listed in Rife's nervous-system sets as a calming / support frequency (nervous tension set) | 🟣 |
| Rife 204 Hz | 204.0 | Listed in Rife's nervous-system sets as a calming / support frequency (nervous system support set) | 🟣 |
| Rife 156 Hz | 156.0 | Listed in Rife's emotional sets as a mood / stress balance frequency (emotional balance set) | 🟣 |
| Rife 192 Hz | 192.0 | Listed in Rife's emotional sets as a mood / stress balance frequency (emotional release set) | 🟣 |
| Rife 198 Hz | 198.0 | Listed in Rife's emotional sets as a mood / stress balance frequency (stress and mood set) | 🟣 |
| Rife 210 Hz | 210.0 | Listed in Rife's emotional sets as a mood / stress balance frequency (harmony and mood set) | 🟣 |
| Rife 226 Hz | 226.0 | Listed in Rife's emotional sets as a mood / stress balance frequency (fear and anxiety set) | 🟣 |
| Rife 216 Hz | 216.0 | Listed in Rife's general support sets as a vitality / tone frequency (general vitality set) | 🟣 |
| Rife 222 Hz | 222.0 | Listed in Rife's general support sets as a vitality / tone frequency (circulation and vitality set) | 🟣 |
| Rife 240 Hz | 240.0 | Listed in Rife's general support sets as a vitality / tone frequency (tissue and vitality set) | 🟣 |
| Rife 244 Hz | 244.0 | Listed in Rife's general support sets as a vitality / tone frequency (general support set) | 🟣 |
| Rife 260 Hz | 260.0 | Listed in Rife's general support sets as a vitality / tone frequency (detoxification set) | 🟣 |

Note that every beat here is above the 1–30 Hz range in which beats are usually perceived, so the
app will flag them as outside the typical perception range. This category exists because the
specification decided to keep the full traditional reference without editorial filtering.

---

## 🚀 Space & Consciousness

*Frequencies claimed by space-program and consciousness-oriented sources.*

| Entry | Beat | Effect (as described in the data) | |
|---|---|---|---|
| 432 Hz — claimed natural / space tuning | 432.0 | Circulated as a "natural", space-approved tuning for meditation and grounding; the approval claim itself is unverified | 🟡 |
| 528 Hz — claimed consciousness tone | 528.0 | Circulated as a consciousness and DNA-repair tone in space-oriented sources; no clinical support | 🟡 |
| 40 Hz — gamma, attention and consciousness research | 40.0 | Gamma entrainment; investigated for attention and for sensory-neural stimulation in neurodegeneration | 🟢 |
| 10 Hz — alpha, alertness in demanding conditions | 10.0 | Alpha entrainment; studied for sustained alertness, attention and performance under load | 🟢 |
| 7.83 Hz — Earth resonance in space environments | 7.83 | The Schumann resonance, used in space-oriented material as a grounding tone away from the ground reference | 🟡 |
| 136.1 Hz — Om tone as a meditative anchor | 136.1 | The "Om" tone; used in practice as an anchor for orientation and meditation in unfamiliar surroundings | 🟣 |
| 111 Hz — activation and spaciousness | 111.0 | Attributed activation and a sense of expanded space; a common tone in space-themed sound meditations | 🟣 |

The "space-approved" attribution on 432 Hz is called out in the data as unverified. There is no
agency endorsement of these frequencies.

---

## ✨ Healing & Energy

*Sound therapy and energy-medicine practices: tones, space harmonisation, grounding.*

| Entry | Beat | Effect (as described in the data) | |
|---|---|---|---|
| Earth–Sun tone 126.22 Hz | 126.22 | Tone used in sound healing for vitality, grounding and vitality of the body | 🟣 |
| Om tone 136.1 Hz | 136.1 | Base tone of sound-healing practice; attributed meditative calm and stability | 🟣 |
| Earth tone 194.18 Hz | 194.18 | Grounding and stability tone in sound-healing sessions | 🟣 |
| 111 Hz — activation | 111.0 | Attributed activation and a sense of space opening in energy practice | 🟣 |
| 432 Hz — natural tuning | 432.0 | Attributed softness, relaxation and harmony with nature | 🟡 |
| 128 Hz — tuning fork / vibroacoustic base | 128.0 | Tuning-fork C, used as the base for vibroacoustic and sound-bath sessions | 🟡 |
| 261.6 Hz — middle C anchor | 261.6 | Middle C; used in sound-healing practice as a neutral anchor and reference | 🟡 |

---

## Disclaimer

These frequencies and the effect descriptions come from research literature **and** from esoteric,
energy-based and alternative practices. The application is **not a medical device** and is not
intended for the diagnosis, treatment or prevention of any disease. Do not use it with epilepsy, a
cardiac pacemaker, during pregnancy, or with photosensitivity without consulting a doctor. Keep the
volume at a reasonable level.

Read [docs/SCIENCE.md](SCIENCE.md) for what the research does and does not support.