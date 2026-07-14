import Darwin
import Foundation

/// Result of a guided `lpass login` attempt.
enum LastPassLoginResult: Equatable {
    case ok
    case mfaRequired           // master password accepted, an authenticator code is needed
    case failed(String)        // human-readable reason (secrets redacted)
}

/// A LastPass entry: its display name and unique `lpass` ID. Look-ups use the
/// ID when present (`id` is non-empty), which avoids name-matching problems
/// with spaces or duplicate names.
struct LastPassEntry: Hashable {
    let name: String
    let id: String
    /// What to pass to `lpass show` — the ID when known, else the name.
    var ref: String { id.isEmpty ? name : id }
}

/// Guided, in-app setup for the LastPass CLI — the macOS-native counterpart to
/// the Python onboarding app's LastPass flow. It installs the `lpass` CLI via
/// Homebrew, drives `lpass login` (handling the master-password and
/// authenticator prompts through a pseudo-terminal, exactly as the Python
/// installer does), and lists/validates the shared vault entry. Every call
/// here blocks on a subprocess, so run them off the main thread.
enum LastPassSetup {

    // MARK: Install

    /// Ensure the `lpass` CLI exists, installing it via `brew install
    /// lastpass-cli` if it's missing. Streams brew output through `log`.
    static func ensureInstalled(log: @escaping (String) -> Void) -> (installed: Bool, error: String?) {
        if LastPass.isInstalled { return (true, nil) }
        guard let brew = locateBrew() else {
            return (false, "Homebrew isn't installed, so the LastPass CLI can't be "
                    + "installed automatically. Install Homebrew from https://brew.sh, "
                    + "then try again.")
        }
        log("$ brew install lastpass-cli")
        let result = capture(URL(fileURLWithPath: brew), ["install", "lastpass-cli"], timeout: 900)
        let output = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty { log(output) }
        if result?.status != 0 {
            return (false, output.isEmpty ? "brew install failed" : String(output.suffix(300)))
        }
        return (LastPass.isInstalled,
                LastPass.isInstalled ? nil : "Install finished but lpass still isn't on PATH.")
    }

    private static func locateBrew() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: Login

    // Prompt fragments lpass prints; used to know which input it's waiting for.
    private static let pwPrompts = ["master password", "password"]
    private static let otpPrompts = ["code", "factor", "passcode", "otp",
                                     "authenticat", "google", "yubikey", "out-of-band"]

    /// Log in to LastPass by driving `lpass login --trust <email>`. Returns
    /// `.ok` on success, `.mfaRequired` when the password was accepted but an
    /// authenticator code is needed (re-call with `otp`), or `.failed`. `lpass
    /// status` is the source of truth; the transcript (secrets redacted) is
    /// streamed through `log` for diagnosis.
    static func login(email: String, password: String, otp: String,
                      log: @escaping (String) -> Void) -> LastPassLoginResult {
        guard let lpass = LastPass.locate() else {
            return .failed("LastPass CLI not found. Install it first.")
        }
        guard !email.isEmpty, !password.isEmpty else {
            return .failed("Email and master password are required.")
        }
        log("$ lpass login --trust \(email)")

        let (transcript, sawOTP) = drive(lpass: lpass, email: email, password: password, otp: otp)

        var detail = transcript
        for secret in [password, otp] where !secret.isEmpty {
            detail = detail.replacingOccurrences(of: secret, with: "•••")
        }
        detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in detail.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { log("lpass: \(trimmed)") }
        }

        if LastPass.statusLoggedIn() { return .ok }
        let low = detail.lowercased()
        if sawOTP && otp.isEmpty { return .mfaRequired }
        if sawOTP && !otp.isEmpty {
            return .failed("LastPass rejected the authenticator code (or it expired — "
                           + "try the current one).")
        }
        if low.contains("password"),
           ["incorrect", "could not", "failed", "invalid"].contains(where: { low.contains($0) }) {
            return .failed("LastPass rejected the master password.")
        }
        if detail.isEmpty { return .failed("LastPass didn't respond (no prompt seen).") }
        return .failed(String(detail.suffix(200)))
    }

    /// Run `lpass login` under a pseudo-terminal, feeding the master password
    /// and (if asked) the authenticator code. lpass reads the password from
    /// the controlling terminal, not plain stdin, so a pty is required for MFA
    /// accounts; falls back to a plain pipe if a pty can't be allocated.
    /// Bounded by a hard deadline and an idle timeout so it can't hang the UI.
    private static func drive(lpass: String, email: String, password: String, otp: String)
        -> (transcript: String, sawOTP: Bool) {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let namePtr = ptsname(master) else {
            if master >= 0 { close(master) }
            return drivePipe(lpass: lpass, email: email, password: password, otp: otp)
        }
        let slave = open(String(cString: namePtr), O_RDWR)
        guard slave >= 0 else {
            close(master)
            return drivePipe(lpass: lpass, email: email, password: password, otp: otp)
        }

        var env = ProcessInfo.processInfo.environment
        env["LPASS_DISABLE_PINENTRY"] = "1"
        env["LPASS_AGENT_TIMEOUT"] = "0"   // hold the session for the menu-bar app

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lpass)
        process.arguments = ["login", "--trust", email]
        process.environment = env
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        do {
            try process.run()
        } catch {
            close(master); close(slave)
            return ("Couldn't start lpass: \(error.localizedDescription)", false)
        }
        close(slave)   // the child holds its own copy

        func writeMaster(_ text: String) {
            let bytes = Array(text.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, bytes.count) }
        }

        var transcript = "", buffer = ""
        var sentPassword = false, sentOTP = false, sawOTP = false
        let start = Date()
        var lastActivity = start

        while Date().timeIntervalSince(start) < 45 {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 500)
            if ready <= 0 {
                if !process.isRunning { break }
                if Date().timeIntervalSince(lastActivity) > 20 {
                    transcript += "\n[timed out waiting for lpass]"
                    break
                }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(master, &chunk, 4096)
            if count <= 0 { break }
            lastActivity = Date()
            let text = String(decoding: chunk[0..<count], as: UTF8.self)
            transcript += text
            buffer += text
            let low = buffer.lowercased()
            if !sentPassword, pwPrompts.contains(where: { low.contains($0) }) {
                writeMaster(password + "\n"); sentPassword = true; buffer = ""; continue
            }
            if sentPassword, !sentOTP, otpPrompts.contains(where: { low.contains($0) }) {
                sawOTP = true
                if !otp.isEmpty {
                    writeMaster(otp + "\n"); sentOTP = true; buffer = ""; continue
                }
                break   // need a code we don't have → stop and report mfaRequired
            }
        }

        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        close(master)
        return (transcript, sawOTP)
    }

    /// Fallback when no pty is available: feed the password (+ code) via stdin.
    private static func drivePipe(lpass: String, email: String, password: String, otp: String)
        -> (transcript: String, sawOTP: Bool) {
        let stdin = otp.isEmpty ? password + "\n" : password + "\n" + otp + "\n"
        let result = capture(URL(fileURLWithPath: lpass), ["login", "--trust", email],
                             timeout: 45, stdin: stdin,
                             extraEnv: ["LPASS_DISABLE_PINENTRY": "1", "LPASS_AGENT_TIMEOUT": "0"])
        let output = result?.output ?? ""
        let low = output.lowercased()
        return (output, otpPrompts.contains(where: { low.contains($0) }))
    }

    // MARK: Logout / entries / validate

    static func logout() {
        guard let lpass = LastPass.locate() else { return }
        _ = capture(URL(fileURLWithPath: lpass), ["logout", "--force"], timeout: 20)
        LastPass.statusLoggedIn()
    }

    /// `lpass ls` → entries with their unique IDs (best-effort, empty on
    /// failure). Lines look like "Group/Name [id: 1234]". The ID is what we
    /// pass back to `lpass show`, since it's immune to spaces in group/note
    /// names and to duplicate names that would otherwise be ambiguous.
    static func listEntries() -> [LastPassEntry] {
        guard let lpass = LastPass.locate(),
              let result = capture(URL(fileURLWithPath: lpass), ["ls"], timeout: 45),
              result.status == 0 else { return [] }
        var seen = Set<String>(), entries: [LastPassEntry] = []
        for rawLine in result.output.split(separator: "\n") {
            let line = String(rawLine)
            var name = line, id = ""
            if let range = line.range(of: " [id: ") {
                name = String(line[..<range.lowerBound])
                id = String(line[range.upperBound...].prefix { $0 != "]" })
            }
            name = name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !seen.contains(name) {
                seen.insert(name)
                entries.append(LastPassEntry(name: name, id: id))
            }
        }
        return entries
    }

    /// Field names available on an entry — the `key=value` lines in the
    /// secure-note body (the shared-vault format) plus any custom
    /// "Label: value" fields — so the user can map which field holds each key.
    /// Best-effort; empty on failure.
    static func availableFields(entry: String) -> [String] {
        let entry = entry.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty, let lpass = LastPass.locate() else { return [] }
        var seen = Set<String>(), fields: [String] = []
        func add(_ raw: String) {
            let key = raw.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !seen.contains(key) { seen.insert(key); fields.append(key) }
        }

        // Secure-note body: key=value lines (datadogAPIKey=…, datadogAPPKey=…).
        // `--notes` prints just the body, so every line is a candidate.
        if let notes = capture(URL(fileURLWithPath: lpass), ["show", "--notes", entry], timeout: 30),
           notes.status == 0 {
            for line in notes.output.split(separator: "\n") {
                if let eq = line.firstIndex(of: "=") { add(String(line[..<eq])) }
            }
        }

        // Custom-field entries: "Label: value" lines from the full show,
        // skipping lpass's standard headers.
        let standard: Set<String> = ["username", "password", "url", "notes",
                                     "id", "name", "fullname", "group",
                                     "last modified", "last touch"]
        if let full = capture(URL(fileURLWithPath: lpass), ["show", entry], timeout: 30),
           full.status == 0 {
            let lines = full.output.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, rawLine) in lines.enumerated() {
                if index == 0 { continue }   // first line is the entry's own name/path
                let line = String(rawLine)
                guard let colon = line.range(of: ": ") else { continue }
                let key = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
                if key.lowercased() == "notes" {
                    // The first note line rides on "Notes: <first line>" — grab its key too.
                    let rest = line[colon.upperBound...]
                    if let eq = rest.firstIndex(of: "=") { add(String(rest[..<eq])) }
                } else if !standard.contains(key.lowercased()) {
                    add(key)
                }
            }
        }
        return fields
    }

    /// Read the entry the same way the running app will, capturing stderr and
    /// the app's environment, and return a redacted transcript. This is the
    /// "Test" path: it surfaces exactly why a read fails from inside the app
    /// (e.g. a different HOME/agent than the terminal) instead of silently
    /// falling back. Secret values are never included — only key names and
    /// character counts.
    static func diagnostics(entry: String, apiField: String, appField: String, site: String)
        -> (ok: Bool, report: String) {
        let entry = entry.trimmingCharacters(in: .whitespaces)
        var lines: [String] = []
        let env = ProcessInfo.processInfo.environment

        // Environment the app sees — the usual terminal-vs-GUI culprits.
        let home = env["HOME"] ?? "(unset)"
        lines.append("HOME=\(home)")
        if let lpassHome = env["LPASS_HOME"] { lines.append("LPASS_HOME=\(lpassHome)") }
        let vaultDir = env["LPASS_HOME"] ?? (env["HOME"].map { "\($0)/.lpass" } ?? "")
        if !vaultDir.isEmpty {
            lines.append("vault dir exists: \(FileManager.default.fileExists(atPath: vaultDir)) (\(vaultDir))")
        }

        guard let lpass = LastPass.locate() else {
            lines.append("lpass binary: NOT FOUND — checked /opt/homebrew/bin/lpass, "
                         + "/usr/local/bin/lpass, and PATH. The bundled app's PATH differs "
                         + "from your shell; install lpass to a standard Homebrew path.")
            return (false, lines.joined(separator: "\n"))
        }
        lines.append("lpass binary: \(lpass)")
        lines.append("looking up entry: \(entry)")

        func run(_ args: [String]) -> (status: Int32, output: String) {
            let result = capture(URL(fileURLWithPath: lpass), args, timeout: 30)
            lines.append("")
            lines.append("$ lpass \(shellJoin(args))")
            lines.append("exit: \(result.map { String($0.status) } ?? "no result (couldn't launch)")")
            return (result?.status ?? -1, result?.output ?? "")
        }

        // 1) Are we logged in from the app's point of view? (no secrets here)
        let status = run(["status"])
        let out = status.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { lines.append(out) }

        // 2) Read the API/App keys via --field, then the note body.
        let api = probe(lpass, entry: entry, field: apiField, lines: &lines)
        let app = probe(lpass, entry: entry, field: appField, lines: &lines)
        guard let api, !api.isEmpty, let app, !app.isEmpty else {
            lines.append("")
            let missing = (api?.isEmpty ?? true) ? apiField : appField
            lines.append("❌ Couldn't read \(missing) from “\(entry)”. See the output above.")
            return (false, lines.joined(separator: "\n"))
        }

        // 3) End-to-end: do the keys actually work against Datadog? A 403 here
        //    with a readable note usually means the wrong site for the org, or
        //    an App key missing scopes.
        lines.append("")
        lines.append("$ GET https://api.\(site)/api/v1/validate")
        let (ok, detail) = validateDatadog(apiKey: api, appKey: app, site: site)
        lines.append(detail)
        lines.append("")
        lines.append(ok
                     ? "✅ Keys read and validated against Datadog (\(site)). Save to use this note."
                     : "❌ Keys were read from the note, but Datadog rejected them (see above).")
        return (ok, lines.joined(separator: "\n"))
    }

    /// Validate a Datadog access token (ddpat_/ddsat_). `/api/v1/validate`
    /// only understands API keys, so probe the cheapest call the app actually
    /// needs: one monitor under the monitors_read scope. A 200 proves the
    /// token is live, on the right site, and scoped for our main read path.
    static func validateAccessToken(_ token: String, site: String)
        -> (ok: Bool, detail: String) {
        guard let url = URL(string: "https://api.\(site)/api/v1/monitor?page_size=1") else {
            return (false, "→ invalid site “\(site)”.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let result = probeHTTP(request)
        switch result.code {
        case 200:
            return (true, "→ 200 OK — token is valid for site \(site) and can read monitors.")
        case 403:
            return (false, "→ 403 Forbidden — the token was rejected for site \(site). "
                + "Check the site, that the token hasn't expired, and that it carries "
                + "the scopes this app needs: \(DatadogScope.copyList).")
        case 401:
            return (false, "→ 401 Unauthorized — the token is invalid for site \(site).")
        case -1:
            return (false, result.detail)
        default:
            return (false, "→ HTTP \(result.code).")
        }
    }

    /// Run one request synchronously and report the status code (or a network
    /// error as code -1). Callers are already off the main thread.
    private static func probeHTTP(_ request: URLRequest) -> (code: Int, detail: String) {
        let semaphore = DispatchSemaphore(value: 0)
        var code = -1
        var detail = "→ no response"
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            if let error {
                detail = "→ network error: \(error.localizedDescription)"
                return
            }
            code = (response as? HTTPURLResponse)?.statusCode ?? -1
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return (code, detail)
    }

    /// Call Datadog's key-validation endpoint. Runs synchronously (caller is
    /// already off the main thread) so it can fold into the transcript.
    /// Internal so the onboarding window can validate pasted keys the same way.
    static func validateDatadog(apiKey: String, appKey: String, site: String)
        -> (ok: Bool, detail: String) {
        guard let url = URL(string: "https://api.\(site)/api/v1/validate") else {
            return (false, "→ invalid site “\(site)”.")
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "DD-API-KEY")
        request.setValue(appKey, forHTTPHeaderField: "DD-APPLICATION-KEY")
        request.timeoutInterval = 15
        let semaphore = DispatchSemaphore(value: 0)
        var detail = "→ no response"
        var ok = false
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            if let error {
                detail = "→ network error: \(error.localizedDescription)"
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            switch code {
            case 200:
                ok = true
                detail = "→ 200 OK — keys are valid for site \(site)."
            case 403:
                detail = "→ 403 Forbidden — Datadog rejected the keys for site \(site). "
                    + "Likely the wrong site for your org (try datadoghq.eu / us3 / us5 / "
                    + "ap1 in Settings), or the App key lacks the needed scopes."
            case 401:
                detail = "→ 401 Unauthorized — the API key is invalid for site \(site)."
            default:
                detail = "→ HTTP \(code)."
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return (ok, detail)
    }

    /// Probe one field like `get` does (--field then key=value notes), logging
    /// each step with the value redacted. Returns the value found, or nil.
    private static func probe(_ lpass: String, entry: String, field: String,
                              lines: inout [String]) -> String? {
        let fieldResult = capture(URL(fileURLWithPath: lpass),
                                  ["show", "--field", field, entry], timeout: 30)
        lines.append("")
        lines.append("$ lpass \(shellJoin(["show", "--field", field, entry]))")
        lines.append("exit: \(fieldResult.map { String($0.status) } ?? "no result")")
        let fieldValue = fieldResult?.status == 0
            ? (fieldResult?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : ""
        if let raw = fieldResult?.output.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            // Redact: if this looks like the value, mask it; otherwise it's an
            // lpass error message worth showing verbatim.
            lines.append(fieldResult?.status == 0 ? "→ value: ••• (\(raw.count) chars)" : raw)
        }
        if !fieldValue.isEmpty { return fieldValue }

        let notes = capture(URL(fileURLWithPath: lpass), ["show", "--notes", entry], timeout: 30)
        lines.append("")
        lines.append("$ lpass \(shellJoin(["show", "--notes", entry]))")
        lines.append("exit: \(notes.map { String($0.status) } ?? "no result")")
        guard notes?.status == 0, let body = notes?.output else {
            if let err = notes?.output.trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
                lines.append(err)
            }
            return nil
        }
        var keys: [String] = []
        var found: String?
        for line in body.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { keys.append(key) }
            if key == field {
                let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { found = value }
            }
        }
        lines.append("keys in note: \(keys.isEmpty ? "(none parsed)" : keys.joined(separator: ", "))")
        return found
    }

    /// Confirm the chosen entry actually yields both Datadog keys.
    static func validate(entry: String, apiField: String, appField: String)
        -> (ok: Bool, error: String?) {
        guard LastPass.isInstalled else { return (false, "LastPass CLI not found.") }
        let entry = entry.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return (false, "Pick an entry.") }
        let api = LastPass.get(entry: entry, field: apiField)
        let app = LastPass.get(entry: entry, field: appField)
        var missing: [String] = []
        if api?.isEmpty ?? true { missing.append(apiField) }
        if app?.isEmpty ?? true { missing.append(appField) }
        if !missing.isEmpty {
            return (false, "Couldn't read field(s) from “\(entry)”: \(missing.joined(separator: ", "))")
        }
        return (true, nil)
    }

    // MARK: Process helper

    /// Render args the way a shell would need them (quoting anything with a
    /// space), so a transcript line is copy-pasteable. This is display-only —
    /// the actual calls pass each arg discretely, never through a shell.
    private static func shellJoin(_ args: [String]) -> String {
        args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    private static func capture(_ url: URL, _ args: [String], timeout: TimeInterval,
                                stdin: String? = nil, extraEnv: [String: String]? = nil)
        -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        if let extraEnv {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in extraEnv { env[key] = value }
            process.environment = env
        }
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        if stdin != nil { process.standardInput = Pipe() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if let stdin, let inPipe = process.standardInput as? Pipe {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
