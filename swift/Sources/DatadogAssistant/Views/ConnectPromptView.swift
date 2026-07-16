import SwiftUI
import AppKit

/// Shown in the panel when there are no usable credentials — instead of
/// silently serving sample data, the app asks you to connect, right here.
/// Access token is the primary path (Datadog's recommendation); API keys and
/// the team LastPass vault are one tap away.
struct ConnectPromptView: View {
    @State private var useAccessToken = true
    @State private var accessToken = ""
    @State private var apiKey = ""
    @State private var appKey = ""
    @State private var site = Credentials.currentSite()
    @State private var busy = false
    @State private var succeeded = false
    @State private var error: String?
    @State private var showScopes = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            hero

            Picker("", selection: $useAccessToken) {
                Text("Access token").tag(true)
                Text("API keys").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if useAccessToken {
                SecureField("Access token (ddpat_… or ddsat_…)", text: $accessToken)
                    .textFieldStyle(.roundedBorder)
                DisclosureGroup("Which scopes does the token need?", isExpanded: $showScopes) {
                    ScopeChecklistView().padding(.top, 4)
                }
                .font(.caption)
            } else {
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("Application key", text: $appKey)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Site", selection: $site) {
                ForEach(Credentials.knownSites, id: \.self) { Text($0) }
            }
            .labelsHidden()

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if succeeded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.ok)
                        .symbolBounceOnAppearIfAvailable(reduceMotion: reduceMotion)
                } else if busy {
                    ProgressView().controlSize(.small)
                }
                Button(action: connect) {
                    Text(succeeded ? "Connected" : (busy ? "Connecting…" : "Connect"))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || succeeded || primaryDisabled)
            }

            HStack {
                Button("Team LastPass vault…") { openSettings() }
                    .buttonStyle(.link)
                Spacer()
                Button("Explore sample data") { useSample() }
                    .buttonStyle(.link)
            }
            .font(.caption)
        }
    }

    private var hero: some View {
        HStack(spacing: 10) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect to Datadog")
                    .font(.system(size: 15, weight: .bold))
                Text("Paste a token to see your monitors.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
        }
    }

    private var primaryDisabled: Bool {
        useAccessToken
            ? accessToken.trimmingCharacters(in: .whitespaces).isEmpty
            : apiKey.isEmpty || appKey.isEmpty
    }

    private func connect() {
        busy = true; error = nil
        let useToken = useAccessToken
        let token = accessToken.trimmingCharacters(in: .whitespaces)
        let api = apiKey, app = appKey, site = self.site
        Task.detached {
            let result = useToken
                ? LastPassSetup.validateAccessToken(token, site: site)
                : LastPassSetup.validateDatadog(apiKey: api, appKey: app, site: site)
            await MainActor.run {
                busy = false
                guard result.ok else {
                    error = result.detail
                    return
                }
                do {
                    if useToken {
                        try Credentials.saveAccessToken(token, site: site)
                    } else {
                        try Credentials(apiKey: api, appKey: app, site: site).save()
                    }
                } catch {
                    self.error = "Couldn't save: \(error.localizedDescription)"
                    return
                }
                // Success beat: flash a ✓ for ~0.4s before the root swaps to
                // the dashboard. The delay lives ONLY on the happy path —
                // errors above return immediately with no added latency.
                succeeded = true
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    NotificationCenter.default.post(name: .reloadCredentials, object: nil)
                }
            }
        }
    }

    private func useSample() {
        AuthMode.set(.sample)
        NotificationCenter.default.post(name: .reloadCredentials, object: nil)
    }

    private func openSettings() {
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }
}
