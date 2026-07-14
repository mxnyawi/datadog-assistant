import AppKit
import SwiftUI

/// Borderless, non-activating panel — replaces NSPopover so we control the
/// chrome: no arrow, continuous 13pt corners (the Sonoma+ menu radius), and
/// the system popover material, adapting to light/dark automatically.
final class FloatingPanel: NSPanel {
    /// Called when the user asks the panel to go away (Esc). The owning
    /// controller hides the panel and tears down its dismiss monitors.
    var onDismiss: (() -> Void)?

    init(contentView: NSView, size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 13
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        contentView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: effect.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        self.contentView = effect
    }

    // Borderless panels refuse key status by default; we want it so the panel
    // can host focused controls (search, filter fields).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc dismisses, like a menu.
    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}
