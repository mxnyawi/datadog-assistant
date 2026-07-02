import SwiftUI

/// Guided sheet for setting up the LastPass CLI from inside the app: install
/// the `lpass` CLI, log in (with authenticator support), then pick and
/// validate the shared-vault entry. On success it hands the chosen entry back
/// to the caller, which persists it as the active LastPassConfig.
struct LastPassSetupView: View {
    /// Called with the validated entry name when setup completes.
    let onComplete: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var installed = LastPass.isInstalled
    @State private var loggedIn = false
    @State private var email = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var needsOTP = false
    @State private var entry = ""
    @State private var entries: [String] = []
    @State private var busy = false
    @State private var status: String?
    @State private var isError = false
    @State private var log: [String] = []

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

            // Step 3 — choose the entry
            GroupBox("3 · Shared vault entry") {
                VStack(alignment: .leading, spacing: 8) {
                    if !entries.isEmpty {
                        Picker("Entry", selection: $entry) {
                            Text("Select…").tag("")
                            ForEach(entries, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("Entry (e.g. Shared-SRE/datadog-assistant)", text: $entry)
                    Text("The secure note holds datadogAPIKey / datadogAPPKey "
                         + "(and optionally githubToken).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            if !log.isEmpty {
                ScrollView {
                    Text(log.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 72)
                .background(Color(nsColor: .textBackgroundColor))
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .disabled(busy || !loggedIn || entry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
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
                busy = false; loggedIn = false; entries = []
                status = "Logged out."; isError = false
            }
        }
    }

    private func save() {
        let chosen = entry.trimmingCharacters(in: .whitespaces)
        guard !chosen.isEmpty else { fail("Pick or type an entry."); return }
        busy = true; status = nil
        Task.detached {
            let result = LastPassSetup.validate(entry: chosen,
                                                apiField: "datadogAPIKey",
                                                appField: "datadogAPPKey")
            await MainActor.run {
                busy = false
                if result.ok { onComplete(chosen); dismiss() }
                else { fail(result.error ?? "Validation failed.") }
            }
        }
    }

    // MARK: Helpers

    private func fail(_ message: String) { status = message; isError = true }

    private func appendLog(_ line: String) {
        Task { @MainActor in log.append(line) }
    }
}
