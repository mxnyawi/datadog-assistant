import SwiftUI
import AppKit

/// Every Datadog authorization scope this app uses, and the feature it
/// powers. Access tokens are scoped at creation — Datadog shows a scope
/// search field and users have to know what to tick — so token setup renders
/// this list verbatim instead of hoping people memorize six identifiers.
struct DatadogScope: Identifiable {
    /// The exact scope identifier as it appears in Datadog's scope picker.
    let name: String
    /// What breaks in this app without it, in user terms.
    let purpose: String
    /// Only monitors_read is load-bearing; everything else degrades a
    /// single feature.
    let required: Bool

    var id: String { name }

    static let all: [DatadogScope] = [
        DatadogScope(name: "monitors_read",
                     purpose: "List monitors and their alert states — the panel itself.",
                     required: true),
        DatadogScope(name: "monitors_downtime",
                     purpose: "Mute / unmute monitors and the Snooze tab.",
                     required: false),
        DatadogScope(name: "events_read",
                     purpose: "Deploys on the Changes tab and “landed before this alert” suspects.",
                     required: false),
        DatadogScope(name: "incident_read",
                     purpose: "The Active Incidents section.",
                     required: false),
        DatadogScope(name: "dashboards_read",
                     purpose: "“My dashboards” quick links in Tools.",
                     required: false),
        DatadogScope(name: "timeseries_query",
                     purpose: "Sparklines and live value-vs-threshold on alerts.",
                     required: false),
    ]

    /// Space-separated list for pasting into Datadog's scope search field.
    static var copyList: String { all.map(\.name).joined(separator: " ") }
}

/// The scope checklist rendered in token setup (onboarding sheet and
/// Settings): one row per scope with what it powers, a copy button so the
/// list can be pasted straight into Datadog's scope picker, and a shortcut
/// to the Access Tokens page for the configured org.
struct ScopeChecklistView: View {
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Scopes to select when creating the token")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyScopes()
                } label: {
                    Label(copied ? "Copied" : "Copy scopes",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy all six scope names — paste into Datadog's scope search")
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(DatadogScope.all) { scope in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(scope.name)
                            .font(.system(size: 11, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                            .layoutPriority(1)
                        if scope.required {
                            Text("required")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.orange)
                        }
                        Text(scope.purpose)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button {
                LinkOpener.open(Credentials.currentAppBaseURL()
                    .appendingPathComponent("/personal-settings/access-tokens"))
            } label: {
                Label("Create a token in Datadog", systemImage: "arrow.up.forward.square")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .help("Personal Settings → Access Tokens (service accounts: Organization Settings → Service Accounts)")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
    }

    private func copyScopes() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DatadogScope.copyList, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
