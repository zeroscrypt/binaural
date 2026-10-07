# What the science says

A plain-language summary of the evidence behind binaural beats, written so the app's behaviour can be
justified — and so nothing it does gets oversold.

- [The mechanism](#the-mechanism)
- [What is reasonably well established](#what-is-reasonably-well-established)
- [Where the evidence is weak](#where-the-evidence-is-weak)
- [What this means for the app](#what-this-means-for-the-app)
- [Sources](#sources)

---

## The mechanism

1. A tone is played into each ear separately. Left ear: `fL`. Right ear: `fR`.
2. Both signals travel to the **medial superior olive (MSO)** in the brainstem — the first station in
   the auditory pathway where the two ears are compared.
3. The comparison produces a response at the **difference frequency**, `|fL − fR|`.
4. That difference is what people report perceiving as a slow flicker, pulse or tone inside the head.

The key consequence: the beat frequency is **not present in the audio signal**. Each ear receives a
plain sine wave. The difference exists only after the two signals meet in the listener's brain. That
is also why the effect vanishes on speakers — the tones mix in the air, both ears get the same
waveform, and there is nothing left to compare.

## What is reasonably well established

**Perception happens roughly in the 1–30 Hz range.**
This overlaps the main EEG bands, which is not a coincidence: sub-auditory fluctuations in an ongoing
tone correspond to the amplitude-modulation range the auditory system can follow. Below roughly 1 Hz
the fluctuation is too slow to track; above about 30 Hz the difference starts to be heard as a
separate tone rather than a beat.

**Low carriers work better.**
Carrier frequency is the centre of the pair, `(fL + fR) / 2`. Responses have been measured at
carriers around 400 Hz, become unreliable above roughly 3 kHz, and sensitivity appears to peak near
250 Hz. This is the single most practically useful finding: it is why the app defaults to a 200 Hz
carrier. Note what it does *not* do: there is no carrier warning. The app only flags the beat when
it leaves the perceivable range, so a high carrier will not be second-guessed for you.

**Two measurable responses exist in the EEG.**
The **frequency-following response (FFR)** locks onto the carrier frequency, and the
**auditory steady-state response (ASSR)** appears at the beat frequency. Both have been demonstrated
experimentally with scalp recordings. This is the strongest part of the evidence base: the brain
measurably tracks the beat.

**Noise masks the effect.**
Adding broadband noise to the signal weakens entrainment. The app therefore ships with no noise
layer at all, and any noise option is off by default.

**Studies use 5–15 minute sessions.**
Typical stimulation durations in the literature are 5–15 minutes, which is where the planned
15-minute session timer comes from.

## Where the evidence is weak

**Results are inconsistent, and that is the headline.**
A 2023 systematic review looked at 14 relevant studies. Six supported the entrainment hypothesis;
nine did not or were inconclusive. Individual studies also differ in how they measure outcomes — EEG
markers, subjective reports, sleep quality, cognitive performance — which makes them hard to compare
directly.

**Effects vary between people.**
Not everyone perceives a beat, and among those who do, the reported intensity differs widely.

**Tracking is not the same as benefit.**
The FFR and ASSR findings show that the auditory system follows the beat. They do not, on their own,
show that listening to it improves sleep, mood, attention or any health outcome. That step needs its
own evidence, and that evidence is exactly where the studies disagree.

**Much of the popular material is not scientific at all.**
Entries in the reference marked 🟣 or 🟡 come from esoteric, energy-based or alternative practice.
They are kept in the app so the catalogue is complete and clearly labelled, not because they are
supported. "DNA repair", "detoxification" and agency endorsements are claims, not findings.

So the honest summary: the phenomenon is real and measurable, subjective reports of an effect are
common, and the claim that it *does* something specific for you is contested. This is a field with
genuinely ambiguous data. The app makes no promise about what you will experience and no therapeutic
claim of any kind.

## What this means for the app

| Evidence point | Consequence in the app |
|---|---|
| Beats are perceived around 1–30 Hz | A hint appears when the beat falls outside 0.5–100 Hz; presets stay near the studied range |
| Lower carriers work better | Default carrier 200 Hz; no carrier-based warning (only the beat range is checked) |
| FFR and ASSR are measurable | Both the carrier and the beat are always shown, so you can see what you are actually generating |
| Noise weakens entrainment | No noise in the signal by default |
| Sessions run 5–15 minutes | Planned 15-minute timer with a smooth fade-out |
| Evidence is mixed | Honest wording in the UI and docs; no medical claims, ever |

## Sources

- **Systematic review (2023)** — assessment of the entrainment hypothesis across 14 studies, 6
  supporting it and 9 not.
  <https://pmc.ncbi.nlm.nih.gov/articles/PMC10198548/>
- **Pratt et al. (2009)** — cortical responses to binaural beats as a function of carrier frequency.
- **Reznik & Allen (2020)**, *eNeuro* — FFR at the carrier and ASSR at the beat frequency.
  <https://www.eneuro.org/content/7/2/ENEURO.0232-19.2020>
- **Garcia-Argibay et al. (2025)**, *Scientific Reports* — white-noise masking of entrainment.
  <https://www.nature.com/articles/s41598-025-88517-z>
- **Schwarz & Taylor** — carrier-frequency sensitivity, including the peak near 250 Hz.

See also [`docs/SPEC.md §2.1`](SPEC.md) for the project's own notes on the literature.

## Disclaimer

This application is **not a medical device** and is not intended for the diagnosis, treatment or
prevention of any disease. Binaural beats are sound, not a substance, and they do not replace one:
nothing here helps with withdrawal, craving, tolerance or relapse, and the app does not treat
dependence of any kind. Withdrawal from alcohol and from sedatives can be dangerous; anything to do
with using less of something is a question for a doctor or a specialist service. Do not use it with
epilepsy, a cardiac pacemaker, during pregnancy, or with photosensitivity without consulting a
doctor. Keep the volume at a reasonable level.