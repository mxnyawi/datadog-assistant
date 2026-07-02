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

/// Tabbed settings: each concern gets its own pane instead of one long
/// scroll. Changes that affect polling call onSave (which reloads the source);
/// pickers and toggles persist immediately — no hidden "unsaved" state.
struct SettingsView: View {
    let onSave: () -> Void

    var body: some View {
        TabView {
            SourceSettingsTab(onSave: onSave)
                .tabItem { Label("Source", systemImage: "key.fill") }
            FilterSettingsTab(onSave: onSave)
                .tabItem { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
            NotificationSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell.badge.fill") }
            JiraSettingsTab()
                .tabItem { Label("Jira", systemImage: "ticket.fill") }
            GitHubSettingsTab(onSave: onSave)
                .tabItem { Label("GitHub", systemImage: "arrow.triangle.pull") }
        }
        .frame(width: 470)
        .padding(12)
    }
}

// MARK: - Source (credentials)

private struct SourceSettingsTab: View {
    let onSave: () -> Void

    @State private var apiKey = ""
    @State private var appKey = ""
    @State private var site = Credentials.currentSite()
    @State private var error: String?
    @State private var hasExistingKeys = Credentials.load() != nil
    @State private var lastPassEntry = ""
    @State private var hasLastPass = LastPassConfig.load() != nil
    @State private var lastPassLoggedIn = false
    @State private var showLastPassSetup = false
    @State private var authMode = AuthMode.current
    @State private var subdomain = Credentials.currentSubdomain()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Credential source")
                .font(.headline)
            Picker("", selection: Binding(get: { authMode }, set: { setMode($0) })) {
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

            switch authMode {
            case .sample:
                Text("Running on sample data — nothing to configure. Pick Keychain "
                     + "or LastPass above to connect your org.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .keychain:
                keychainSection
            case .lastPass:
                lastPassSection
            }

            if authMode != .sample {
                Divider()
                linksSection
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(height: 380)
        .onAppear {
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

    private var keychainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hasExistingKeys
                 ? "Keys are stored in the macOS Keychain. Enter new values to replace them."
                 : "Stored in the macOS Keychain, never written to disk in plain text. "
                   + "App key needs monitors_read (plus monitors_write for mute, "
                   + "incident_read and metrics_read for full features).")
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
            HStack {
                if hasExistingKeys {
                    Button("Remove keys", role: .destructive) {
                        Credentials.clear()
                        hasExistingKeys = false
                        setMode(.sample)
                    }
                }
                Spacer()
                Button("Save keys") { saveKeys() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiKey.isEmpty || appKey.isEmpty)
            }
        }
    }

    private var lastPassSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hasLastPass
                 ? "Keys are fetched from this entry at runtime via the lpass CLI — "
                   + (lastPassLoggedIn ? "logged in ✓" : "run Set up… to unlock the vault.")
                 : "Fetch the team's Datadog keys (and GitHub / Jira tokens) from a "
                   + "LastPass secure note instead of storing them locally. Set up… "
                   + "installs the lpass CLI and logs you in.")
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
        }
    }

    /// Org subdomain for browser links. With the generic app.* host, orgs
    /// that use a vanity subdomain get bounced to a login page on every link.
    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Form {
                TextField("Org subdomain (yourorg → yourorg.\(Credentials.currentSite()))",
                          text: $subdomain)
                    .onSubmit { onSave() }   // rebuild monitor links now
            }
            Text("Browser links open at \(subdomain.isEmpty ? "app" : subdomain)"
                 + ".\(Credentials.currentSite()) — set your org's subdomain so "
                 + "Datadog doesn't re-ask you to log in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: subdomain) { newValue in
            Credentials.setSubdomain(newValue)
        }
    }

    private var authSourceHint: String {
        switch authMode {
        case .sample:
            return "Running on sample data. Choose Keychain or LastPass to connect real data."
        case .keychain:
            return "Using keys stored in the macOS Keychain."
        case .lastPass:
            return lastPassLoggedIn
                ? "Using the shared LastPass vault — keys are fetched at runtime, nothing is stored locally."
                : "LastPass selected. Run Set up… (or `lpass login`) to unlock the vault."
        }
    }

    /// Persist the chosen source, keep the control in sync, and reload.
    private func setMode(_ mode: AuthMode) {
        authMode = mode
        AuthMode.set(mode)
        onSave()
    }

    private func saveKeys() {
        do {
            try Credentials(apiKey: apiKey, appKey: appKey, site: site).save()
            hasExistingKeys = true
            apiKey = ""
            appKey = ""
            setMode(.keychain)
        } catch {
            self.error = "Keychain write failed: \(error.localizedDescription)"
        }
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
}

// MARK: - Filters

private struct FilterSettingsTab: View {
    let onSave: () -> Void

    @State private var filters = FilterConfig.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Monitor filters")
                .font(.headline)
            Text("Only monitors matching these filters are fetched and shown — "
                 + "same as the Python app's tag/name filter. Tags are OR'd; the "
                 + "quickest way to pick them is the Filter dropdown in the panel.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Name contains", text: $filters.name)
            }

            if FilterConfig.knownTags().isEmpty {
                Text("No tags discovered yet — they appear after the first poll.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                tagPicker
            }

            if !filters.tags.isEmpty {
                Text("Active tags: \(filters.tags.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Clear all filters") {
                    filters = FilterConfig()
                    apply()
                }
                .disabled(!filters.isActive)
                Spacer()
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(height: 340)
    }

    private var tagPicker: some View {
        Menu {
            ForEach(FilterConfig.knownTagsByKey(), id: \.key) { group in
                Menu(group.key) {
                    ForEach(group.tags, id: \.self) { tag in
                        Button {
                            if let index = filters.tags.firstIndex(of: tag) {
                                filters.tags.remove(at: index)
                            } else {
                                filters.tags.append(tag)
                            }
                        } label: {
                            if filters.tags.contains(tag) {
                                Label(tag, systemImage: "checkmark")
                            } else {
                                Text(tag)
                            }
                        }
                    }
                }
            }
        } label: {
            Label(filters.tags.isEmpty ? "Choose tags…" : "\(filters.tags.count) tag(s) selected",
                  systemImage: "tag.fill")
        }
        .fixedSize()
    }

    private func apply() {
        filters.save()
        onSave()
    }
}

// MARK: - Notifications

private struct NotificationSettingsTab: View {
    @State private var settings = NotificationSettings.load()
    @State private var lastPreviewedSound = NotificationSettings.load().soundName

    private let sounds = NotificationSettings.availableSounds()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notifications")
                .font(.headline)
            Text("Changes apply immediately.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Form {
                Toggle("Enable notifications", isOn: $settings.enabled)
                Toggle("Notify on warnings", isOn: $settings.notifyOnWarn)
                    .disabled(!settings.enabled)
                Toggle("Notify on recovery", isOn: $settings.notifyOnRecovery)
                    .disabled(!settings.enabled)

                Divider()

                Toggle("Play sound", isOn: $settings.soundEnabled)
                    .disabled(!settings.enabled)
                Picker("Alert sound", selection: $settings.soundName) {
                    Text("System default").tag("")
                    ForEach(sounds, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!settings.enabled || !settings.soundEnabled)

                Divider()

                Picker("Re-notify while still alerting", selection: $settings.renotifyMinutes) {
                    ForEach(NotificationSettings.renotifyChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Off" : "every \(minutes) min").tag(minutes)
                    }
                }
                .disabled(!settings.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(height: 340)
        .onChange(of: settings) { newValue in
            newValue.save()
            // Instant feedback when trying sounds from the dropdown.
            if newValue.soundName != lastPreviewedSound {
                lastPreviewedSound = newValue.soundName
                if !newValue.soundName.isEmpty, newValue.soundEnabled {
                    NSSound(named: newValue.soundName)?.play()
                }
            }
        }
    }
}

// MARK: - Jira

private struct JiraSettingsTab: View {
    @State private var baseURL = ""
    @State private var email = ""
    @State private var projectKey = ""
    @State private var issueType = "Task"
    @State private var autoCreate = 0
    @State private var token = ""
    @State private var configured = JiraConfig.load() != nil
    @State private var status: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jira ticketing")
                .font(.headline)
            Text(configured
                 ? "Configured — alerts show a “Jira ticket” action. Enter new values to change."
                 : "One-tap tickets from any alert. In LastPass mode the API token can "
                   + "come from the shared note's jiraToken field; otherwise it's stored "
                   + "in the Keychain.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Site (yourorg.atlassian.net)", text: $baseURL)
                TextField("Account email", text: $email)
                TextField("Project key (e.g. OPS)", text: $projectKey)
                Picker("Issue type", selection: $issueType) {
                    ForEach(JiraConfig.issueTypes, id: \.self) { Text($0) }
                }
                Picker("Auto-create on alert", selection: $autoCreate) {
                    Text("Off").tag(0)
                    Text("P1 only").tag(1)
                    Text("P1 + P2").tag(2)
                }
                SecureField(AuthMode.current == .lastPass
                            ? "API token (blank = LastPass jiraToken field)"
                            : "API token",
                            text: $token)
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
            }

            HStack {
                if configured {
                    Button("Disable Jira", role: .destructive) {
                        JiraConfig.clear()
                        configured = false
                        baseURL = ""; email = ""; projectKey = ""; token = ""
                        status = nil
                    }
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(baseURL.isEmpty || email.isEmpty || projectKey.isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(height: 340)
        .onAppear {
            if let config = JiraConfig.load() {
                baseURL = config.baseURL
                email = config.email
                projectKey = config.projectKey
                issueType = config.issueType
                autoCreate = config.autoCreatePriority
            }
        }
    }

    private func save() {
        var config = JiraConfig(baseURL: baseURL, email: email, projectKey: projectKey)
        config.issueType = issueType
        config.autoCreatePriority = autoCreate
        config.save()
        if !token.isEmpty {
            do {
                try JiraConfig.saveToken(token)
                token = ""
            } catch {
                status = "Keychain write failed: \(error.localizedDescription)"
                isError = true
                return
            }
        }
        configured = true
        status = "Saved."
        isError = false
    }
}

// MARK: - GitHub

private struct GitHubSettingsTab: View {
    let onSave: () -> Void

    @State private var gitHubToken = ""
    @State private var gitHubRepos = ""
    @State private var hasGitHub = GitHubConfig.load() != nil
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GitHub — change correlation")
                .font(.headline)
            Text(hasGitHub
                 ? "Configured. Enter new values to replace."
                 : "A fine-grained token with repo read access, plus repos to watch for "
                   + "merges. Map a repo to a service with service=owner/repo; bare "
                   + "owner/repo entries apply org-wide. Comma-separated. In LastPass "
                   + "mode the token can come from the note's githubToken field.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                SecureField("GitHub token", text: $gitHubToken)
                TextField("Repos (payments=acme/pay-api, acme/platform)", text: $gitHubRepos)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if hasGitHub {
                    Button("Disable GitHub", role: .destructive) {
                        GitHubConfig.clear()
                        hasGitHub = false
                        onSave()
                    }
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(gitHubRepos.isEmpty
                              || (gitHubToken.isEmpty && AuthMode.current != .lastPass))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(height: 340)
    }

    private func save() {
        let repoSpecs = gitHubRepos
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !repoSpecs.isEmpty else { return }
        do {
            // Blank token in LastPass mode: repos persist, the token resolves
            // from the vault's githubToken field at load time.
            if gitHubToken.isEmpty {
                GitHubConfig.saveRepoSpecsOnly(repoSpecs)
            } else {
                try GitHubConfig(token: gitHubToken, repoSpecs: repoSpecs).save()
                gitHubToken = ""
            }
            hasGitHub = true
            onSave()
        } catch {
            self.error = "Keychain write failed: \(error.localizedDescription)"
        }
    }
}
