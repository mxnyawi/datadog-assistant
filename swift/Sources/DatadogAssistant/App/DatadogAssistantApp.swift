import AppKit

@main
@MainActor
struct DatadogAssistantApp {
    static func main() {
        guard acquireSingleInstanceLock() else {
            print("Datadog Assistant is already running 🐶")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// One instance only — two poll loops would double API traffic and
    /// duplicate every notification. The fd stays open (and the lock held)
    /// for the process's lifetime.
    private static func acquireSingleInstanceLock() -> Bool {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DatadogAssistant", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])   // SecretStore lives here — owner-only
        let fd = open(dir.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }   // can't lock → don't block launch
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }
}
