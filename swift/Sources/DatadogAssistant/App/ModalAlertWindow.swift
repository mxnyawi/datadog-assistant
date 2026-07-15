import AppKit
import SwiftUI

/// The "unmissable popup" notification style: a floating, always-on-top alert
/// window for monitors whose effective style includes modal (P1s by default).
/// Deliberately not an NSAlert runModal — nothing blocks; it auto-dismisses
/// after 5 minutes, and a newer alert replaces the content.
@MainActor
final class ModalAlertWindow {
    static let shared = ModalAlertWindow()

    private var window: NSWindow?
    private var dismissWork: DispatchWorkItem?

    func show(title: String, body: String, url: URL?) {
        let content = ModalAlertView(
            title: title, message: body,
            onOpen: { [weak self] in
                if let url { LinkOpener.open(url) }
                self?.close()
            },
            onDismiss: { [weak self] in self?.close() })

        let host = NSHostingController(rootView: content)
        if window == nil {
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled]
            window.title = "Datadog Alert"
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.window = window
        } else {
            window?.contentViewController = host
        }
        // A newer alert can replace the content while the window is already
        // up — in that case the card re-runs its scale-in beat (desirable),
        // but the window must NOT re-fade.
        let alreadyVisible = window?.isVisible == true
        window?.center()
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            if alreadyVisible {
                window.makeKeyAndOrderFront(nil)
            } else if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                window.alphaValue = 1
                window.makeKeyAndOrderFront(nil)
            } else {
                window.alphaValue = 0
                window.makeKeyAndOrderFront(nil)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 1
                }
            }
        }

        // Give up after 5 minutes, like the Python modal.
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
    }

    private func close() {
        dismissWork?.cancel()
        dismissWork = nil
        guard let window else { return }
        // Symmetric with the entrance: fade out rather than blink, unless the
        // user asked for reduced motion (then just dismiss).
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
            })
        }
    }
}

private struct ModalAlertView: View {
    let title: String
    let message: String
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.red)
                    .symbolBounceOnAppearIfAvailable(reduceMotion: reduceMotion)
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Dismiss", action: onDismiss)
                Button("Open in Datadog", action: onOpen)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        // Settle in from 98% rather than popping — never from scale(0).
        .scaleEffect(appeared || reduceMotion ? 1 : 0.98)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appeared)
        .onAppear { appeared = true }
    }
}
