import AppKit
import SwiftUI

/// Borderless, non-activating glass panel — replaces NSPopover so we control
/// the chrome entirely: no arrow, continuous 20pt corners, behind-window blur.
final class FloatingPanel: NSPanel {
    init(contentView: NSView, size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)   // the design is dark glass

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 20
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

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
    // can host focused controls (search, settings fields) later.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
