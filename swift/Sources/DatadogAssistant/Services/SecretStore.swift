import Foundation
import CryptoKit

/// On-device secret storage that never prompts for the login password.
///
/// The macOS login Keychain prompts an ad-hoc-signed app for the account
/// password on nearly every access: the item's access-control list is bound to
/// the app's code-signing identity, and an unsigned/ad-hoc app gets a fresh,
/// unstable identity (code-directory hash) on each rebuild — so the Keychain
/// sees a "different app" every launch/update and asks the user to authorize
/// it. Until the app is Developer-ID signed (which gives a stable identity and
/// unlocks the promptless Data-Protection Keychain), simply opening the menu
/// bar is a password gauntlet. So the app's own secrets (Datadog token/keys,
/// Jira token, GitHub token) live here instead — no Keychain, no prompt.
///
/// **How it's protected.** Secrets are AES-GCM encrypted (CryptoKit) in a file
/// that's readable only by this user (`0600`), inside a `0700` directory,
/// excluded from iCloud/Time Machine backups. The encryption key is, when the
/// hardware allows it, wrapped by this Mac's **Secure Enclave**: the key
/// material never leaves the Enclave and can't be decrypted on any other
/// machine, so a stolen disk or a leaked backup is useless — and none of this
/// touches the Keychain, so there's no prompt. On Macs without a usable
/// Enclave it falls back to a random key in a sibling `0600` file (still
/// encrypted at rest, but the key is co-located — obfuscation, not true
/// confidentiality, against a process running as you).
///
/// **Honest threat model.** This defeats casual disk inspection, backup/cloud
/// leakage, other local users, and (with the Enclave) physical theft. It does
/// **not** stop another process running as you or malware in your account —
/// the app must decrypt unattended, so anything with your privileges can too.
/// That's an acceptable trade for a scoped, revocable, expiring Datadog token:
/// keep FileVault on, and rotate the token if a machine is compromised.
enum SecretStore {
    private static let lock = NSLock()
    private static var cache: [String: String]?

    // MARK: API (mirrors the old Keychain enum so call sites barely change)

    static func read(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let value = load()[key]
        return (value?.isEmpty == false) ? value : nil
    }

    static func write(_ key: String, _ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        var dict = load()
        dict[key] = value
        try persist(dict)
    }

    static func delete(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = load()
        guard dict[key] != nil else { return }
        dict.removeValue(forKey: key)
        try? persist(dict)
    }

    // MARK: Storage

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DatadogAssistant", isDirectory: true)
    }
    private static var secretsURL: URL { directory.appendingPathComponent("secrets.enc") }
    private static var randomKeyURL: URL { directory.appendingPathComponent("secrets.key") }
    private static var enclaveKeyURL: URL { directory.appendingPathComponent("secrets.se") }
    private static var enclavePubURL: URL { directory.appendingPathComponent("secrets.sepub") }

    /// Decrypt the secrets file into memory (cached until the next write).
    private static func load() -> [String: String] {
        if let cache { return cache }
        guard let key = try? symmetricKey(),
              let blob = try? Data(contentsOf: secretsURL), !blob.isEmpty,
              let sealed = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(sealed, using: key),
              let dict = try? JSONDecoder().decode([String: String].self, from: plain)
        else {
            cache = [:]
            return [:]
        }
        cache = dict
        return dict
    }

    private static func persist(_ dict: [String: String]) throws {
        try ensureDirectory()
        cache = dict
        // An empty store means "no secrets" — remove the file rather than
        // leave an encrypted empty blob behind.
        guard !dict.isEmpty else {
            try? FileManager.default.removeItem(at: secretsURL)
            return
        }
        let key = try symmetricKey()
        let plain = try JSONEncoder().encode(dict)
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else { throw StoreError.seal }
        try combined.write(to: secretsURL, options: .atomic)
        setOwnerOnly(secretsURL)
        excludeFromBackup(secretsURL)
    }

    // MARK: Key management — Secure Enclave preferred, random-key fallback

    /// The AES key used to seal the secrets file. Established on first use and
    /// reused thereafter. Prefers a Secure-Enclave-wrapped key (device-bound,
    /// non-exportable); falls back to a random key on a `0600` file when the
    /// Enclave isn't usable (older/VM hardware, or ad-hoc signing that blocks
    /// key creation).
    private static func symmetricKey() throws -> SymmetricKey {
        try ensureDirectory()
        if let key = try? enclaveSymmetricKey() { return key }
        return try randomSymmetricKey()
    }

    /// Derive a stable symmetric key from a Secure-Enclave private key via ECDH
    /// against a persisted counterpart public key, then HKDF. The Enclave blob
    /// only decrypts on this Mac's Enclave, so the secrets file can't be read
    /// off-device even if both files are copied. Throws if the Enclave is
    /// unavailable or key material can't be created/restored.
    private static func enclaveSymmetricKey() throws -> SymmetricKey {
        guard SecureEnclave.isAvailable else { throw StoreError.noEnclave }

        let privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey
        let counterpart: P256.KeyAgreement.PublicKey

        if let keyBlob = try? Data(contentsOf: enclaveKeyURL),
           let pubBlob = try? Data(contentsOf: enclavePubURL) {
            privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: keyBlob)
            counterpart = try P256.KeyAgreement.PublicKey(rawRepresentation: pubBlob)
        } else {
            // First use on this device: mint the Enclave key + a throwaway
            // software key whose *public* half is the fixed ECDH counterpart.
            privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            counterpart = P256.KeyAgreement.PrivateKey().publicKey
            try privateKey.dataRepresentation.write(to: enclaveKeyURL, options: .atomic)
            try counterpart.rawRepresentation.write(to: enclavePubURL, options: .atomic)
            setOwnerOnly(enclaveKeyURL); excludeFromBackup(enclaveKeyURL)
            setOwnerOnly(enclavePubURL); excludeFromBackup(enclavePubURL)
        }

        let shared = try privateKey.sharedSecretFromKeyAgreement(with: counterpart)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("DatadogAssistant.SecretStore".utf8),
            sharedInfo: Data(),
            outputByteCount: 32)
    }

    /// Fallback: a random 256-bit key persisted `0600`, created on first use.
    private static func randomSymmetricKey() throws -> SymmetricKey {
        if let raw = try? Data(contentsOf: randomKeyURL), raw.count == 32 {
            return SymmetricKey(data: raw)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try raw.write(to: randomKeyURL, options: .atomic)
        setOwnerOnly(randomKeyURL)
        excludeFromBackup(randomKeyURL)
        return key
    }

    // MARK: File helpers

    private static func ensureDirectory() throws {
        let dir = directory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }

    private static func setOwnerOnly(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private enum StoreError: Error { case seal, noEnclave }
}
