import AppKit

/// The width a numeric field needs for the widest value it can hold.
///
/// A fixed width makes a field showing `163.5` look empty and a field showing `20000.0`
/// look cramped, and neither is the number's fault. The width is computed from the
/// longest value the field can take, so it is as narrow as it can be and never
/// truncates.
///
/// It does **not** follow the text as it is typed: a field that changes width under
/// the cursor is worse to type in than one that is slightly too wide.
enum FieldMetrics {

    /// The width of a bezeled field showing `text` in `font`, with room for the
    /// bezel's own padding and the caret.
    static func width(for text: String, font: NSFont) -> CGFloat {
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        return (textWidth + 16).rounded()
    }
}
