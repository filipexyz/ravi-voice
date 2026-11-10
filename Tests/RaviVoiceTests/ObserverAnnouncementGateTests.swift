import Foundation
import XCTest
@testable import RaviVoice

final class ObserverAnnouncementGateTests: XCTestCase {
    private func recordQuiet(_ gate: ObserverAnnouncementGate, from start: TimeInterval = 0,
                             through end: TimeInterval = 1) {
        for time in stride(from: start, through: end, by: 0.125) {
            XCTAssertFalse(gate.noteInput(level: 0.01, at: time))
        }
    }

    func testMissingCaptureNeverCountsAsQuiet() {
        let gate = ObserverAnnouncementGate()
        XCTAssertFalse(gate.canSubmit(at: 10))
        XCTAssertFalse(gate.markSubmitted(at: 10))
        XCTAssertFalse(gate.allowsPlayback(at: 10))
        XCTAssertFalse(gate.isCancelled)
    }

    func testContinuousQuietAdmitsExactlyOnceAndKeepsPlaybackGuarded() {
        let gate = ObserverAnnouncementGate()
        recordQuiet(gate, through: 0.875)
        XCTAssertFalse(gate.canSubmit(at: 0.875))
        XCTAssertFalse(gate.allowsPlayback(at: 0.875))
        XCTAssertFalse(gate.noteInput(level: 0.01, at: 1))
        XCTAssertTrue(gate.canSubmit(at: 1))
        XCTAssertTrue(gate.markSubmitted(at: 1))
        XCTAssertFalse(gate.canSubmit(at: 1))
        XCTAssertFalse(gate.markSubmitted(at: 1))
        XCTAssertTrue(gate.allowsPlayback(at: 1.125))
    }

    func testSpeechBeforeAdmissionCancelsWithoutRetry() {
        let gate = ObserverAnnouncementGate()
        XCTAssertTrue(gate.noteInput(level: 0.08, at: 0))
        XCTAssertTrue(gate.noteInput(level: 0, at: 1))
        XCTAssertTrue(gate.isCancelled)
        XCTAssertFalse(gate.markSubmitted(at: 1))
        XCTAssertFalse(gate.allowsPlayback(at: 1))
    }

    func testBargeInAfterAdmissionBlocksEveryLaterAudioChunk() {
        let gate = ObserverAnnouncementGate()
        recordQuiet(gate)
        XCTAssertTrue(gate.markSubmitted(at: 1))
        XCTAssertTrue(gate.allowsPlayback(at: 1))
        XCTAssertTrue(gate.noteInput(level: 0.2, at: 1.125))
        XCTAssertFalse(gate.allowsPlayback(at: 1.125))
        XCTAssertTrue(gate.noteInput(level: 0, at: 1.25))
        XCTAssertFalse(gate.allowsPlayback(at: 1.25))
        XCTAssertFalse(gate.markSubmitted(at: 2))
    }

    func testNonFiniteInputFailsClosed() {
        for level in [Double.nan, .infinity, -.infinity] {
            let gate = ObserverAnnouncementGate()
            XCTAssertTrue(gate.noteInput(level: level, at: 0))
            XCTAssertTrue(gate.isCancelled)
            XCTAssertFalse(gate.canSubmit(at: 1))
        }
        let gate = ObserverAnnouncementGate()
        XCTAssertTrue(gate.noteInput(level: 0, at: .nan))
        XCTAssertFalse(gate.canSubmit(at: 1))
    }

    func testCaptureGapBeforeAdmissionRestartsTheQuietWindow() {
        let gate = ObserverAnnouncementGate()
        recordQuiet(gate, through: 0.5)
        XCTAssertFalse(gate.canSubmit(at: 1))
        XCTAssertFalse(gate.noteInput(level: 0, at: 1))
        XCTAssertFalse(gate.canSubmit(at: 1))
        recordQuiet(gate, from: 1.125, through: 1.875)
        XCTAssertFalse(gate.markSubmitted(at: 1.875))
        XCTAssertFalse(gate.noteInput(level: 0, at: 2))
        XCTAssertTrue(gate.markSubmitted(at: 2))
    }

    func testStaleCaptureAfterAdmissionCancelsPermanently() {
        let gate = ObserverAnnouncementGate()
        recordQuiet(gate)
        XCTAssertTrue(gate.markSubmitted(at: 1))
        XCTAssertTrue(gate.allowsPlayback(at: 1.25))
        XCTAssertFalse(gate.allowsPlayback(at: 1.375))
        XCTAssertTrue(gate.isCancelled)
        XCTAssertTrue(gate.noteInput(level: 0, at: 1.5))
        XCTAssertFalse(gate.allowsPlayback(at: 1.5))
    }

    func testCaptureCannotResumeAfterAnUnobservedIntervalFollowingSubmission() {
        let gate = ObserverAnnouncementGate()
        recordQuiet(gate)
        XCTAssertTrue(gate.markSubmitted(at: 1))
        // No playback callback occurred during the capture outage.
        XCTAssertTrue(gate.noteInput(level: 0, at: 1.5))
        XCTAssertTrue(gate.isCancelled)
        XCTAssertFalse(gate.allowsPlayback(at: 1.5))
    }

    func testRegressiveCaptureTimestampFailsClosed() {
        let gate = ObserverAnnouncementGate()
        XCTAssertFalse(gate.noteInput(level: 0, at: 1))
        XCTAssertTrue(gate.noteInput(level: 0, at: 0.875))
        XCTAssertTrue(gate.isCancelled)
        XCTAssertFalse(gate.markSubmitted(at: 2))
    }

    func testRegressivePlaybackTimestampFailsClosed() {
        let gate = ObserverAnnouncementGate()
        recordQuiet(gate)
        XCTAssertTrue(gate.markSubmitted(at: 1))
        XCTAssertFalse(gate.allowsPlayback(at: 0.875))
        XCTAssertTrue(gate.isCancelled)
        XCTAssertFalse(gate.allowsPlayback(at: 1))
    }

    func testExplicitCancellationAndInvalidConfigurationFailClosed() {
        let gate = ObserverAnnouncementGate()
        recordQuiet(gate)
        gate.cancel()
        XCTAssertTrue(gate.isCancelled)
        XCTAssertFalse(gate.markSubmitted(at: 1))

        for invalid in [ObserverAnnouncementGate(inputThreshold: .nan),
                        ObserverAnnouncementGate(quietSeconds: 0),
                        ObserverAnnouncementGate(sampleFreshness: .infinity)] {
            XCTAssertTrue(invalid.isCancelled)
            XCTAssertTrue(invalid.noteInput(level: 0, at: 0))
            XCTAssertFalse(invalid.canSubmit(at: 1))
        }
    }

    func testConcurrentSubmissionsHaveOneWinner() {
        let gate = ObserverAnnouncementGate()
        recordQuiet(gate)
        let lock = NSLock()
        var admitted = 0
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if gate.markSubmitted(at: 1) {
                lock.withLock { admitted += 1 }
            }
        }
        XCTAssertEqual(admitted, 1)
        XCTAssertTrue(gate.allowsPlayback(at: 1))
    }
}
