import AppKit
import SwiftUI

/// Floating pill at the top of the screen while a session is live: an animated face that
/// shows whether Ravi is listening, speaking or thinking, plus a live caption.
@MainActor
final class OverlayController {
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    static let size = NSSize(width: 420, height: 96)

    init(activity: VoiceActivity) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OverlayView(activity: activity))
    }

    func show() {
        hideWork?.cancel()
        position()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func hide(after delay: TimeInterval = 0.6) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in self?.panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Top center of the screen the mouse is on, just under the menu bar.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - Self.size.height - 6)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
    }
}

struct OverlayView: View {
    @ObservedObject var activity: VoiceActivity

    var body: some View {
        HStack(spacing: 12) {
            FaceView(activity: activity)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.95))
                    .textCase(.uppercase)
                if !activity.caption.isEmpty {
                    Text(activity.caption)
                        .font(.system(size: 13, weight: activity.captionIsUser ? .regular : .medium))
                        .foregroundStyle(.white.opacity(activity.captionIsUser ? 0.7 : 0.95))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: 300, alignment: .leading)
                        .animation(nil, value: activity.caption)
                }
            }
            .frame(maxWidth: activity.caption.isEmpty ? 120 : 300, alignment: .leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.86))
                .overlay(Capsule(style: .continuous).stroke(accent.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.2), value: activity.caption.isEmpty)
    }

    private var statusLabel: String {
        switch activity.sessionState {
        case .connecting: return "conectando"
        case .closing: return "até já"
        case .idle: return ""
        case .live:
            if activity.muted { return "mic mutado" }
            if activity.isSpeaking { return "falando" }
            if activity.thinking { return "pensando" }
            return "ouvindo"
        }
    }

    private var accent: Color { FaceView.accent(for: activity) }
}

/// The face: eyes that blink and glance while thinking, a mouth driven by output audio,
/// and a ring that breathes with your mic level.
struct FaceView: View {
    @ObservedObject var activity: VoiceActivity

    static func accent(for a: VoiceActivity) -> Color {
        switch a.sessionState {
        case .connecting, .closing, .idle: return Color(white: 0.6)
        case .live:
            if a.muted { return Color(red: 1, green: 0.35, blue: 0.35) }
            if a.isSpeaking { return Color(red: 0.45, green: 0.7, blue: 1) }
            if a.thinking { return Color(red: 1, green: 0.72, blue: 0.3) }
            return Color(red: 0.35, green: 0.9, blue: 0.6)
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            face(t: t)
        }
    }

    @ViewBuilder
    private func face(t: Double) -> some View {
        let accent = Self.accent(for: activity)
        let live = activity.sessionState == .live
        let listening = live && !activity.muted && !activity.isSpeaking
        let ringLevel = listening ? activity.inputLevel : activity.outputLevel * 0.6
        let pulse = activity.sessionState == .connecting ? 0.5 + 0.5 * sin(t * 4) : 1

        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.22), Color(white: 0.08)],
                                     center: .init(x: 0.4, y: 0.35), startRadius: 2, endRadius: 34))
            // Ring: mic level while listening, rotating arc while thinking.
            if activity.thinking && !activity.isSpeaking {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.radians(t * 5))
            } else {
                Circle()
                    .stroke(accent.opacity((0.35 + ringLevel * 0.65) * pulse), lineWidth: 2 + ringLevel * 4)
                    .scaleEffect(1 + ringLevel * 0.06)
            }
            eyes(t: t, accent: accent)
                .offset(y: -6)
            mouth(accent: accent)
                .offset(y: 11)
        }
        .padding(3)
    }

    private func eyes(t: Double, accent: Color) -> some View {
        // Blink ~every 4 s for ~120 ms.
        let phase = t.truncatingRemainder(dividingBy: 4.1)
        let blink = phase < 0.12 ? 0.15 : 1.0
        // Glance up-right and drift while thinking.
        let thinking = activity.thinking && !activity.isSpeaking
        let look = thinking ? CGSize(width: 3 + sin(t * 1.5) * 2, height: -3) : .zero
        let eye = Capsule().fill(Color.white.opacity(0.95)).frame(width: 7, height: 11 * blink)
        return HStack(spacing: 11) { eye; eye }
            .offset(look)
    }

    @ViewBuilder
    private func mouth(accent: Color) -> some View {
        if activity.muted {
            Capsule().fill(Color.white.opacity(0.8)).frame(width: 14, height: 2.5)
        } else if activity.isSpeaking {
            Capsule()
                .fill(Color.white.opacity(0.95))
                .frame(width: 10 + activity.outputLevel * 6, height: 3 + activity.outputLevel * 12)
        } else {
            Smile()
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 16, height: 6)
        }
    }
}

/// Linear face: no fill, outlined ring, dot eyes, bar mouth. Clean and minimal.
struct LinearFaceView: View {
    @ObservedObject var activity: VoiceActivity

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            face(t: t)
        }
    }

    @ViewBuilder
    private func face(t: Double) -> some View {
        let accent = FaceView.accent(for: activity)
        let live = activity.sessionState == .live
        let thinking = live && activity.thinking && !activity.isSpeaking
        let speaking = live && activity.isSpeaking
        let listening = live && !activity.muted && !speaking && !thinking
        let connecting = activity.sessionState == .connecting
        let muted = live && activity.muted

        ZStack {
            ring(t: t, accent: accent, thinking: thinking, speaking: speaking,
                 listening: listening, connecting: connecting, muted: muted)
            eyes(t: t, accent: accent, speaking: speaking, thinking: thinking)
                .offset(y: -6)
            mouth(t: t, accent: accent, speaking: speaking, thinking: thinking, muted: muted)
                .offset(y: 11)
        }
        .padding(3)
    }

    @ViewBuilder
    private func ring(t: Double, accent: Color, thinking: Bool, speaking: Bool,
                      listening: Bool, connecting: Bool, muted: Bool) -> some View {
        if thinking {
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.radians(t * 5))
        } else if connecting {
            Circle()
                .stroke(accent.opacity(0.4 + 0.4 * sin(t * 3)),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        } else {
            let pulse = speaking ? 0.5 + 0.5 * sin(t * 12) :
                        listening ? 0.5 + 0.5 * sin(t * 2.5) : 0.0
            Circle()
                .stroke(accent.opacity(muted ? 0.45 : 0.65 + pulse * 0.3),
                        lineWidth: (listening || speaking) ? 1.5 + pulse * 2.5 : 1.5)
        }
    }

    private func eyes(t: Double, accent: Color, speaking: Bool, thinking: Bool) -> some View {
        let phase = t.truncatingRemainder(dividingBy: 4.1)
        let blink: Double = phase < 0.12 ? 0.35 : 1.0
        let drift: CGSize = thinking ? CGSize(width: 2.5 * sin(t * 1.5), height: -2.5) : .zero
        let r: Double = speaking ? 3 + 1.5 * abs(sin(t * 8)) : 3
        let dot = Circle().fill(accent.opacity(0.95)).frame(width: r * 2, height: r * 2 * blink)
        return HStack(spacing: 12) { dot; dot }.offset(drift)
    }

    @ViewBuilder
    private func mouth(t: Double, accent: Color, speaking: Bool, thinking: Bool, muted: Bool) -> some View {
        let w: Double = muted ? 16 : speaking ? 10 + activity.outputLevel * 6 : 14
        let h: Double = muted ? 3.5 : speaking ? 2 + activity.outputLevel * 8 : 2
        let opacity: Double = thinking ? 0.45 + 0.4 * abs(sin(t * 2)) : 0.88
        Capsule()
            .fill(accent.opacity(opacity))
            .frame(width: w, height: h)
    }
}

private struct Smile: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY + 4))
        return p
    }
}

/// Renders the overlay in representative states (debug aid, `--snapshot <dir>`).
@MainActor
enum OverlaySnapshots {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cases: [(String, (VoiceActivity) -> Void)] = [
            ("connecting", { $0.sessionState = .connecting }),
            ("listening", { $0.sessionState = .live; $0.inputLevel = 0.6; $0.setCaption("E aí, tudo bom? Tô testando aqui do computador", isUser: true) }),
            ("speaking", { $0.sessionState = .live; $0.outputLevel = 0.7; $0.setCaption("Tudo ótimo também. Como posso te ajudar?", isUser: false) }),
            ("thinking", { $0.sessionState = .live; $0.thinking = true; $0.setCaption("Peraí que vou conferir", isUser: false) }),
            ("muted", { $0.sessionState = .live; $0.muted = true }),
        ]
        for (name, setup) in cases {
            let activity = VoiceActivity()
            setup(activity)
            let renderer = ImageRenderer(content: OverlayView(activity: activity)
                .frame(width: OverlayController.size.width, height: OverlayController.size.height)
                .background(Color(white: 0.93)))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
