import Foundation

/// Admission and playback guard for a single, isolated observer announcement.
/// The audio callback records input even before submission. Speech, invalid input or a
/// capture interruption after submission cancels the announcement permanently.
final class ObserverAnnouncementGate: @unchecked Sendable {
    private let lock = NSLock()
    private let inputThreshold: Double
    private let quietSeconds: TimeInterval
    private let sampleFreshness: TimeInterval

    private var quietSince: TimeInterval?
    private var lastInputAt: TimeInterval?
    private var submitted = false
    private var cancelled: Bool

    init(inputThreshold: Double = 0.08, quietSeconds: TimeInterval = 1,
         sampleFreshness: TimeInterval = 0.25) {
        self.inputThreshold = inputThreshold
        self.quietSeconds = quietSeconds
        self.sampleFreshness = sampleFreshness
        cancelled = !inputThreshold.isFinite || inputThreshold <= 0 || inputThreshold > 1
            || !quietSeconds.isFinite || quietSeconds <= 0
            || !sampleFreshness.isFinite || sampleFreshness <= 0
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Returns true when the caller must abandon the announcement and flush playback.
    @discardableResult
    func noteInput(level: Double,
                   at timestamp: @autoclosure () -> TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock {
            let now = timestamp()
            guard !cancelled else { return true }
            guard level.isFinite, now.isFinite, level >= 0, level < inputThreshold else {
                cancelled = true
                return true
            }
            if let lastInputAt {
                guard now >= lastInputAt else {
                    cancelled = true
                    return true
                }
                if now - lastInputAt > sampleFreshness {
                    // Once submitted, fresh input cannot resurrect an announcement that
                    // had an unobserved interval while its audio could be arriving.
                    if submitted {
                        cancelled = true
                        return true
                    }
                    quietSince = now
                }
            } else {
                quietSince = now
            }
            lastInputAt = now
            return false
        }
    }

    // Sample the monotonic clock only after acquiring the lock. A newer capture must
    // not make a playback check look regressive while that check waits for the lock.
    func canSubmit(at timestamp: @autoclosure () -> TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock { readyToSubmit(at: timestamp()) }
    }

    /// Combines the last input check and one-time admission under the audio callback's lock.
    @discardableResult
    func markSubmitted(at timestamp: @autoclosure () -> TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock {
            guard readyToSubmit(at: timestamp()) else { return false }
            submitted = true
            return true
        }
    }

    func allowsPlayback(at timestamp: @autoclosure () -> TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock {
            guard !cancelled, submitted else { return false }
            guard freshInput(at: timestamp()) else {
                cancelled = true
                return false
            }
            return true
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    /// Call only while holding `lock`.
    private func readyToSubmit(at now: TimeInterval) -> Bool {
        guard !cancelled, !submitted else { return false }
        guard now.isFinite, lastInputAt.map({ now >= $0 }) ?? true else {
            cancelled = true
            return false
        }
        guard let quietSince, freshInput(at: now) else { return false }
        return now - quietSince >= quietSeconds
    }

    /// Call only while holding `lock`. Missing capture is not evidence of silence.
    private func freshInput(at now: TimeInterval) -> Bool {
        guard now.isFinite, let lastInputAt, now >= lastInputAt else { return false }
        return now - lastInputAt <= sampleFreshness
    }
}
