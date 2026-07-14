import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onSave: () -> Void
    private let monitoredServices: () -> [String]

    init(onSave: @escaping () -> Void,
         monitoredServices: @escaping () -> [String] = { [] }) {
        self.onSave = onSave
        self.monitoredServices = monitoredServices
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(
                onSave: { [weak self] in self?.onSave() },
                monitoredServices: { [weak self] in self?.monitoredServices() ?? [] }))
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
    var monitoredServices: () -> [String] = { [] }

    var body: some View {
        // Each tab scrolls inside a fixed-height TabView. Without this, a tab
        // whose content is taller than the window (Source with the scope
        // checklist, Notifications) overflows upward into the tab strip on
        // first open until a relayout — the "overlap" bug.
        TabView {
            tab("Source", "key.fill") { SourceSettingsTab(onSave: onSave) }
            tab("Filters", "line.3.horizontal.decrease.circle") { FilterSettingsTab(onSave: onSave) }
            tab("Notifications", "bell.badge.fill") { NotificationSettingsTab() }
            tab("Jira", "ticket.fill") { JiraSettingsTab() }
            tab("GitHub", "arrow.triangle.pull") {
                GitHubSettingsTab(onSave: onSave, monitoredServices: monitoredServices)
            }
        }
        .frame(width: 470, height: 490)
        .padding(12)
    }

    private func tab<Content: View>(_ title: String, _ icon: String,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        ScrollView { content() }
            .tabItem { Label(title, systemImage: icon) }
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
    @State private var browser = LinkOpener.currentBrowser()
    @State private var apiKeyCmd = UserDefaults.standard.string(forKey: "apiKeyCmd") ?? ""
    @State private var appKeyCmd = UserDefaults.standard.string(forKey: "appKeyCmd") ?? ""
    // Token-first: default to the access-token sub-tab unless a key pair is
    // what's actually stored.
    @State private var useAccessToken =
        Credentials.hasStoredAccessToken() || !Credentials.hasStoredKeyPair()
    @State private var accessToken = ""
    @State private var accessTokenCmd = UserDefaults.standard.string(forKey: "accessTokenCmd") ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Credential source")
                .font(.headline)
            Picker("", selection: Binding(get: { authMode }, set: { setMode($0) })) {
                Text("This Mac").tag(AuthMode.device)
                Text("Team LastPass").tag(AuthMode.lastPass)
                Text("Sample data").tag(AuthMode.sample)
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
                Text("Running on sample data — nothing to configure. Pick This Mac "
                     + "or Team LastPass above to connect your org.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .device:
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
        // Min, not fixed: the token section's scope checklist expands
        // past 380pt and must not clip.
        .frame(minHeight: 430)
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
            // Two credential shapes since Datadog's 2026 auth modernization:
            // the classic pair, or one scoped access token.
            Picker("", selection: $useAccessToken) {
                Text("Access token").tag(true)
                Text("API + App keys").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if useAccessToken {
                accessTokenFields
            } else {
                keyPairFields
            }
        }
    }

    private var keyPairFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hasExistingKeys && !Credentials.hasStoredAccessToken()
                 ? "Keys are stored securely on this Mac. Enter new values to replace them."
                 : "Stored securely on this Mac (encrypted on disk, no password prompt). "
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
                TextField("API key command (optional, e.g. op read op://…)", text: $apiKeyCmd)
                    .onSubmit { saveCommands() }
                TextField("App key command (optional)", text: $appKeyCmd)
                    .onSubmit { saveCommands() }
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

    private var accessTokenFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Credentials.hasStoredAccessToken()
                 ? "An access token is stored securely on this Mac. Paste a new one to replace it."
                 : "One scoped credential instead of a key pair — create it under "
                   + "Personal Settings → Access Tokens (or on a service account for a "
                   + "non-expiring token).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Which scopes does the token need?") {
                ScopeChecklistView()
                    .padding(.top, 4)
            }
            .font(.caption)
            Form {
                SecureField("Access token (ddpat_… or ddsat_…)", text: $accessToken)
                Picker("Site", selection: $site) {
                    ForEach(Credentials.knownSites, id: \.self) { Text($0) }
                }
                TextField("Token command (optional, e.g. op read op://…)", text: $accessTokenCmd)
                    .onSubmit { saveCommands() }
            }
            Text("Personal tokens expire (up to 1 year) — you'll re-paste one when "
                 + "Datadog reports 401/403. Service-account tokens can be non-expiring.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if Credentials.hasStoredAccessToken() {
                    Button("Remove token", role: .destructive) {
                        Credentials.clear()
                        hasExistingKeys = false
                        useAccessToken = false
                        setMode(.sample)
                    }
                }
                Spacer()
                Button("Save token") { saveAccessToken() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(accessToken.trimmingCharacters(in: .whitespaces).isEmpty)
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
                Picker("Open links in", selection: $browser) {
                    Text("System default").tag("")
                    ForEach(LinkOpener.installedBrowsers(), id: \.self) { Text($0).tag($0) }
                }
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
        .onChange(of: browser) { newValue in
            LinkOpener.setBrowser(newValue)
        }
    }

    private var authSourceHint: String {
        switch authMode {
        case .sample:
            return "Running on sample data. Choose This Mac or Team LastPass to connect real data."
        case .device:
            return Credentials.hasStoredAccessToken()
                ? "Using an access token stored securely on this Mac."
                : "Using keys stored securely on this Mac."
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

    private func saveCommands() {
        UserDefaults.standard.set(apiKeyCmd, forKey: "apiKeyCmd")
        UserDefaults.standard.set(appKeyCmd, forKey: "appKeyCmd")
        UserDefaults.standard.set(accessTokenCmd, forKey: "accessTokenCmd")
        onSave()
    }

    private func saveKeys() {
        do {
            try Credentials(apiKey: apiKey, appKey: appKey, site: site).save()
            hasExistingKeys = true
            apiKey = ""
            appKey = ""
            setMode(.device)
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func saveAccessToken() {
        do {
            try Credentials.saveAccessToken(
                accessToken.trimmingCharacters(in: .whitespaces), site: site)
            hasExistingKeys = true
            accessToken = ""
            setMode(.device)
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
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
                Toggle("Hide No-Data monitors", isOn: $filters.hideNoData)
                    .onChange(of: filters.hideNoData) { _ in apply() }
            }
            Text("No-Data monitors carry no signal, so they're hidden by default "
                 + "(their triage checks are skipped too). Turn this off to see them, "
                 + "grouped as likely-broken vs quiet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
        .frame(minHeight: 430)
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
                Picker("Style", selection: $settings.style) {
                    ForEach(NotificationSettings.Style.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .disabled(!settings.enabled)
                Toggle("Notify on warnings", isOn: $settings.notifyOnWarn)
                    .disabled(!settings.enabled)
                Toggle("Notify on No Data (likely broken only)", isOn: $settings.notifyOnNoData)
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
                Picker("Daily digest", selection: $settings.digestHour) {
                    Text("Off").tag(-1)
                    ForEach([7, 8, 9, 10, 11], id: \.self) { Text("\($0):00").tag($0) }
                }
                .disabled(!settings.enabled)
            }

            DisclosureGroup("Per-priority overrides") {
                Form {
                    ForEach([1, 2, 3], id: \.self) { priority in
                        severityRow(priority)
                    }
                }
                Text("P1 defaults to Both (unmissable popup) nagging every 10 min; "
                     + "P3 to banner every hour. “Inherit” uses the base settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!settings.enabled)

            HStack {
                Spacer()
                Button("Test notification") { NotificationManager.shared.sendTest() }
                    .disabled(!settings.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minHeight: 430)
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

    /// One priority's override row: style + renotify, with "Inherit" tags.
    private func severityRow(_ priority: Int) -> some View {
        HStack {
            Text("P\(priority)")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, alignment: .leading)
            Picker("", selection: Binding(
                get: { settings.severityRules[priority]?.style },
                set: { settings.severityRules[priority, default: .init()].style = $0 }
            )) {
                Text("Inherit").tag(NotificationSettings.Style?.none)
                ForEach(NotificationSettings.Style.allCases, id: \.self) {
                    Text($0.label).tag(NotificationSettings.Style?.some($0))
                }
            }
            .labelsHidden()
            Picker("", selection: Binding(
                get: { settings.severityRules[priority]?.renotifyMinutes },
                set: { settings.severityRules[priority, default: .init()].renotifyMinutes = $0 }
            )) {
                Text("Inherit").tag(Int?.none)
                ForEach(NotificationSettings.renotifyChoices, id: \.self) { minutes in
                    Text(minutes == 0 ? "No re-notify" : "every \(minutes)m").tag(Int?.some(minutes))
                }
            }
            .labelsHidden()
        }
    }
}

// MARK: - Jira

private struct JiraSettingsTab: View {
    @State private var authMode: JiraConfig.Auth = .oauth
    @State private var baseURL = ""
    @State private var email = ""
    @State private var projectKey = ""
    @State private var issueType = "Task"
    @State private var autoCreate = 0
    @State private var token = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var connected = JiraOAuth.isConnected
    @State private var busy = false
    @State private var status: String?
    @State private var isError = false

    private var hasLastPassCreds: Bool {
        AuthMode.current == .lastPass
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jira ticketing")
                .font(.headline)

            Picker("", selection: $authMode) {
                Text("OAuth (client ID + secret)").tag(JiraConfig.Auth.oauth)
                Text("API token").tag(JiraConfig.Auth.token)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if authMode == .oauth {
                oauthSection
            } else {
                tokenSection
            }

            Form {
                TextField("Project key (e.g. OPS)", text: $projectKey)
                Picker("Issue type", selection: $issueType) {
                    ForEach(JiraConfig.issueTypes, id: \.self) { Text($0) }
                }
                Picker("Auto-create on alert", selection: $autoCreate) {
                    Text("Off").tag(0)
                    Text("P1 only").tag(1)
                    Text("P1 + P2").tag(2)
                }
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Disable Jira", role: .destructive) {
                    JiraConfig.clear()
                    connected = false
                    baseURL = ""; email = ""; projectKey = ""; token = ""
                    clientID = ""; clientSecret = ""
                    status = nil
                }
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Test") { testConnection() }
                    .disabled(busy || projectKey.isEmpty)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || projectKey.isEmpty
                              || (authMode == .token && (baseURL.isEmpty || email.isEmpty)))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minHeight: 430)
        .onAppear { loadStored() }
    }

    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(connected
                 ? "Connected ✓ — tickets are created via OAuth"
                   + (JiraOAuth.siteURL().map { " at \($0)" } ?? "") + "."
                 : hasLastPassCreds
                   ? "Client ID and secret come from the LastPass note's jiraClientID / "
                     + "jiraClientSecret fields — leave the fields blank and hit Connect."
                   : "Enter your Atlassian OAuth app's client ID and secret (redirect URL "
                     + "must be http://localhost:8917/callback), then Connect.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField(hasLastPassCreds ? "Client ID (blank = LastPass jiraClientID)"
                                           : "Client ID", text: $clientID)
                SecureField(hasLastPassCreds ? "Client secret (blank = LastPass jiraClientSecret)"
                                             : "Client secret", text: $clientSecret)
                TextField("Site (yourorg.atlassian.net — picks the right org)", text: $baseURL)
            }
            HStack {
                Spacer()
                Button(connected ? "Reconnect…" : "Connect Jira…") { connect() }
                    .disabled(busy)
            }
        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Legacy mode: email + API token Basic auth. In LastPass mode the token "
                 + "can come from the note's jiraToken field.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Site (yourorg.atlassian.net)", text: $baseURL)
                TextField("Account email", text: $email)
                SecureField(hasLastPassCreds ? "API token (blank = LastPass jiraToken field)"
                                             : "API token", text: $token)
            }
        }
    }

    private func loadStored() {
        let config = JiraConfig.loadStored()
        authMode = config.auth
        baseURL = config.baseURL
        email = config.email
        projectKey = config.projectKey
        issueType = config.issueType
        autoCreate = config.autoCreatePriority
        clientID = JiraOAuth.storedClientID()
    }

    private func currentConfig() -> JiraConfig {
        var config = JiraConfig(baseURL: baseURL, projectKey: projectKey)
        config.auth = authMode
        config.email = email
        config.issueType = issueType
        config.autoCreatePriority = autoCreate
        return config
    }

    private func save() {
        let config = currentConfig()
        config.save()
        do {
            if authMode == .oauth, !clientID.isEmpty {
                try JiraOAuth.saveClientCredentials(id: clientID, secret: clientSecret)
                clientSecret = ""
            }
            if authMode == .token, !token.isEmpty {
                try JiraConfig.saveToken(token)
                token = ""
            }
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
            isError = true
            return
        }
        status = authMode == .oauth && !connected
            ? "Saved — now hit Connect to authorize." : "Saved."
        isError = false
    }

    /// Save first (so credentials are in place), then run the browser flow.
    private func connect() {
        save()
        guard !isError else { return }
        busy = true; status = "Opening browser for Atlassian consent…"; isError = false
        let host = baseURL
        Task {
            do {
                let site = try await JiraOAuth.connect(preferredHost: host)
                connected = true
                if baseURL.isEmpty {
                    baseURL = site.replacingOccurrences(of: "https://", with: "")
                }
                currentConfig().save()
                status = "Connected ✓ (\(site))"
                isError = false
            } catch {
                status = error.localizedDescription
                isError = true
            }
            busy = false
        }
    }

    private func testConnection() {
        save()
        guard !isError else { return }
        busy = true; status = "Testing…"; isError = false
        let config = currentConfig()
        Task {
            let report = await JiraClient.connectionTest(config: config)
            status = report
            isError = report.lowercased().contains("failed")
            busy = false
        }
    }
}

// MARK: - GitHub

private struct GitHubSettingsTab: View {
    let onSave: () -> Void
    var monitoredServices: () -> [String] = { [] }

    @State private var gitHubToken = ""
    @State private var gitHubRepos = ""
    @State private var hasGitHub = GitHubConfig.load() != nil
    @State private var ghAvailable = false
    @State private var ghToken = false
    @State private var suggestedRepos: [String] = []
    @State private var orgs: [String] = []
    @State private var selectedOwner = ""     // "" = your own repos
    @State private var customOwner = ""       // free-text org/owner not in the list
    @State private var loadingRepos = false
    @State private var error: String?

    /// The owner whose repos the suggestion list should show.
    private var currentOwner: String {
        let custom = customOwner.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? selectedOwner : custom
    }
    private var currentOwnerLabel: String {
        currentOwner.isEmpty ? "your repos" : currentOwner
    }

    /// Repos-only saves are fine whenever a token resolves elsewhere: the
    /// LastPass note or the gh CLI.
    private var tokenOptional: Bool { AuthMode.current == .lastPass || ghToken }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GitHub — change correlation & CI")
                .font(.headline)
            Text(hasGitHub
                 ? "Configured — merges and CI pipeline runs feed the Changes tab. "
                   + "Enter new values to replace."
                 : "Repos to watch for merges and CI runs. Map a repo to a service with "
                   + "service=owner/repo; bare owner/repo entries apply org-wide. "
                   + "Comma-separated.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // gh CLI status: when it's logged in, no token is needed at all.
            HStack(spacing: 6) {
                Image(systemName: ghToken ? "checkmark.circle.fill"
                      : ghAvailable ? "exclamationmark.circle" : "circle.dashed")
                    .foregroundStyle(ghToken ? .green : .secondary)
                Text(ghToken
                     ? "gh CLI detected and logged in — token field is optional."
                     : ghAvailable
                       ? "gh CLI found but not logged in — run `gh auth login`, or paste a token."
                       : "No gh CLI — paste a fine-grained token (or add githubToken to the "
                         + "LastPass note).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                SecureField(tokenOptional ? "GitHub token (optional)" : "GitHub token",
                            text: $gitHubToken)
                TextField("Repos (payments=acme/pay-api, acme/platform)", text: $gitHubRepos)
            }

            // Pull repo suggestions from your own account or any organization
            // you belong to — most org repos aren't owned by your user.
            if ghToken {
                HStack(spacing: 8) {
                    Picker("From", selection: $selectedOwner) {
                        Text("Your repos").tag("")
                        ForEach(orgs, id: \.self) { org in Text(org).tag(org) }
                    }
                    .fixedSize()
                    .onChange(of: selectedOwner) { _ in
                        customOwner = ""
                        loadRepos()
                    }
                    TextField("or type an org", text: $customOwner)
                        .frame(width: 130)
                        .onSubmit { loadRepos() }
                    if loadingRepos { ProgressView().controlSize(.small) }
                }

                // The one-click path: match this owner's repos against the
                // service: tags on your monitors and fill them in for you.
                let services = monitoredServices()
                if !services.isEmpty {
                    Button {
                        autofillFromMonitors(services: services)
                    } label: {
                        Label("Auto-fill from \(services.count) monitored "
                              + "service\(services.count == 1 ? "" : "s")",
                              systemImage: "wand.and.stars")
                            .font(.caption)
                    }
                    .buttonStyle(.pressable)
                    .foregroundColor(Theme.info)
                    .disabled(loadingRepos)
                    .help("Match \(currentOwnerLabel)'s repos to your monitors' "
                          + "service tags and add the ones that line up.")
                }

                if !suggestedRepos.isEmpty {
                    Menu {
                        ForEach(suggestedRepos, id: \.self) { repo in
                            Button(repo) { appendRepo(repo) }
                        }
                    } label: {
                        Label("Or add manually from \(currentOwnerLabel)…", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .fixedSize()
                } else if !loadingRepos {
                    Text("No repos found for \(currentOwnerLabel). "
                         + "For a private org, make sure `gh auth login` granted read:org.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                    .disabled(gitHubRepos.isEmpty || (gitHubToken.isEmpty && !tokenOptional))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minHeight: 430)
        .onAppear { probeGH() }
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
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Detect the gh CLI + login state and fetch repo suggestions, off the
    /// main thread (each is a subprocess).
    private func probeGH() {
        Task.detached {
            let available = GitHubCLI.isInstalled
            let token = available && GitHubCLI.authToken() != nil
            let repos = token ? GitHubCLI.listRepos() : []
            let orgs = token ? GitHubCLI.listOrgs() : []
            await MainActor.run {
                ghAvailable = available
                ghToken = token
                suggestedRepos = repos
                self.orgs = orgs
            }
        }
    }

    /// Re-fetch repo suggestions for the currently-chosen owner (your account,
    /// a picked org, or a typed one). Off the main thread — it shells out.
    private func loadRepos() {
        let owner = currentOwner
        loadingRepos = true
        Task.detached {
            let repos = GitHubCLI.listRepos(owner: owner)
            await MainActor.run {
                suggestedRepos = repos
                loadingRepos = false
            }
        }
    }

    private func appendRepo(_ repo: String) {
        let existing = gitHubRepos.trimmingCharacters(in: .whitespaces)
        guard !existing.contains(repo) else { return }
        gitHubRepos = existing.isEmpty ? repo : "\(existing), \(repo)"
    }

    /// Fetch the chosen owner's repos and map them to the monitors' services,
    /// filling the repos field with `service=owner/repo` specs. The user still
    /// reviews and hits Save, since fuzzy name matching can mis-guess.
    private func autofillFromMonitors(services: [String]) {
        let owner = currentOwner
        loadingRepos = true
        error = nil
        Task.detached {
            let repos = GitHubCLI.listRepos(owner: owner)
            let specs = matchReposToServices(services: services, repos: repos)
            await MainActor.run {
                loadingRepos = false
                suggestedRepos = repos
                if specs.isEmpty {
                    error = "No repos in \(currentOwnerLabel) matched your monitored "
                        + "services (\(services.prefix(4).joined(separator: ", "))…). "
                        + "Add them manually below."
                } else {
                    mergeSpecs(specs)
                }
            }
        }
    }

    /// Merge new `service=owner/repo` specs into the field, skipping any whose
    /// repo is already listed.
    private func mergeSpecs(_ specs: [String]) {
        var current = gitHubRepos
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        func repoPart(_ s: String) -> String { s.split(separator: "=").last.map(String.init) ?? s }
        let have = Set(current.map(repoPart))
        for spec in specs where !have.contains(repoPart(spec)) {
            current.append(spec)
        }
        gitHubRepos = current.joined(separator: ", ")
    }

}

/// Match each monitored service to the best-named repo. Normalizes both sides
/// (lowercase, drop common suffixes like -api/-service, keep only
/// alphanumerics) and prefers an exact name match over a containment one, so
/// service "payments" lines up with "acme/payments-api". Each repo is used at
/// most once. Free function so it's callable from a detached task without any
/// actor-isolation ceremony.
private func matchReposToServices(services: [String], repos: [String]) -> [String] {
    func norm(_ s: String) -> String {
        var x = s.lowercased()
        for suffix in ["-api", "-service", "-svc", "-app", "-backend", "-server", "-worker"]
        where x.hasSuffix(suffix) { x = String(x.dropLast(suffix.count)) }
        return x.filter { $0.isLetter || $0.isNumber }
    }
    var specs: [String] = []
    var usedRepos = Set<String>()
    for service in services {
        let ns = norm(service)
        guard !ns.isEmpty else { continue }
        var best: String?
        var bestScore = 0
        for repo in repos where !usedRepos.contains(repo) {
            let name = repo.split(separator: "/").last.map(String.init) ?? repo
            let nr = norm(name)
            var score = 0
            if nr == ns { score = 3 }
            else if nr.contains(ns) || ns.contains(nr) { score = 2 }
            if score > bestScore { bestScore = score; best = repo }
        }
        if let best, bestScore >= 2 {
            specs.append("\(service)=\(best)")
            usedRepos.insert(best)
        }
    }
    return specs
}
