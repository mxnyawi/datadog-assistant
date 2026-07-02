import SwiftUI

/// Guided sheet for setting up the LastPass CLI from inside the app: install
/// the `lpass` CLI, log in (with authenticator support), then pick and
/// validate the shared-vault entry. On success it hands the chosen entry back
/// to the caller, which persists it as the active LastPassConfig.
struct LastPassSetupView: View {
    /// Called with the validated LastPass config when setup completes.
    let onComplete: (LastPassConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var installed = LastPass.isInstalled
    @State private var loggedIn = false
    @State private var email = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var needsOTP = false
    @State private var entry = ""
    @State private var entries: [LastPassEntry] = []
    @State private var apiField = "datadogAPIKey"
    @State private var appField = "datadogAPPKey"
    @State private var site = Credentials.currentSite()
    @State private var availableFields: [String] = []
    @State private var busy = false
    @State private var status: String?
    @State private var isError = false
    @State private var log: [String] = []
    @State private var testReport = ""
    @State private var testOK: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up LastPass")
                .font(.title3.bold())
            Text("Fetch your team's Datadog keys from a shared LastPass vault. "
                 + "Nothing is stored on this machine — keys are read at runtime via the lpass CLI.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Step 1 — install the CLI
            GroupBox("1 · LastPass CLI") {
                HStack {
                    Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(installed ? .green : .secondary)
                    Text(installed ? "lpass is installed." : "The lpass CLI isn't installed yet.")
                    Spacer()
                    if !installed {
                        Button("Install") { install() }
                            .disabled(busy)
                    }
                }
                .padding(6)
            }

            // Step 2 — log in
            GroupBox("2 · Log in") {
                VStack(alignment: .leading, spacing: 8) {
                    if loggedIn {
                        Label("Logged in to LastPass.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Log out") { logout() }.disabled(busy)
                    } else {
                        TextField("LastPass email", text: $email)
                            .textContentType(.username)
                        SecureField("Master password", text: $password)
                        if needsOTP {
                            SecureField("Authenticator code", text: $otp)
                            Text("Your account has multi-factor auth. Enter the current code.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button(needsOTP ? "Submit code" : "Log in") { login() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(busy || !installed || email.isEmpty || password.isEmpty
                                      || (needsOTP && otp.isEmpty))
                    }
                }
                .padding(6)
            }
            .disabled(!installed)

            // Step 3 — choose the entry (and map its fields)
            GroupBox("3 · Shared vault entry") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Note / folder", selection: $entry) {
                            Text(entries.isEmpty ? "No entries loaded" : "Select a note…").tag("")
                            ForEach(entries, id: \.self) { Text($0.name).tag($0.name) }
                        }
                        Button("Refresh") { loadEntries() }.disabled(busy || !loggedIn)
                    }
                    TextField("…or type the entry path", text: $entry)

                    Picker("Datadog site", selection: $site) {
                        ForEach(Credentials.knownSites, id: \.self) { Text($0) }
                    }

                    if !availableFields.isEmpty {
                        Divider()
                        Text("Map the keys to this note's fields:")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("API key field", selection: $apiField) {
                            ForEach(fieldOptions, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("App key field", selection: $appField) {
                            ForEach(fieldOptions, id: \.self) { Text($0).tag($0) }
                        }
                        Text("Fields found: \(availableFields.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("The secure note should hold datadogAPIKey / datadogAPPKey "
                             + "(or custom fields you'll map after picking it).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }
            .disabled(!loggedIn)

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Console: install/login log, or the Test transcript when present.
            if !testReport.isEmpty || !log.isEmpty {
                let text = testReport.isEmpty ? log.joined(separator: "\n") : testReport
                ScrollView {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: testReport.isEmpty ? 72 : 150)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Test") { test() }
                    .disabled(busy || !loggedIn || entry.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !loggedIn || entry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { refreshState() }
    }

    // MARK: Actions — all subprocess work runs off the main thread (detached),
    // then applies its result back on the main actor.

    private func refreshState() {
        Task.detached {
            let installed = LastPass.isInstalled
            let loggedIn = installed && LastPass.statusLoggedIn()
            let entries = loggedIn ? LastPassSetup.listEntries() : []
            await MainActor.run {
                self.installed = installed
                self.loggedIn = loggedIn
                self.entries = entries
            }
        }
    }

    private func install() {
        busy = true; status = nil; log = []
        Task.detached {
            let result = LastPassSetup.ensureInstalled { appendLog($0) }
            await MainActor.run {
                busy = false
                installed = result.installed
                if let error = result.error { fail(error) }
                else { status = "lpass installed."; isError = false }
            }
        }
    }

    private func login() {
        busy = true; status = nil; log = []
        let email = self.email, password = self.password, otp = self.otp
        Task.detached {
            let result = LastPassSetup.login(email: email, password: password, otp: otp) { appendLog($0) }
            let entries = result == .ok ? LastPassSetup.listEntries() : []
            await MainActor.run {
                busy = false
                switch result {
                case .ok:
                    loggedIn = true; needsOTP = false; self.otp = ""
                    self.entries = entries
                    status = "Logged in ✓"; isError = false
                case .mfaRequired:
                    needsOTP = true
                    status = "Enter your authenticator code."; isError = false
                case .failed(let message):
                    fail(message)
                }
            }
        }
    }

    private func logout() {
        busy = true; status = nil
        Task.detached {
            LastPassSetup.logout()
            await MainActor.run {
                busy = false; loggedIn = false; entries = []; availableFields = []
                status = "Logged out."; isError = false
            }
        }
    }

    private func loadEntries() {
        busy = true
        Task.detached {
            let entries = LastPassSetup.listEntries()
            await MainActor.run {
                busy = false
                self.entries = entries
                if entries.isEmpty { status = "No entries returned by `lpass ls`."; isError = true }
            }
        }
    }

    private func test() {
        let chosen = entry.trimmingCharacters(in: .whitespaces)
        guard !chosen.isEmpty else { fail("Pick or type an entry."); return }
        busy = true; status = nil; log = []; testReport = ""
        let api = apiField, app = appField, site = self.site, ref = currentRef()
        Task.detached {
            let result = LastPassSetup.diagnostics(entry: ref, apiField: api, appField: app, site: site)
            // On failure, surface the note's fields so the user can remap.
            let fields = result.ok ? [] : LastPassSetup.availableFields(entry: ref)
            await MainActor.run {
                busy = false
                testReport = result.report
                testOK = result.ok
                if result.ok {
                    status = "Read OK — Save to use this note."; isError = false
                } else {
                    if !fields.isEmpty { availableFields = fields; autoMap(fields) }
                    fail("Test failed — see the output below.")
                }
            }
        }
    }

    private func save() {
        let chosen = entry.trimmingCharacters(in: .whitespaces)
        guard !chosen.isEmpty else { fail("Pick or type an entry."); return }
        busy = true; status = nil
        let api = apiField, app = appField, site = self.site, ref = currentRef()
        Task.detached {
            let result = LastPassSetup.validate(entry: ref, apiField: api, appField: app)
            // On failure, read the note's actual fields so the user can map them.
            let fields = result.ok ? [] : LastPassSetup.availableFields(entry: ref)
            await MainActor.run {
                busy = false
                if result.ok {
                    Credentials.setSite(site)
                    var config = LastPassConfig(entry: chosen)
                    config.entryID = (ref != chosen) ? ref : ""
                    config.apiKeyField = api
                    config.appKeyField = app
                    onComplete(config)
                    dismiss()
                    return
                }
                availableFields = fields
                autoMap(fields)
                if fields.isEmpty {
                    fail("Couldn't read “\(chosen)”. Make sure it's a secure note you can "
                         + "access (not an empty folder), then try again.")
                } else {
                    fail("Couldn't read \(api) / \(app) from “\(chosen)”. Pick which of this "
                         + "note's fields holds each key below, then Save again.")
                }
            }
        }
    }

    // MARK: Helpers

    /// Field names offered in the mapping pickers: the note's own fields plus
    /// the current/default selections, so the Picker's tag always exists.
    private var fieldOptions: [String] {
        var options = availableFields
        for field in [apiField, appField, "datadogAPIKey", "datadogAPPKey"]
        where !field.isEmpty && !options.contains(field) {
            options.append(field)
        }
        return options
    }

    /// Best-effort guess of which discovered fields hold the API / App keys.
    private func autoMap(_ fields: [String]) {
        guard !fields.isEmpty else { return }
        if let match = fields.first(where: { $0.caseInsensitiveCompare("datadogAPIKey") == .orderedSame })
            ?? fields.first(where: { $0.lowercased().contains("api") }) {
            apiField = match
        }
        if let match = fields.first(where: { $0.caseInsensitiveCompare("datadogAPPKey") == .orderedSame })
            ?? fields.first(where: { let l = $0.lowercased(); return l.contains("app") && !l.contains("api") }) {
            appField = match
        }
    }

    /// The reference to hand to `lpass` for the selected entry: its unique ID
    /// when the entry came from the dropdown (immune to spaces / duplicate
    /// names), else the typed name.
    private func currentRef() -> String {
        let name = entry.trimmingCharacters(in: .whitespaces)
        if let match = entries.first(where: { $0.name == name }), !match.id.isEmpty {
            return match.id
        }
        return name
    }

    private func fail(_ message: String) { status = message; isError = true }

    private func appendLog(_ line: String) {
        Task { @MainActor in log.append(line) }
    }
}
