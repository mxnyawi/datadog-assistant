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
/// **Key scheme is pinned.** Whichever scheme seals the file first (Enclave or
/// random) is the one used forever after, identified by which key file exists.
/// The store never silently switches schemes or mints a new key over an
/// existing store — that was the source of a data-loss class of bug. If the
/// key genuinely can't be reproduced (e.g. the file was restored onto a
/// *different* Mac whose Enclave can't unwrap it — the intended security
/// property), the unreadable ciphertext is dropped and the store starts fresh
/// on the next save; nothing *recoverable* is ever destroyed, because
/// undecryptable data is already unrecoverable on this machine.
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

    // MARK: Storage locations

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DatadogAssistant", isDirectory: true)
    }
    private static var secretsURL: URL { directory.appendingPathComponent("secrets.enc") }
    private static var randomKeyURL: URL { directory.appendingPathComponent("secrets.key") }
    private static var enclaveKeyURL: URL { directory.appendingPathComponent("secrets.se") }
    private static var enclavePubURL: URL { directory.appendingPathComponent("secrets.sepub") }

    // MARK: Load / persist

    /// Decrypt the secrets file into memory (cached until the next write). An
    /// absent *or* unreadable file yields an empty store; an unreadable file is
    /// also dropped, so the next save starts clean rather than failing forever.
    private static func load() -> [String: String] {
        if let cache { return cache }
        guard let blob = try? Data(contentsOf: secretsURL), !blob.isEmpty else {
            cache = [:]
            return [:]
        }
        guard let key = try? symmetricKey(),
              let sealed = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(sealed, using: key),
              let dict = try? JSONDecoder().decode([String: String].self, from: plain)
        else {
            // The ciphertext exists but can't be decrypted with this machine's
            // key (foreign Enclave after a cross-Mac restore, or corruption).
            // Its plaintext is unrecoverable here, so drop it — this loses no
            // *recoverable* secret and lets the user re-save.
            try? FileManager.default.removeItem(at: secretsURL)
            cache = [:]
            return [:]
        }
        cache = dict
        return dict
    }

    private static func persist(_ dict: [String: String]) throws {
        try ensureDirectory()
        // An empty store means "no secrets" — remove the file rather than
        // leave an encrypted empty blob behind.
        guard !dict.isEmpty else {
            try? FileManager.default.removeItem(at: secretsURL)
            cache = [:]
            return
        }
        let key = try symmetricKey()
        let plain = try JSONEncoder().encode(dict)
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else { throw StoreError.seal }
        try combined.write(to: secretsURL, options: .atomic)   // may throw → cache stays in sync with disk
        cache = dict
        setOwnerOnly(secretsURL)
        excludeFromBackup(secretsURL)
    }

    // MARK: Key management — one pinned scheme, self-healing

    /// The AES key that seals the secrets file. Deterministic and idempotent:
    /// it returns the key of whichever scheme is already established (identified
    /// by the key file on disk), restoring it. If an established key can't be
    /// reproduced, its stale material is wiped and a fresh key is established —
    /// but a fresh key is *never* minted while a usable one exists, so the
    /// Enclave and random paths can never disagree.
    private static func symmetricKey() throws -> SymmetricKey {
        try ensureDirectory()
        let fm = FileManager.default

        // Established: random scheme (the key file is the literal key bytes).
        if let raw = try? Data(contentsOf: randomKeyURL), raw.count == 32 {
            return SymmetricKey(data: raw)
        }
        // Established: Enclave scheme (secrets.se is the wrapped-key marker).
        if fm.fileExists(atPath: enclaveKeyURL.path) {
            if let key = try? restoreEnclaveKey() { return key }
            // Marker present but unrestorable (foreign Enclave / lost) — wipe
            // and re-establish below.
            try? fm.removeItem(at: enclaveKeyURL)
            try? fm.removeItem(at: enclavePubURL)
        }
        // First use (or post-wipe): pick the strongest scheme that works and
        // pin it by creating exactly one key file.
        if let key = try? createEnclaveKey() { return key }
        return try createRandomKey()
    }

    /// Restore the symmetric key from an existing Secure-Enclave key pair.
    private static func restoreEnclaveKey() throws -> SymmetricKey {
        guard SecureEnclave.isAvailable else { throw StoreError.noEnclave }
        let keyBlob = try Data(contentsOf: enclaveKeyURL)
        let pubBlob = try Data(contentsOf: enclavePubURL)
        let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: keyBlob)
        let counterpart = try P256.KeyAgreement.PublicKey(rawRepresentation: pubBlob)
        return try derive(privateKey: privateKey, counterpart: counterpart)
    }

    /// Mint and persist a new Secure-Enclave key + counterpart public key. The
    /// marker file (`secrets.se`) is written **last**, so a partial failure
    /// leaves no marker and the next launch cleanly retries first-use.
    private static func createEnclaveKey() throws -> SymmetricKey {
        guard SecureEnclave.isAvailable else { throw StoreError.noEnclave }
        let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        let counterpart = P256.KeyAgreement.PrivateKey().publicKey
        let key = try derive(privateKey: privateKey, counterpart: counterpart)
        try counterpart.rawRepresentation.write(to: enclavePubURL, options: .atomic)
        setOwnerOnly(enclavePubURL); excludeFromBackup(enclavePubURL)
        try privateKey.dataRepresentation.write(to: enclaveKeyURL, options: .atomic)
        setOwnerOnly(enclaveKeyURL); excludeFromBackup(enclaveKeyURL)
        return key
    }

    private static func derive(privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey,
                               counterpart: P256.KeyAgreement.PublicKey) throws -> SymmetricKey {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: counterpart)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("DatadogAssistant.SecretStore".utf8),
            sharedInfo: Data(),
            outputByteCount: 32)
    }

    /// Fallback: a random 256-bit key persisted `0600`.
    private static func createRandomKey() throws -> SymmetricKey {
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
