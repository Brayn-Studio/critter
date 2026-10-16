import AppKit

/// A transparent, borderless panel that stays on top of everything -- all spaces,
/// fullscreen apps included -- without ever stealing keyboard focus or showing up in the
/// Dock or Cmd-Tab. It hosts the `ClawdLayer`(s) drawn by `PetController`/`AppDelegate`.
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

        let contentView = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        contentView.wantsLayer = true
        self.contentView = contentView
    }

    /// Never becomes key, so it never steals focus from whatever the user is doing.
    override var canBecomeKey: Bool { false }

    /// Never becomes main, for the same reason.
    override var canBecomeMain: Bool { false }
}
