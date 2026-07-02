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
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        // Give up after 5 minutes, like the Python modal.
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
    }

    private func close() {
        dismissWork?.cancel()
        dismissWork = nil
        window?.orderOut(nil)
    }
}

private struct ModalAlertView: View {
    let title: String
    let message: String
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.red)
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
    }
}
