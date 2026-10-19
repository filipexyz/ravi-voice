import AppKit

// `RaviVoice say …` / `RaviVoice deliver …` run as plain commands, without the menu bar app.
if let code = CLI.run(CommandLine.arguments) { exit(code) }

let app = NSApplication.shared

// Debug: `RaviVoice --snapshot <dir>` renders the overlay in each state to PNGs and exits.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { OverlaySnapshots.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
    exit(0)
}
// Debug: `RaviVoice --ravi-context` prints what a new session would get from Ravi and exits.
if CommandLine.arguments.contains("--ravi-context") {
    Task { @MainActor in
        guard let gateway = RaviGateway.fromConfig(Config.load()) else { exit(1) }
        let config = Config.load()
        let bridge = RaviBridge(gateway: gateway, sessions: config.raviRecentSessions, messages: config.raviMessagesPerSession)
        await bridge.refresh().value
        print(bridge.takeVoiceContext())
        print("\n---- backend ----\n" + bridge.backendContext())
        exit(0)
    }
    RunLoop.main.run()
}
guard SingleInstance.claim() else { Log.flush(); exit(0) }
let controller = MainActor.assumeIsolated { AppController() }
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
