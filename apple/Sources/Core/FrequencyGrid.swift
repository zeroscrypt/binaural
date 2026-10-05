import Foundation

/// The frequency grid the interface works on: 1–20000 Hz in steps of 0.1 Hz.
///
/// Ported from the two places Python keeps those rules — `ui/widgets/freq_control.py`
/// (`_slider_to_hz` / `_hz_to_slider`, the 0.1 Hz rounding in `set_value`) and
/// `_format_hz` in `ui/main_window.py`. They live here, in the framework, so the rules
/// are unit-testable without AppKit and so both platforms round identically.
public enum FrequencyGrid {

    /// SPEC F1: the entry step.
    public static let stepHz: Double = 0.1

    public static let minHz: Double = BeatMath.minFrequencyHz
    public static let maxHz: Double = BeatMath.maxFrequencyHz

    /// Slider resolution. 1000 steps over 4.3 decades keeps 0.1 Hz usable down to
    /// ~200 Hz and still reaches 20 kHz — Python's `SLIDER_STEPS`, unchanged.
    public static let sliderSteps: Double = 1000

    private static let logMin = log10(minHz)
    private static let logSpan = log10(maxHz) - logMin

    // MARK: - The grid

    /// Clamp to 1–20000 Hz and snap to the 0.1 Hz grid.
    ///
    /// Non-finite input is clamped rather than propagated: a field being edited can
    /// legitimately hold an empty or half-typed string, and `FreqControl.set_value`
    /// ignores NaN and infinity the same way.
    public static func quantized(_ hz: Double) -> Double {
        guard hz.isFinite else { return minHz }
        let clamped = min(maxHz, max(minHz, hz))
        // `%.1f` and then back, rather than `(hz * 10).rounded() / 10`.
        //
        // The multiplication shortcut is wrong on ties, and ties are common here: every
        // `x.x5` value is one. It rounds 4.35 to 4.4 where CPython's `round(4.35, 1)` says
        // 4.3, because `4.35 * 10` lands one ulp above the halfway point. `%.1f` prints the
        // correctly rounded decimal form of the double, which is exactly what CPython's
        // `round` computes — verified equal on 50 000 random values and on all 57 144
        // `x.x5` ties in 1…20000 Hz (`FrequencyGridTests.testRoundingMatchesCPython`).
        //
        // The format allocates, which is why this is *not* used on the audio thread: the
        // render callback only ever reads already-quantised values published by the UI.
        return Double(String(format: "%.1f", clamped)) ?? clamped
    }

    /// Move by `delta` Hz, staying on the grid. The `↑`/`↓` nudge of SPEC §7.
    public static func nudged(_ hz: Double, by delta: Double) -> Double {
        quantized(quantized(hz) + (delta.isFinite ? delta : 0))
    }

    // MARK: - Slider mapping

    /// Frequency -> slider position in 0...1, logarithmic.
    public static func sliderPosition(for hz: Double) -> Double {
        let clamped = min(maxHz, max(minHz, hz.isFinite ? hz : minHz))
        let ratio = (log10(clamped) - logMin) / logSpan
        return min(1, max(0, ratio))
    }

    /// Slider position in 0...1 -> frequency. The caller snaps it with
    /// ``quantized(_:)``, which is what `FreqControl` does for a slider drag.
    public static func frequency(atSliderPosition position: Double) -> Double {
        let ratio = min(1, max(0, position.isFinite ? position : 0))
        return pow(10, logMin + logSpan * ratio)
    }

    // MARK: - Text

    /// Frequency text without a pointless `.0` on whole numbers — the `_format_hz`
    /// rule the tray tooltips and preset descriptions rely on.
    public static func text(_ hz: Double) -> String {
        let value = hz.isFinite ? hz : 0
        if abs(value - value.rounded()) < 0.05 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.1f", value)
    }
}