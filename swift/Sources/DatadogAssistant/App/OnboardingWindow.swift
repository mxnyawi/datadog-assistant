import AppKit
import SwiftUI

/// First-run welcome window: pick how the app should authenticate before the
/// menu bar panel means anything. Shown once, when no credential source has
/// been chosen yet; every path here is also reachable later via Settings.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var finished = false
    private let onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    /// Has the user already made (or been migrated into) a credential choice?
    /// `hasCredentials` is the result of the `Credentials.load()` the caller
    /// already performed — never re-load here: in inferred-LastPass mode a
    /// load shells out to `lpass` synchronously, and this runs on the main
    /// thread during launch.
    static func isNeeded(hasCredentials: Bool) -> Bool {
        guard AuthMode.currentIsUnset else { return false }
        guard !UserDefaults.standard.bool(forKey: "onboardingShown") else { return false }
        // Existing installs (keys in the Keychain, LastPass entry configured,
        // or env vars) skip the welcome — they're already set up.
        return !hasCredentials && LastPassConfig.load() == nil
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView { [weak self] in
                self?.finish()
            })
            let window = NSWindow(contentViewController: host)
            window.title = "Welcome"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The single completion funnel for every exit (choice made, sample-data
    /// link, red close button). Teardown is deferred one runloop turn: this
    /// can be reached from inside AppKit's close machinery or a sheet's
    /// completion closure, and ordering out / releasing the window
    /// synchronously there is a use-after-free waiting to happen.
    private func finish() {
        guard !finished else { return }
        finished = true
        UserDefaults.standard.set(true, forKey: "onboardingShown")
        DispatchQueue.main.async { [self] in
            window?.orderOut(nil)
            onFinished()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window counts as "explore first" — sample data, no nag.
        if AuthMode.currentIsUnset { AuthMode.set(.sample) }
        finish()
    }
}

/// The welcome content: one screen, three ways in, LastPass first.
private struct OnboardingView: View {
    let onFinished: () -> Void

    @State private var showLastPassSetup = false
    @State private var showKeyEntry = false

    var body: some View {
        VStack(spacing: 0) {
            hero
                .padding(.top, 28)
                .padding(.bottom, 20)

            VStack(spacing: 10) {
                lastPassCard
                apiKeysCard
            }
            .padding(.horizontal, 24)

            Button("Explore with sample data first") {
                AuthMode.set(.sample)
                onFinished()
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(.top, 16)

            Text("You can switch sources anytime in Settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
                .padding(.bottom, 20)
        }
        .frame(width: 440)
        .fixedSize()
        .sheet(isPresented: $showLastPassSetup) {
            LastPassSetupView { config in
                config.save()
                AuthMode.set(.lastPass)
                onFinished()
            }
        }
        .sheet(isPresented: $showKeyEntry) {
            APIKeyEntryView {
                onFinished()
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 72, height: 72)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.panel)
                )
            Text("Welcome to Datadog Assistant")
                .font(.title2.bold())
            Text("Your monitors, incidents, and deploys — one click away in the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var lastPassCard: some View {
        ChoiceCard(
            icon: "person.3.fill",
            title: "Use your team's LastPass vault",
            badge: "Recommended",
            detail: "One shared secure note holds the keys for everyone. "
                + "Guided setup installs the lpass CLI and signs you in — no terminal, "
                + "no keys stored on this Mac.",
            buttonTitle: "Set Up LastPass…",
            prominent: true
        ) {
            showLastPassSetup = true
        }
    }

    private var apiKeysCard: some View {
        ChoiceCard(
            icon: "key.fill",
            title: "Paste an access token or API keys",
            badge: nil,
            detail: "Use a personal access token (ddpat_…) — Datadog's "
                + "recommended credential for personal tools — or the classic "
                + "API + application key pair. Validated, then stored in the "
                + "macOS Keychain, never written to disk.",
            buttonTitle: "Enter Credentials…",
            prominent: false
        ) {
            showKeyEntry = true
        }
    }
}

/// A grouped-inset choice row: icon, copy, and a single action button.
private struct ChoiceCard: View {
    let icon: String
    let title: String
    let badge: String?
    let detail: String
    let buttonTitle: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                Text(title)
                    .font(.headline)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(.tint)
                }
                Spacer()
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if prominent {
                    Button(buttonTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(buttonTitle, action: action)
                        .controlSize(.large)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.panel)
        )
    }
}

/// Minimal credential entry for the onboarding path: paste an access token
/// (Datadog's recommended credential for personal tools since 2026) or the
/// classic key pair, validate against Datadog, save to the Keychain. The
/// full editor stays in Settings.
private struct APIKeyEntryView: View {
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var useAccessToken = true
    @State private var accessToken = ""
    @State private var apiKey = ""
    @State private var appKey = ""
    @State private var site = Credentials.currentSite()
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Datadog")
                .font(.title3.bold())

            Picker("", selection: $useAccessToken) {
                Text("Access token").tag(true)
                Text("API + App keys").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(useAccessToken
                 ? "Create one under Personal Settings → Access Tokens with scopes: "
                   + "monitors_read, monitors_downtime, events_read, incident_read, "
                   + "dashboards_read, timeseries_query. One credential, no key pair."
                 : "Create keys in Datadog under Organization Settings → API Keys "
                   + "and Application Keys. The app key needs monitors_read "
                   + "(plus monitors_write to mute from the app).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                if useAccessToken {
                    SecureField("Access token (ddpat_… or ddsat_…)", text: $accessToken)
                } else {
                    SecureField("API key", text: $apiKey)
                    SecureField("Application key", text: $appKey)
                }
                Picker("Datadog site", selection: $site) {
                    ForEach(Credentials.knownSites, id: \.self) { Text($0) }
                }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || (useAccessToken
                        ? accessToken.trimmingCharacters(in: .whitespaces).isEmpty
                        : apiKey.isEmpty || appKey.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func connect() {
        busy = true; error = nil
        let token = accessToken.trimmingCharacters(in: .whitespaces)
        let api = apiKey, app = appKey, site = self.site, useToken = useAccessToken
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
                    dismiss()
                    onSaved()
                } catch {
                    self.error = "Couldn't write to the Keychain: \(error)"
                }
            }
        }
    }
}
