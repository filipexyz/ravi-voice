import CoreGraphics
import Foundation
import XCTest
@testable import RaviVoice

final class HotkeySpecTests: XCTestCase {
    func testParsesLoneModifiers() {
        XCTAssertEqual(HotkeySpec.parse("rightCommand"), .modifierTap(keyCode: 54, deviceMask: 0x10))
        XCTAssertEqual(HotkeySpec.parse("Right Option"), .modifierTap(keyCode: 61, deviceMask: 0x40))
    }

    func testParsesCombos() {
        XCTAssertEqual(HotkeySpec.parse("ctrl+option+space"), .combo(keyCode: 49, modifiers: [.maskControl, .maskAlternate]))
        XCTAssertEqual(HotkeySpec.parse("cmd+shift+f12"), .combo(keyCode: 111, modifiers: [.maskCommand, .maskShift]))
    }

    func testRejectsGarbage() {
        XCTAssertNil(HotkeySpec.parse("hyper+banana"))
        XCTAssertNil(HotkeySpec.parse("ctrl+nope"))
    }
}

final class ModifierTapDetectorTests: XCTestCase {
    // Right ⌘ down: generic command flag + right-command device bit.
    let rightCmdDown: UInt64 = CGEventFlags.maskCommand.rawValue | 0x10
    let released: UInt64 = 0

    func testQuickTapFires() {
        var d = ModifierTapDetector(keyCode: 54, deviceMask: 0x10)
        XCTAssertFalse(d.flagsChanged(keyCode: 54, flags: rightCmdDown, at: 1.0))
        XCTAssertTrue(d.flagsChanged(keyCode: 54, flags: released, at: 1.2))
    }

    func testLongHoldDoesNotFire() {
        var d = ModifierTapDetector(keyCode: 54, deviceMask: 0x10)
        _ = d.flagsChanged(keyCode: 54, flags: rightCmdDown, at: 1.0)
        XCTAssertFalse(d.flagsChanged(keyCode: 54, flags: released, at: 2.0))
    }

    func testShortcutWithRightCommandDoesNotFire() {
        var d = ModifierTapDetector(keyCode: 54, deviceMask: 0x10)
        _ = d.flagsChanged(keyCode: 54, flags: rightCmdDown, at: 1.0)
        d.keyDown() // ⌘C
        XCTAssertFalse(d.flagsChanged(keyCode: 54, flags: released, at: 1.1))
    }

    func testChordWithOtherModifierDoesNotFire() {
        var d = ModifierTapDetector(keyCode: 54, deviceMask: 0x10)
        _ = d.flagsChanged(keyCode: 56, flags: CGEventFlags.maskShift.rawValue | 0x02, at: 0.9)
        XCTAssertFalse(d.flagsChanged(keyCode: 54, flags: rightCmdDown | CGEventFlags.maskShift.rawValue, at: 1.0))
        XCTAssertFalse(d.flagsChanged(keyCode: 54, flags: CGEventFlags.maskShift.rawValue, at: 1.1))
    }

    func testLeftCommandDoesNotTriggerRight() {
        var d = ModifierTapDetector(keyCode: 54, deviceMask: 0x10)
        _ = d.flagsChanged(keyCode: 55, flags: CGEventFlags.maskCommand.rawValue | 0x08, at: 1.0)
        XCTAssertFalse(d.flagsChanged(keyCode: 55, flags: released, at: 1.1))
    }
}

final class IdleTrackerTests: XCTestCase {
    func testIdlesAfterTimeout() {
        var t = IdleTracker(timeout: 60, now: 0)
        XCTAssertFalse(t.isIdle(at: 59))
        XCTAssertTrue(t.isIdle(at: 60))
    }

    func testActivityResetsClock() {
        var t = IdleTracker(timeout: 60, now: 0)
        t.touch(at: 50)
        XCTAssertFalse(t.isIdle(at: 100))
        XCTAssertTrue(t.isIdle(at: 110))
    }

    func testPendingWorkKeepsSessionAlive() {
        var t = IdleTracker(timeout: 60, now: 0)
        t.beginWork("d1", at: 10)
        XCTAssertFalse(t.isIdle(at: 500))
        t.endWork("d1", at: 500)
        XCTAssertFalse(t.isIdle(at: 559))
        XCTAssertTrue(t.isIdle(at: 560))
    }
}

final class ConfigTests: XCTestCase {
    func testReadsDotenv() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-\(UUID()).env")
        try "# c\nexport OPENAI_API_KEY=\"sk-abc\"\nFOO = bar\n\nBAD\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let env = Config.readDotenv(url)
        XCTAssertEqual(env["OPENAI_API_KEY"], "sk-abc")
        XCTAssertEqual(env["FOO"], "bar")
        XCTAssertNil(env["BAD"])
    }
}

final class ToolRegistryTests: XCTestCase {
    func testDefinitionsAndCalls() async {
        let registry = ToolRegistry([CurrentTimeTool()])
        XCTAssertEqual(registry.definitions.first?["name"] as? String, "current_time")
        let output = await registry.call(name: "current_time", argumentsJSON: "{}")
        XCTAssertTrue(output.contains("timeZone"))
        let missing = await registry.call(name: "nope", argumentsJSON: "{}")
        XCTAssertTrue(missing.contains("unknown tool"))
    }
}

final class AudioPeakTests: XCTestCase {
    func testPeak() {
        var samples: [Int16] = [0, 10, -400, 20]
        let data = Data(bytes: &samples, count: samples.count * 2)
        XCTAssertEqual(AudioIO.peak(pcm16: data), 400)
    }
}

final class RaviTextTests: XCTestCase {
    func testCleanStripsRoutingHeaders() {
        let raw = """
        [session surface] This turn came from a WhatsApp chat. A normal reply returns there.
        [WhatsApp Métricas id:120363@g.us mid:3EB0 18/10/2026, 17:15 sun] Luís Filipe: rodei aqui
        e   funcionou
        """
        XCTAssertEqual(RaviText.clean(raw), "Luís Filipe: rodei aqui e funcionou")
    }

    func testCleanKeepsInlineBrackets() {
        XCTAssertEqual(RaviText.clean("veja [isso] aqui"), "veja [isso] aqui")
    }

    func testRelative() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(RaviText.relative(now.addingTimeInterval(-30), now: now), "agora")
        XCTAssertEqual(RaviText.relative(now.addingTimeInterval(-5 * 60), now: now), "há 5 min")
        XCTAssertEqual(RaviText.relative(now.addingTimeInterval(-3 * 3600), now: now), "há 3 h")
        XCTAssertEqual(RaviText.relative(nil, now: now), "sem data")
    }

    func testVoiceContextIncludesSessionsAndHeldReplies() {
        let now = Date()
        let session = RaviSessionDigest(
            name: "m-tricas", agentId: "ravi-metrics", displayName: "Métricas", channel: "whatsapp",
            updatedAt: now.addingTimeInterval(-600),
            messages: [.init(role: "user", text: "como tá o /uso?", time: nil),
                       .init(role: "assistant", text: "Publicado em ravi-metrics.ravi.page/uso", time: nil)]
        )
        let reply = RaviReply(session: "main", text: "feito", receivedAt: now)
        let text = RaviText.voiceContext(sessions: [session], replies: [reply], now: now)
        XCTAssertTrue(text.contains("m-tricas (\"Métricas\", agente ravi-metrics, whatsapp) — ativa há 10 min"))
        XCTAssertTrue(text.contains("- usuário: como tá o /uso?"))
        XCTAssertTrue(text.contains("- agente: Publicado"))
        XCTAssertTrue(text.contains("- main (agora): feito"))
        XCTAssertTrue(RaviText.backendContext(sessions: [session], now: now).contains("- m-tricas"))
    }

    func testTruncate() {
        XCTAssertEqual(RaviText.truncate("abcdef", 3), "abc…")
        XCTAssertEqual(RaviText.truncate("ab", 3), "ab")
    }
}

final class RaviNoiseTests: XCTestCase {
    func testCleansAttachmentsAndMarkdown() {
        let raw = "[WhatsApp X id:1] Luís: [Audio] Transcript: me ajuda com o **tema**? file: /Users/luis/a.ogg"
        XCTAssertEqual(RaviText.clean(raw), "Luís: (áudio) me ajuda com o tema?")
        XCTAssertEqual(RaviText.clean("Luís: [Document: /tmp/x.html]"), "Luís: [anexo]")
        XCTAssertEqual(RaviText.clean("rode `ravi whoami`"), "rode ravi whoami")
    }

    func testDetectsEventNoise() {
        XCTAssertTrue(RaviText.isNoise(RaviText.clean("[Trigger: x]\nEvent: ravi.console.inbox.item Data: {}")))
        XCTAssertFalse(RaviText.isNoise("abre"))
    }
}

final class SingleInstanceTests: XCTestCase {
    func testDecisions() {
        XCTAssertEqual(SingleInstance.decide(isLaunchdJob: false, otherPids: []), .run)
        XCTAssertEqual(SingleInstance.decide(isLaunchdJob: true, otherPids: []), .run)
        XCTAssertEqual(SingleInstance.decide(isLaunchdJob: false, otherPids: [42]), .exitBecauseAlreadyRunning)
        XCTAssertEqual(SingleInstance.decide(isLaunchdJob: true, otherPids: [42]), .takeOver(pids: [42]))
    }
}

final class VoiceBridgeTests: XCTestCase {
    func testMessageRoundTripAndEnvelope() throws {
        let message = VoiceMessage(correlationId: "voice_1", replyTo: "vreq_1", text: "pronto",
                                   fromSession: "comm", fromAgent: "comm", createdAt: Date(timeIntervalSince1970: 1_792_000_000))
        let data = try message.encoded()
        XCTAssertEqual(try VoiceMessage.decode(data), message)
        let wrapped = try JSONSerialization.data(withJSONObject: ["data": try JSONSerialization.jsonObject(with: data)])
        XCTAssertEqual(try VoiceMessage.decode(wrapped), message)
    }

    func testRequestPromptCarriesReturnInstruction() {
        let prompt = RaviText.requestPrompt(message: "o que tá rolando?", requestId: "vreq_abc")
        XCTAssertTrue(prompt.contains("o que tá rolando?"))
        XCTAssertTrue(prompt.contains("ravi voice say --execute --reply-to vreq_abc --text"))
        XCTAssertTrue(prompt.contains("@@SILENT@@"))
    }

    @MainActor
    func testAnnouncementMatchesPendingRequestOnce() {
        let bridge = RaviBridge(gateway: RaviGateway(baseURL: URL(string: "http://127.0.0.1:1")!, contextKey: "rctx_test"),
                                sessions: 1, messages: 1)
        let reply = VoiceMessage(correlationId: "voice_2", replyTo: "vreq_unknown", text: "**oi**",
                                 fromSession: "comm", fromAgent: nil, createdAt: Date())
        let text = bridge.announcement(for: reply)
        XCTAssertTrue(text.contains("Chegou uma mensagem da sessão comm do Ravi"))
        XCTAssertTrue(text.hasSuffix("oi"))
    }

    func testSayWithoutTextIsUsageError() {
        XCTAssertEqual(CLI.say([]), 2)
    }

    func testNotACLICommand() {
        XCTAssertNil(CLI.run(["RaviVoice"]))
        XCTAssertNil(CLI.run(["RaviVoice", "--start"]))
    }
}

final class ConversationMemoryTests: XCTestCase {
    func testOverlappingSpeakersStayWhole() {
        var assembler = TranscriptAssembler()
        let t0 = Date(timeIntervalSince1970: 1_000)
        assembler.append(.user, "E aí, tudo", now: 0, date: t0)
        assembler.append(.assistant, "Que bom", now: 0.3, date: t0.addingTimeInterval(0.3))
        assembler.append(.user, " bom?", now: 0.5)
        XCTAssertEqual(assembler.flushQuiet(now: 1.0), [])
        let lines = assembler.flushQuiet(now: 2.0)
        XCTAssertEqual(lines.map(\.text), ["E aí, tudo bom?", "Que bom"])
        XCTAssertEqual(lines.map(\.role), [.user, .assistant])
    }

    func testHistoryIsRecentOrderedMergedAndBudgeted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mem-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let memory = ConversationMemory(url: url)
        let now = Date()
        memory.append(Utterance(role: .user, text: "velho demais", at: now.addingTimeInterval(-30 * 3600)))
        memory.append(Utterance(role: .user, text: "meu nome secreto é Jabuticaba", at: now.addingTimeInterval(-600)))
        memory.append(Utterance(role: .user, text: "anota aí", at: now.addingTimeInterval(-590)))
        memory.append(Utterance(role: .assistant, text: "anotado", at: now.addingTimeInterval(-580)))

        let input = memory.historyInput(now: now, maxAge: 12 * 3600, maxTokens: 6000)
        XCTAssertEqual(input.count, 3) // merged user, assistant, developer note
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let firstText = ((input[0]["content"] as? [[String: Any]])?.first?["text"]) as? String
        XCTAssertEqual(firstText, "meu nome secreto é Jabuticaba anota aí")
        XCTAssertEqual(((input[1]["content"] as? [[String: Any]])?.first?["type"]) as? String, "output_text")
        XCTAssertEqual(input[2]["role"] as? String, "developer")
        XCTAssertTrue((((input[2]["content"] as? [[String: Any]])?.first?["text"]) as? String ?? "").contains("há 9 min"))

        // A tight budget keeps only the newest lines.
        let tight = memory.historyInput(now: now, maxAge: 12 * 3600, maxTokens: 70)
        XCTAssertEqual(tight.count, 2)
        XCTAssertEqual(((tight[0]["content"] as? [[String: Any]])?.first?["text"]) as? String, "anotado")

        // It survives a restart.
        XCTAssertEqual(ConversationMemory(url: url).utterances.count, 4)
        memory.clear()
        XCTAssertTrue(ConversationMemory(url: url).historyInput(now: now, maxAge: 3600, maxTokens: 6000).isEmpty)
    }
}

final class TranscriptImportTests: XCTestCase {
    func testImportsOnlyUserAndAssistantLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-tr-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        [2026-10-18T23:49:57.051Z] você: Caraca, funcionou
        [2026-10-18T23:49:57.178Z] ravi: Que bom
        [2026-10-18T23:50:01.000Z] ravi:comm: resposta da sessão
        lixo sem data
        """.write(to: url, atomically: true, encoding: .utf8)
        let imported = ConversationMemory.importTranscriptLog(url)
        XCTAssertEqual(imported.map(\.role), [.user, .assistant])
        XCTAssertEqual(imported.first?.text, "Caraca, funcionou")
    }
}
