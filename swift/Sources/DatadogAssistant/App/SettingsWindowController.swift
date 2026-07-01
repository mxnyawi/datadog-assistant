import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onSave: () -> Void

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(onSave: { [weak self] in
                self?.onSave()
                self?.window?.close()
            }))
            let window = NSWindow(contentViewController: host)
            window.title = "Datadog Assistant Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let onSave: () -> Void

    @State private var apiKey = ""
    @State private var appKey = ""
    @State private var site = "datadoghq.com"
    @State private var error: String?
    @State private var hasExistingKeys = Credentials.load() != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Datadog credentials")
                .font(.headline)
            Text(hasExistingKeys
                 ? "Keys are stored in the macOS Keychain. Enter new values to replace them."
                 : "Stored in the macOS Keychain, never written to disk in plain text. App key needs monitors_read (plus monitors_write for mute, incident_read and metrics_read for full features).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                SecureField("API key", text: $apiKey)
                SecureField("Application key", text: $appKey)
                Picker("Site", selection: $site) {
                    ForEach(Credentials.knownSites, id: \.self) { Text($0) }
                }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if hasExistingKeys {
                    Button("Remove keys", role: .destructive) {
                        Credentials.clear()
                        hasExistingKeys = false
                        onSave()
                    }
                }
                Spacer()
                Button("Use sample data") { onSave() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiKey.isEmpty || appKey.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let existing = Credentials.load() { site = existing.site }
        }
    }

    private func save() {
        do {
            try Credentials(apiKey: apiKey, appKey: appKey, site: site).save()
            onSave()
        } catch {
            self.error = "Keychain write failed: \(error.localizedDescription)"
        }
    }
}
