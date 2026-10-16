import AppKit

/// A transparent, borderless panel that stays on top of everything -- all spaces,
/// fullscreen apps included -- without ever stealing keyboard focus or showing up in the
/// Dock or Cmd-Tab. Its content is the `FlockView` that `PetController` drives.
final class PetPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        // Clawd's app is never active (accessory policy, non-activating panel); without
        // this, AppKit would suppress the bubbles' full-text tooltips.
        allowsToolTipsWhenApplicationIsInactive = true

        let contentView = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        contentView.wantsLayer = true
        self.contentView = contentView
    }

    /// Never becomes key, so it never steals focus from whatever the user is doing.
    override var canBecomeKey: Bool { false }

    /// Never becomes main, for the same reason.
    override var canBecomeMain: Bool { false }
}
