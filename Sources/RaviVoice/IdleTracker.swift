import Foundation

/// Decides when a live session has gone quiet. "Activity" is speech from either side
/// (transcript deltas, non-silent output audio) or backend work in flight. The session
/// never idles out while a delegation or tool call is pending — a slow tool keeps it alive.
struct IdleTracker {
    var timeout: TimeInterval
    private(set) var lastActivity: TimeInterval
    private(set) var pendingWork: Set<String> = []

    init(timeout: TimeInterval, now: TimeInterval) {
        self.timeout = timeout
        self.lastActivity = now
    }

    mutating func touch(at now: TimeInterval) {
        lastActivity = max(lastActivity, now)
    }

    mutating func beginWork(_ id: String, at now: TimeInterval) {
        pendingWork.insert(id)
        touch(at: now)
    }

    mutating func endWork(_ id: String, at now: TimeInterval) {
        if pendingWork.remove(id) != nil { touch(at: now) }
    }

    func isIdle(at now: TimeInterval) -> Bool {
        pendingWork.isEmpty && now - lastActivity >= timeout
    }

    func remaining(at now: TimeInterval) -> TimeInterval {
        pendingWork.isEmpty ? max(0, timeout - (now - lastActivity)) : timeout
    }
}
