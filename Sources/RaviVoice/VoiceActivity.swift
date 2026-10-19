import Foundation

/// Live, UI-facing view of the session: what the overlay face renders.
@MainActor
final class VoiceActivity: ObservableObject {
    @Published var sessionState: LiveSession.State = .idle
    @Published var muted = false
    /// Backend delegation or tool call in flight.
    @Published var thinking = false
    /// 0…1, smoothed mic level.
    @Published var inputLevel: Double = 0
    /// 0…1, level of the assistant audio being played.
    @Published var outputLevel: Double = 0
    @Published var caption = ""
    @Published var captionIsUser = false

    var isSpeaking: Bool { outputLevel > 0.08 }

    func setInput(_ level: Double) { inputLevel = Self.smooth(inputLevel, level) }
    func setOutput(_ level: Double) { outputLevel = Self.smooth(outputLevel, level) }

    func setCaption(_ text: String, isUser: Bool) {
        // Keep the tail: the overlay shows the last couple of lines.
        caption = text.count > 140 ? "…" + String(text.suffix(140)) : text
        captionIsUser = isUser
    }

    func reset() {
        muted = false
        thinking = false
        inputLevel = 0
        outputLevel = 0
        caption = ""
    }

    /// Fast attack, slower release, so the mouth/ring don't flicker.
    private static func smooth(_ old: Double, _ new: Double) -> Double {
        new > old ? old + (new - old) * 0.7 : old + (new - old) * 0.35
    }

    /// RMS of a PCM16 LE chunk mapped to a perceptual 0…1 level.
    nonisolated static func level(pcm16 data: Data) -> Double {
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum = 0.0
            for sample in samples {
                let v = Double(Int16(littleEndian: sample)) / 32_768
                sum += v * v
            }
            let rms = (sum / Double(samples.count)).squareRoot()
            return min(1, pow(rms * 7, 0.6))
        }
    }
}
