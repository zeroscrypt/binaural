import AppKit

/// A text field whose click target is taller than the field itself.
///
/// Two rules pull against each other here. SPEC §7.2 asks for a 44×44 px click target,
/// and AppKit cannot draw a bezeled field's text in the middle of a box taller than
/// the field's own — the text is always pinned to the top, however tall the box is. A
/// 44 pt field therefore shows a number floating at the top of an empty-looking box.
///
/// So the field keeps the height of its own text, which is also the compact look, and
/// the missing band is added here as hit slop. The number sits in the middle of its
/// bezel, and the bezel sits in the middle of a 44 pt row.
final class TallTargetTextField: NSTextField {

    /// SPEC §7.2's minimum click target, in points.
    static let minimumTarget: CGFloat = 44

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the *superview's* coordinates, not ours — the field is an
        // arranged subview of a row, so only the first one sits at the origin. Comparing
        // the raw point against `bounds` would therefore miss the field.
        let local = convert(point, from: superview)
        let band = bounds.insetBy(dx: 0, dy: -(Self.minimumTarget - bounds.height) / 2)
        return band.contains(local) ? self : nil
    }
}
