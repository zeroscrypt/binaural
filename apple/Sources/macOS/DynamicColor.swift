import AppKit

/// Build an `NSColor` that follows the window's appearance.
///
/// System colours (`.systemBlue`, `.controlAccentColor`) would resolve this for free,
/// but they are *system* colours: they move when macOS updates and they are not the
/// values the theme pins. A hex pair is the same number the Qt side carries in
/// `theme.py`, so the two implementations cannot drift apart by accident.
enum DynamicColor {

    /// A colour from two hexes, one for the light appearance and one for the dark.
    static func make(light: UInt32, dark: UInt32) -> NSColor {
        func resolve(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? resolve(dark)
                : resolve(light)
        }
    }
}
