import AppKit

/// Only one Ravi Voice may run: two instances both answer the hotkey and open two sessions.
/// The LaunchAgent copy wins (it has KeepAlive); any other copy defers to a running one.
/// macOS can start a second copy by itself, e.g. "Quit & Reopen" after granting Input Monitoring.
enum SingleInstance {
    static let launchdLabel = "bot.ravi.voice"

    enum Decision: Equatable {
        case run
        case exitBecauseAlreadyRunning
        case takeOver(pids: [pid_t])
    }

    static func decide(isLaunchdJob: Bool, otherPids: [pid_t]) -> Decision {
        if otherPids.isEmpty { return .run }
        return isLaunchdJob ? .takeOver(pids: otherPids) : .exitBecauseAlreadyRunning
    }

    /// Returns false when this process should exit.
    static func claim() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return true } // unbundled dev build
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != me }
        let isLaunchdJob = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == launchdLabel

        switch decide(isLaunchdJob: isLaunchdJob, otherPids: others.map(\.processIdentifier)) {
        case .run:
            return true
        case .exitBecauseAlreadyRunning:
            Log.warn("já existe um Ravi Voice rodando (pid \(others.map(\.processIdentifier))); saindo")
            return false
        case .takeOver(let pids):
            Log.warn("encerrando instâncias extras: \(pids)")
            others.forEach { $0.terminate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
            }
            return true
        }
    }
}
