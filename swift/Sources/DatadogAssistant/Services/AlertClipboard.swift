import AppKit

/// Builds a paste-ready summary of an alert for an incident channel or ticket
/// — name, state, value vs threshold, firing duration, hosts, the suspect
/// deploy, and the deep link — in Markdown (GitHub/Jira) or Slack mrkdwn.
/// Complements the one-tap Jira action: sometimes you just want to paste the
/// context into a thread.
enum AlertClipboard {
    /// Copy a formatted summary to the general pasteboard.
    static func copy(monitor: Monitor, suspect: DeployEvent?, format: UIPreferences.CopyFormat) {
        let text = summary(monitor: monitor, suspect: suspect, format: format)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func summary(monitor: Monitor, suspect: DeployEvent?,
                        format: UIPreferences.CopyFormat) -> String {
        let bold = { (s: String) in format == .slack ? "*\(s)*" : "**\(s)**" }
        let bullet = "• "

        var lines: [String] = []
        let priority = monitor.priority.rawValue <= 2 ? "\(monitor.priority.label) " : ""
        lines.append("\(bold("\(priority)\(monitor.name)")) — \(monitor.state.label)")

        if let value = monitor.value {
            if let threshold = monitor.threshold {
                lines.append("\(bullet)Value: \(number(value)) / \(number(threshold)) threshold")
            } else {
                lines.append("\(bullet)Value: \(number(value))")
            }
        }
        if let duration = monitor.firingDuration {
            lines.append("\(bullet)Firing for: \(duration)")
        }
        if !monitor.triggeredHosts.isEmpty {
            lines.append("\(bullet)Hosts: \(monitor.triggeredHosts.prefix(6).joined(separator: ", "))")
        }
        if let delta = monitor.delta, delta >= 1.5 {
            lines.append("\(bullet)×\(String(format: delta >= 10 ? "%.0f" : "%.1f", delta)) vs last week")
        }
        if let suspect {
            let when = suspectLead(monitor: monitor, deploy: suspect)
            let base = "\(bullet)Suspect change: \(suspect.title)\(when)"
            lines.append(link(base, url: suspect.url, format: format))
        }
        if let url = monitor.url {
            lines.append("\(bullet)Datadog: \(url.absoluteString)")
        }
        return lines.joined(separator: "\n")
    }

    /// " (landed 8m before)" when we can place the deploy before the alert.
    private static func suspectLead(monitor: Monitor, deploy: DeployEvent) -> String {
        guard let since = monitor.firingSince else { return "" }
        let mins = Int(since.timeIntervalSince(deploy.occurredAt) / 60)
        guard mins >= 1 else { return "" }
        return " (landed \(mins)m before)"
    }

    /// Slack renders `<url|text>`; Markdown leaves the URL inline on its own
    /// (the callers already put the human text in `base`), so we just append
    /// the raw URL for Markdown and skip it when there's none.
    private static func link(_ base: String, url: URL?, format: UIPreferences.CopyFormat) -> String {
        guard let url else { return base }
        if format == .slack {
            return "\(base) <\(url.absoluteString)>"
        }
        return "\(base) — \(url.absoluteString)"
    }

    private static func number(_ v: Double) -> String {
        if abs(v) >= 1000 { return String(format: "%.1fk", v / 1000) }
        if abs(v) < 10 { return String(format: "%.2f", v) }
        return String(format: "%.0f", v)
    }
}
