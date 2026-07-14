import AppKit
import Foundation

/// Opens URLs in the user's chosen browser (Settings → Source), not just the
/// system default — port of the Python app's `browser` config. The point:
/// your Datadog/Jira session usually lives in your work browser, while the
/// system default may be Safari where every link lands on a login page.
enum LinkOpener {
    private static let browserKey = "linkBrowser"

    /// Display name of the chosen browser; "" = system default.
    static func currentBrowser() -> String {
        UserDefaults.standard.string(forKey: browserKey) ?? ""
    }

    static func setBrowser(_ name: String) {
        UserDefaults.standard.set(name, forKey: browserKey)
    }

    /// Browsers actually present on this Mac, for the Settings dropdown.
    static func installedBrowsers() -> [String] {
        let known = ["Safari", "Google Chrome", "Firefox", "Arc",
                     "Microsoft Edge", "Brave Browser", "Vivaldi", "Orion"]
        return known.filter { name in
            ["/Applications/\(name).app", "/System/Applications/\(name).app",
             "\(NSHomeDirectory())/Applications/\(name).app"]
                .contains { FileManager.default.fileExists(atPath: $0) }
        }
    }

    static func open(_ url: URL) {
        let browser = currentBrowser()
        guard !browser.isEmpty else {
            NSWorkspace.shared.open(url)
            return
        }
        // `open -a <name> <url>` matches the Python app and resolves the app
        // by display name; fall back to the default browser if it fails.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", browser, url.absoluteString]
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(url)
        }
    }
}
