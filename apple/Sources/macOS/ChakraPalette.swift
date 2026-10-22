import AppKit
import BinauralCore

/// The colour of each chakra, and the rule the seven follow.
///
/// The order is the rainbow, from the bottom of the body to the top: red, orange,
/// yellow, green, light blue, blue, violet. It is the order everyone already knows, so
/// a reader can tell which chakra they are looking at from the colour alone — and the
/// colour is what the eye goes to first, before it reads the caption.
///
/// The shades are muted on purpose. A saturated red on a dark background is a glare,
/// and seven of them at once is a rainbow of noise. These keep the hue of each chakra
/// and give up the shout.
///
/// The light shades clear 3.7:1 on white and the dark ones clear 5.7:1 on the dark
/// surface. The frequency number is 34 pt semibold — large text — and the point on the
/// figure is a non-text element, so 3:1 is the bar both of them answer to, and both
/// clear it with room to spare.
enum ChakraPalette {

    /// The colour of the step at an index into ``ChakraSequence/steps`` (root first).
    static func color(forStepIndex index: Int) -> NSColor {
        colors[ChakraSequence.index(of: index)]
    }

    /// Earth first: stone, red, orange, yellow, green, light blue, blue, violet.
    ///
    /// The earth is a stone grey rather than a colour of the rainbow: it is not a
    /// chakra, it is the ground the seven stand on, and giving it a hue of its own would
    /// put it in the sequence's colour order when it is not in the sequence.
    static let colors: [NSColor] = [
        DynamicColor.make(light: 0x7A6E5C, dark: 0xB3A692),   // earth — stone
        DynamicColor.make(light: 0xC8503F, dark: 0xF0877A),   // root — red
        DynamicColor.make(light: 0xC06A22, dark: 0xF0A45F),   // sacral — orange
        DynamicColor.make(light: 0xA1810F, dark: 0xE3C453),   // solar plexus — yellow
        DynamicColor.make(light: 0x3F8A4C, dark: 0x6FBE7C),   // heart — green
        DynamicColor.make(light: 0x2E88A8, dark: 0x5FB6D2),   // throat — light blue
        DynamicColor.make(light: 0x4E63C4, dark: 0x8A9BEA),   // third eye — blue
        DynamicColor.make(light: 0x8149B0, dark: 0xB183DE)    // crown — violet
    ]
}
