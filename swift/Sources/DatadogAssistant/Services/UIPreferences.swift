import Foundation
import Combine

/// Cross-cutting UI/UX preferences that several unrelated surfaces read at
/// once — the menu-bar badge, the row list, the panel chrome. Unlike the
/// per-concern config structs (FilterConfig, DLQConfig…), these need to be
/// *observable* so a change in Settings updates the live panel and the status
/// item without a poll. A single shared ObservableObject keeps that in one
/// place; each stored property persists itself to UserDefaults on write.
///
/// It's a singleton *and* handed to SwiftUI as an observed object — AppKit
/// controllers (MenuBarController) reach `.shared` directly, panel views hold
/// `@ObservedObject private var prefs = UIPreferences.shared`. Same instance
/// either way, so a toggle in one place is seen everywhere.
///
/// Deliberately not `@MainActor`: it's only ever touched from the main thread
/// (SwiftUI views + the menu-bar controller), and staying actor-agnostic lets
/// a View use `= UIPreferences.shared` as a stored-property default without an
/// isolation dance.
final class UIPreferences: ObservableObject {
    static let shared = UIPreferences()

    /// Row spacing: the default look, or a tighter single-glance mode for
    /// people watching dozens of monitors on a laptop screen.
    enum Density: String, CaseIterable {
        case comfortable, compact
        var label: String { self == .comfortable ? "Comfortable" : "Compact" }
    }

    /// What the menu-bar count means. One person's signal is another's noise —
    /// an SRE may only care about P1/P2, everyone else wants the full count.
    enum BadgeMode: String, CaseIterable {
        case allAlerting, highPriority
        var label: String {
            switch self {
            case .allAlerting: return "All alerting"
            case .highPriority: return "P1 / P2 only"
            }
        }

        /// The count this mode shows for a snapshot.
        func count(in snapshot: Snapshot) -> Int {
            switch self {
            case .allAlerting: return snapshot.alerting.count
            case .highPriority: return snapshot.alerting.filter { $0.priority <= .p2 }.count
            }
        }
    }

    /// Clipboard flavor for "Copy alert" — GitHub/Jira Markdown vs Slack mrkdwn.
    enum CopyFormat: String, CaseIterable {
        case markdown, slack
        var label: String { self == .markdown ? "Markdown" : "Slack" }
    }

    /// Starred monitor IDs — pinned to the top of the Monitors tab regardless
    /// of state, so the handful you actually own stay in view.
    @Published var favorites: Set<Int> {
        didSet {
            UserDefaults.standard.set(Array(favorites), forKey: Self.favoritesKey)
        }
    }
    @Published var density: Density {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: Self.densityKey) }
    }
    @Published var badgeMode: BadgeMode {
        didSet { UserDefaults.standard.set(badgeMode.rawValue, forKey: Self.badgeModeKey) }
    }
    /// Briefly pulse the status item when a *new* alert appears (Reduce-Motion
    /// aware at the call site).
    @Published var pulseOnAlert: Bool {
        didSet { UserDefaults.standard.set(pulseOnAlert, forKey: Self.pulseKey) }
    }
    /// Keep the panel up when you click elsewhere — an on-call "park it on the
    /// second display" mode. Off by default (the panel behaves like a menu).
    @Published var pinned: Bool {
        didSet { UserDefaults.standard.set(pinned, forKey: Self.pinnedKey) }
    }
    @Published var copyFormat: CopyFormat {
        didSet { UserDefaults.standard.set(copyFormat.rawValue, forKey: Self.copyFormatKey) }
    }

    private static let favoritesKey = "uiFavorites"
    private static let densityKey = "uiDensity"
    private static let badgeModeKey = "uiBadgeMode"
    private static let pulseKey = "uiPulseOnAlert"
    private static let pinnedKey = "uiPinnedPanel"
    private static let copyFormatKey = "uiCopyFormat"

    private init() {
        let defaults = UserDefaults.standard
        favorites = Set(defaults.array(forKey: Self.favoritesKey) as? [Int] ?? [])
        density = (defaults.string(forKey: Self.densityKey)).flatMap(Density.init) ?? .comfortable
        badgeMode = (defaults.string(forKey: Self.badgeModeKey)).flatMap(BadgeMode.init) ?? .allAlerting
        // Default true (object(forKey:) nil on first launch): the pulse is the
        // kind of small delight that's welcome until someone turns it off.
        pulseOnAlert = defaults.object(forKey: Self.pulseKey) as? Bool ?? true
        pinned = defaults.bool(forKey: Self.pinnedKey)
        copyFormat = (defaults.string(forKey: Self.copyFormatKey)).flatMap(CopyFormat.init) ?? .markdown
    }

    func isFavorite(_ monitorID: Int) -> Bool { favorites.contains(monitorID) }

    func toggleFavorite(_ monitorID: Int) {
        if favorites.contains(monitorID) {
            favorites.remove(monitorID)
        } else {
            favorites.insert(monitorID)
        }
    }
}
