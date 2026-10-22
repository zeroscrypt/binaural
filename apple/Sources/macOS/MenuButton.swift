import AppKit

/// A button that shows its menu on the press, the way a toolbar's overflow button does.
///
/// AppKit only does that by itself for a button inside a toolbar. In a plain window a
/// button that carries a `menu` swallows the click and shows nothing — which is what
/// the corner menu did, and why the button looked alive and did nothing.
///
/// Popping the menu from the button's *action* does not work either: the action runs
/// on the release, and a menu opened there is dismissed at once, because the release
/// lands in the menu that was just opened. The menu has to open on the press, which is
/// where a menu is supposed to open, so it is opened from `mouseDown` instead.
final class MenuButton: NSButton {

    override func mouseDown(with event: NSEvent) {
        guard let menu else {
            super.mouseDown(with: event)
            return
        }
        // The button does not take the press: the menu does, and it tracks the mouse
        // until a choice is made or the click is abandoned.
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: bounds.height),
            in: self
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        // A right click on a menu button shows the same menu, which is what every other
        // menu button on the system does.
        rightMouseUp(with: event)
    }
}
