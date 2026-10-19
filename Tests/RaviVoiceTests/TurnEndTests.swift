import Foundation
import XCTest
@testable import RaviVoice

final class D0DetectorTests: XCTestCase {
    func testCandidateOnlyAfterQuietAndNoInput() {
        let d0 = D0Detector(config: D0Config())
        XCTAssertTrue(d0.isCandidate(
            outputLevel: 0, inputLevel: 0,
            msSinceAgentSpeech: 350, msSinceUserSpeech: 5_000,
            pendingWork: false
        ))
        XCTAssertFalse(d0.isCandidate(
            outputLevel: 0.2, inputLevel: 0,
            msSinceAgentSpeech: 350, msSinceUserSpeech: 5_000,
            pendingWork: false
        ))
        XCTAssertFalse(d0.isCandidate(
            outputLevel: 0, inputLevel: 0.2,
            msSinceAgentSpeech: 350, msSinceUserSpeech: 5_000,
            pendingWork: false
        ))
        XCTAssertFalse(d0.isCandidate(
            outputLevel: 0, inputLevel: 0,
            msSinceAgentSpeech: 299, msSinceUserSpeech: 5_000,
            pendingWork: false
        ))
    }

    func testPendingWorkBlocksCandidate() {
        let d0 = D0Detector(config: D0Config())
        XCTAssertFalse(d0.isCandidate(
            outputLevel: 0, inputLevel: 0,
            msSinceAgentSpeech: 900, msSinceUserSpeech: 5_000,
            pendingWork: true
        ))
    }

    func testUserGuardNeedsHalfSecond() {
        let d0 = D0Detector(config: D0Config())
        XCTAssertFalse(d0.isCandidate(
            outputLevel: 0, inputLevel: 0,
            msSinceAgentSpeech: 900, msSinceUserSpeech: 499,
            pendingWork: false
        ))
        XCTAssertTrue(d0.isCandidate(
            outputLevel: 0, inputLevel: 0,
            msSinceAgentSpeech: 900, msSinceUserSpeech: 500,
            pendingWork: false
        ))
    }
}

final class TurnEndGateTests: XCTestCase {
    /// Reproduz o caso do "até mais": o close chegou com 389 ms desde a fala do usuário.
    /// O gate bloqueia por user_guard; depois de 500 ms, libera.
    func testUserGuardBlocksThenOpens() {
        let gate = TurnEndGate(config: D0Config())
        var signals = TurnSignals(
            outputLevel: 0.064, inputLevel: 0.011,
            msSinceAgentSpeech: 436, msSinceUserSpeech: 389,
            eos: true, pendingWork: false, closeRequested: false
        )
        XCTAssertEqual(gate.failure(signals), "user_guard")
        signals.msSinceUserSpeech = 900
        XCTAssertNil(gate.failure(signals))
        XCTAssertTrue(gate.isOpen(signals))
    }

    func testOutputAndInputBlock() {
        let gate = TurnEndGate(config: D0Config())
        var signals = TurnSignals(
            outputLevel: 0.2, inputLevel: 0,
            msSinceAgentSpeech: 900, msSinceUserSpeech: 5_000,
            eos: true, pendingWork: false, closeRequested: false
        )
        XCTAssertEqual(gate.failure(signals), "output_level")
        signals.outputLevel = 0
        signals.inputLevel = 0.2
        XCTAssertEqual(gate.failure(signals), "input_level")
    }

    func testPendingWorkBlocks() {
        let gate = TurnEndGate(config: D0Config())
        let signals = TurnSignals(
            outputLevel: 0, inputLevel: 0,
            msSinceAgentSpeech: 900, msSinceUserSpeech: 5_000,
            eos: true, pendingWork: true, closeRequested: false
        )
        XCTAssertEqual(gate.failure(signals), "pending_work")
    }
}

final class TurnEndPolicyTests: XCTestCase {
    let signals = TurnSignals(
        outputLevel: 0, inputLevel: 0,
        msSinceAgentSpeech: 2_000, msSinceUserSpeech: 10_000,
        eos: true, pendingWork: false, closeRequested: false
    )

    func response(
        _ state: ConversationState,
        pode: Double,
        complete: Double = 0.95,
        explicit: Double = 0.05
    ) -> TurnEndResponse {
        TurnEndResponse(
            decision: "wait",
            state: state,
            stateProb: pode,
            podeProb: pode,
            completeProb: complete,
            explicitProb: explicit,
            reasonCode: "TEST"
        )
    }

    func testExplicitCloseWinsWithoutConversationState() {
        let engine = TurnEndPolicyEngine(config: TurnPolicy())
        let r = response(.continua, pode: 0.3, explicit: 0.9)
        // O estado continua, mas o pedido explícito não basta: o agente não fechou a fala.
        XCTAssertEqual(engine.decide(r, signals: signals), .wait)
        let encerrada = response(.encerrada, pode: 0.9, explicit: 0.9)
        XCTAssertEqual(engine.decide(encerrada, signals: signals), .close)
    }

    func testEndedStateCloses() {
        let engine = TurnEndPolicyEngine(config: TurnPolicy())
        XCTAssertEqual(engine.decide(response(.encerrada, pode: 0.9), signals: signals), .close)
    }

    func testWaitingStateNeedsThreeSeconds() {
        let engine = TurnEndPolicyEngine(config: TurnPolicy())
        let r = response(.aguardando, pode: 0.99)
        XCTAssertEqual(engine.decide(r, signals: signals), .wait)
        var later = signals
        later.msSinceAgentSpeech = 3_500
        XCTAssertEqual(engine.decide(r, signals: later), .close)
    }

    func testContinuesNeverClosesWithoutExplicit() {
        let engine = TurnEndPolicyEngine(config: TurnPolicy())
        XCTAssertEqual(engine.decide(response(.continua, pode: 0.99), signals: signals), .wait)
    }

    func testIncompleteSpeechWaits() {
        let engine = TurnEndPolicyEngine(config: TurnPolicy())
        XCTAssertEqual(engine.decide(response(.encerrada, pode: 0.99, complete: 0.2), signals: signals), .wait)
    }
}

final class TurnEndContractTests: XCTestCase {
    func testRequestUsesSnakeCaseKeys() throws {
        let request = TurnEndRequest(
            requestId: "r1", sessionId: "s1", turnId: "t1", candidateId: "c1",
            mode: "shadow", deadlineMs: 1500,
            signals: TurnSignals(
                outputLevel: 0, inputLevel: 0,
                msSinceAgentSpeech: 1200, msSinceUserSpeech: 8000,
                eos: true, pendingWork: false, closeRequested: true
            ),
            snippets: TurnSnippets(
                lastUser: "Pode desligar",
                lastAgent: "Fechou.",
                recent: [TurnSnippet(role: "user", text: "Pode desligar")]
            ),
            policy: TurnPolicy()
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schema"] as? String, "ravi.turn_end.request/v1")
        XCTAssertNotNil(object["session_id"])
        XCTAssertNotNil(object["candidate_id"])
        let signals = try XCTUnwrap(object["signals"] as? [String: Any])
        XCTAssertNotNil(signals["ms_since_agent_speech"])
        XCTAssertNotNil(signals["pending_work"])
    }

    func testDecisionDecodesFailSafeShape() throws {
        let json = """
        {"schema":"ravi.turn_end.decision/v1","request_id":"r1","decision":"wait",
         "state":null,"state_prob":null,"pode_prob":null,"complete_prob":null,
         "explicit_prob":null,"confidence":null,"reason_code":"DEADLINE",
         "reason":"sem resposta","provider":"jev","model":"typesafe-ai/jev",
         "latency_ms":804,"shadow":true,"expires_in_ms":1500}
        """
        let response = try JSONDecoder().decode(TurnEndResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.action, .wait)
        XCTAssertEqual(response.reasonCode, "DEADLINE")
    }
}
