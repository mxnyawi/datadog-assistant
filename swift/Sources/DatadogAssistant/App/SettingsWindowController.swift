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
    @State private var gitHubToken = ""
    @State private var gitHubRepos = ""
    @State private var error: String?
    @State private var hasExistingKeys = Credentials.load() != nil
    @State private var hasGitHub = GitHubConfig.load() != nil
    @State private var lastPassEntry = ""
    @State private var hasLastPass = LastPassConfig.load() != nil
    @State private var lastPassLoggedIn = false
    @State private var showLastPassSetup = false
    @State private var authMode = AuthMode.current

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Credential source")
                .font(.headline)
            // A custom binding so only user selection drives the reload; setting
            // `authMode` programmatically elsewhere just updates the display.
            Picker("", selection: Binding(
                get: { authMode },
                set: { setMode($0) }
            )) {
                Text("Sample data").tag(AuthMode.sample)
                Text("Keychain").tag(AuthMode.keychain)
                Text("LastPass").tag(AuthMode.lastPass)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(authSourceHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

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

            Divider()

            Text("GitHub (optional) — change correlation")
                .font(.headline)
            Text(hasGitHub
                 ? "Configured. Enter new values to replace, or clear the repos field to disable."
                 : "A fine-grained token with repo read access, plus repos to watch for merges. Map a repo to a service with service=owner/repo; bare owner/repo entries apply org-wide. Comma-separated.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                SecureField("GitHub token", text: $gitHubToken)
                TextField("Repos (payments=acme/pay-api, acme/platform)", text: $gitHubRepos)
            }

            Divider()

            Text("LastPass (optional) — shared team vault")
                .font(.headline)
            Text(hasLastPass
                 ? "Keys are fetched from this entry at runtime via the lpass CLI — \(lastPassLoggedIn ? "logged in ✓" : "run Set up… (or `lpass login`) to unlock the vault.")"
                 : "Fetch the team's Datadog keys (and GitHub token) from a LastPass secure note instead of storing them locally. Set up… installs the lpass CLI and logs you in; note fields default to datadogAPIKey / datadogAPPKey / githubToken.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Entry (e.g. Shared-SRE/datadog-assistant)", text: $lastPassEntry)
            }

            HStack {
                if hasLastPass {
                    Button("Disable LastPass", role: .destructive) {
                        LastPassConfig.clear()
                        hasLastPass = false
                        lastPassEntry = ""
                        setMode(.sample)
                    }
                }
                Spacer()
                Button("Set up…") { showLastPassSetup = true }
                Button("Use LastPass") { saveLastPass() }
                    .disabled(lastPassEntry.trimmingCharacters(in: .whitespaces).isEmpty)
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
                        setMode(.sample)
                    }
                }
                Spacer()
                Button("Use sample data") { setMode(.sample) }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((apiKey.isEmpty || appKey.isEmpty)
                              && (gitHubToken.isEmpty || gitHubRepos.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let existing = Credentials.load() { site = existing.site }
            if let lastPass = LastPassConfig.load() {
                lastPassEntry = lastPass.entry
                lastPassLoggedIn = LastPass.isLoggedIn()
            }
        }
        .sheet(isPresented: $showLastPassSetup) {
            LastPassSetupView { config in
                config.save()
                lastPassEntry = config.entry
                hasLastPass = true
                lastPassLoggedIn = LastPass.isLoggedIn()
                setMode(.lastPass)
            }
        }
    }

    private var authSourceHint: String {
        switch authMode {
        case .sample:
            return "Running on sample data. Choose Keychain or LastPass below to connect real data."
        case .keychain:
            return "Using keys stored in the macOS Keychain."
        case .lastPass:
            return lastPassLoggedIn
                ? "Using the shared LastPass vault — keys are fetched at runtime, nothing is stored locally."
                : "LastPass selected. Run Set up… (or `lpass login`) to unlock the vault."
        }
    }

    /// Persist the chosen source, keep the segmented control in sync, and
    /// reload. Persisting the mode is what stops the app from falling back to
    /// another source (and its Keychain prompt) the next time it opens.
    private func setMode(_ mode: AuthMode) {
        authMode = mode
        AuthMode.set(mode)
        onSave()
    }

    private func saveLastPass() {
        var config = LastPassConfig.load() ?? LastPassConfig(entry: "")
        config.entry = lastPassEntry.trimmingCharacters(in: .whitespaces)
        guard !config.entry.isEmpty else { return }
        config.save()
        hasLastPass = true
        lastPassLoggedIn = LastPass.isLoggedIn()
        setMode(.lastPass)
    }

    private func save() {
        do {
            var savedKeys = false
            if !apiKey.isEmpty && !appKey.isEmpty {
                try Credentials(apiKey: apiKey, appKey: appKey, site: site).save()
                savedKeys = true
                hasExistingKeys = true
            }
            let repoSpecs = gitHubRepos
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !gitHubToken.isEmpty && !repoSpecs.isEmpty {
                try GitHubConfig(token: gitHubToken, repoSpecs: repoSpecs).save()
            }
            // Entering keys explicitly selects the Keychain source.
            if savedKeys { setMode(.keychain) } else { onSave() }
        } catch {
            self.error = "Keychain write failed: \(error.localizedDescription)"
        }
    }
}
