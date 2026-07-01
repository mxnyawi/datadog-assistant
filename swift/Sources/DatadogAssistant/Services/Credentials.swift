import Foundation
import Security

/// Datadog API credentials. Stored in the macOS Keychain under the same
/// service names the Python app uses, so an existing install carries over.
struct Credentials: Equatable {
    var apiKey: String
    var appKey: String
    var site: String   // e.g. "datadoghq.com", "datadoghq.eu", "us3.datadoghq.com"

    static let knownSites = [
        "datadoghq.com", "datadoghq.eu", "us3.datadoghq.com",
        "us5.datadoghq.com", "ap1.datadoghq.com", "ddog-gov.com",
    ]

    var apiBaseURL: URL { URL(string: "https://api.\(site)")! }
    var appBaseURL: URL { URL(string: "https://app.\(site)")! }

    // Same service names install.sh writes, so existing users need no re-entry.
    private static let apiService = "datadog-assistant-api-key"
    private static let appService = "datadog-assistant-app-key"
    private static let siteDefaultsKey = "datadogSite"

    /// Env vars win (dev loop), then Keychain.
    static func load() -> Credentials? {
        let env = ProcessInfo.processInfo.environment
        if let api = env["DD_API_KEY"], let app = env["DD_APP_KEY"], !api.isEmpty, !app.isEmpty {
            return Credentials(apiKey: api, appKey: app, site: env["DD_SITE"] ?? "datadoghq.com")
        }
        guard let api = Keychain.read(service: apiService),
              let app = Keychain.read(service: appService) else { return nil }
        let site = UserDefaults.standard.string(forKey: siteDefaultsKey) ?? "datadoghq.com"
        return Credentials(apiKey: api, appKey: app, site: site)
    }

    func save() throws {
        try Keychain.write(service: Self.apiService, value: apiKey)
        try Keychain.write(service: Self.appService, value: appKey)
        UserDefaults.standard.set(site, forKey: Self.siteDefaultsKey)
    }

    static func clear() {
        Keychain.delete(service: apiService)
        Keychain.delete(service: appService)
        UserDefaults.standard.removeObject(forKey: siteDefaultsKey)
    }
}

enum Keychain {
    enum Error: Swift.Error { case status(OSStatus) }

    static func read(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func write(service: String, value: String) throws {
        delete(service: service)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.status(status) }
    }

    static func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
