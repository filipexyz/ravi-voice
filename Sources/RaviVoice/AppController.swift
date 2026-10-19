import AppKit
import CoreAudio

/// Menu bar agent: owns the hotkey, the audio engine and the current live session.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()
    private let audio = AudioIO()
    private let tools = ToolRegistry([CurrentTimeTool()])
    private var ravi: RaviBridge?
    private var session: LiveSession?
    private var turnEnd: TurnEndService?
    private var hotkey: HotkeyMonitor?
    private var statusItem: NSStatusItem!
    private var lastEndReason: String?
    private var startingSession = false
    /// Announcements for the session being opened (a woken session speaks them first).
    private var pendingOpening: [String] = []
    private var pendingIdleTimeout: TimeInterval?
    private var inbox: VoiceInbox?
    private let memory = ConversationMemory()
    private let activity = VoiceActivity()
    private lazy var overlay = OverlayController(activity: activity)

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggleSession), keyEquivalent: "")
    private let muteItem = NSMenuItem(title: "Mutar microfone", action: #selector(toggleMute), keyEquivalent: "")
    private let micItem = NSMenuItem(title: "Microfone", action: nil, keyEquivalent: "")
    private let micMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        buildMenu()
        render(.idle)
        installHotkey()
        turnEnd = TurnEndService(config: config.turnEnd)
        setUpRavi()
        tools.register(CloseSessionTool { [weak self] in self?.session?.close(reason: "user_request") })
        inbox = VoiceInbox { [weak self] message in self?.handleInbox(message) }
        inbox?.start()
        registerMicChangeListener()
        Log.info("Ravi Voice pronto; hotkey \(config.hotkey), idle \(Int(config.idleTimeoutSeconds))s")
        if CommandLine.arguments.contains("--start") { startSession() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.close(reason: "quit")
    }

    // MARK: Hotkey

    private func installHotkey() {
        hotkey?.stop()
        guard let spec = HotkeySpec.parse(config.hotkey) else {
            Log.error("hotkey inválida: \(config.hotkey)")
            lastEndReason = "hotkey inválida: \(config.hotkey)"
            return
        }
        hotkey = HotkeyMonitor(spec: spec) { [weak self] in self?.hotkeyPressed() }
        hotkey?.start()
    }

    private func hotkeyPressed() {
        guard let session, session.state != .idle else {
            startSession()
            return
        }
        if session.state == .live, config.hotkeyWhileActive == "mute" {
            toggleMute()
        } else {
            session.close(reason: "hotkey")
        }
    }

    // MARK: Session

    @objc private func toggleSession() {
        if let session, session.state != .idle {
            session.close(reason: "menu")
        } else {
            startSession()
        }
    }

    @objc private func toggleMute() {
        guard let session, session.state == .live else { return }
        session.setMuted(!session.isMuted)
        render(session.state)
    }

    /// Opens a conversation. `opening` is said right away (used when a message wakes the voice).
    private func startSession(opening: [String] = [], idleTimeout: TimeInterval? = nil) {
        pendingOpening.append(contentsOf: opening)
        if idleTimeout != nil { pendingIdleTimeout = idleTimeout }
        guard let apiKey = config.resolveApiKey() else {
            Log.error("OPENAI_API_KEY não encontrada (config, ambiente ou ~/.ravi/.env)")
            lastEndReason = "sem OPENAI_API_KEY"
            render(.idle)
            NSSound(named: "Basso")?.play()
            return
        }
        guard !startingSession else { return }
        startingSession = true
        Task {
            defer { self.startingSession = false }
            guard await AudioIO.requestMicrophoneAccess() else {
                Log.error("sem permissão de microfone (Ajustes › Privacidade › Microfone)")
                self.lastEndReason = "sem permissão de microfone"
                self.render(.idle)
                self.sound("Basso")
                return
            }
            await self.ravi?.prepare()
            self.openSession(apiKey: apiKey)
        }
    }

    private func setUpRavi() {
        guard let gateway = RaviGateway.fromConfig(config) else { return }
        let bridge = RaviBridge(gateway: gateway, sessions: config.raviRecentSessions, messages: config.raviMessagesPerSession)
        bridge.onRequestSent = { [weak self] _ in
            guard let self, self.config.closeAfterRequestSeconds > 0 else { return }
            self.session?.closeWhenQuiet(after: self.config.closeAfterRequestSeconds)
        }
        tools.register(RaviListSessionsTool(gateway: gateway))
        tools.register(RaviSessionRecapTool(gateway: gateway))
        tools.register(RaviSendMessageTool(gateway: gateway, bridge: bridge))
        bridge.startBackgroundRefresh()
        ravi = bridge
        Task { Log.info("Ravi conectado em \(gateway.baseURL.absoluteString)") }
    }

    /// A message on ravi.voice (a reply to a voice request, or another agent talking to the user):
    /// say it in the live conversation, or wake one up to say it.
    private func handleInbox(_ message: VoiceMessage) {
        Log.transcript("ravi:\(message.fromSession ?? message.fromAgent ?? "?")", message.text)
        let text = ravi?.announcement(for: message)
            ?? "Chegou uma mensagem do Ravi pro usuário. Conte agora, resumindo: \(RaviText.truncate(message.text, 1_400))"
        if let session, session.announce(text) {
            // Reply to a voice request: re-arm close-when-quiet so the session ends after
            // speaking the response instead of waiting the full idle timeout.
            if message.replyTo != nil, config.closeAfterRequestSeconds > 0 {
                session.closeWhenQuiet(after: config.closeAfterRequestSeconds + 4)
            }
            return
        }
        if startingSession {
            pendingOpening.append(text)
            return
        }
        let ageMinutes = Date().timeIntervalSince(message.createdAt) / 60
        guard config.wakeOnMessages, ageMinutes < config.wakeMaxAgeMinutes else {
            Log.info("mensagem do Ravi guardada pra próxima conversa (\(Int(ageMinutes)) min)")
            ravi?.hold(message)
            return
        }
        Log.info("mensagem do Ravi (\(message.fromSession ?? "?")); acordando a voz")
        sound("Glass")
        startSession(opening: [text], idleTimeout: config.wakeIdleTimeoutSeconds)
    }

    private func openSession(apiKey: String) {
        audio.inputDevice = config.inputDevice
        let history = config.memoryEnabled
            ? memory.historyInput(maxAge: config.memoryHours * 3600, maxTokens: config.memoryMaxTokens)
            : []
        if !history.isEmpty { Log.info("memória: \(history.count - 1) mensagens da conversa anterior no contexto") }
        let session = LiveSession(
            config: config, apiKey: apiKey, tools: tools, audio: audio,
            voiceContext: ravi?.takeVoiceContext() ?? "",
            backendContext: ravi?.backendContext() ?? "",
            openingCommentary: pendingOpening,
            idleTimeout: pendingIdleTimeout,
            memory: config.memoryEnabled ? memory : nil,
            history: history,
            turnEnd: turnEnd
        )
        pendingOpening.removeAll()
        pendingIdleTimeout = nil
        session.activity = activity
        session.onStateChange = { [weak self] state in
            guard let self else { return }
            self.render(state)
            if state == .live { self.sound("Pop") }
            if self.config.overlay {
                state == .idle ? self.overlay.hide() : self.overlay.show()
            }
        }
        session.onEnded = { [weak self] reason in
            guard let self else { return }
            self.lastEndReason = reason
            self.render(.idle)
            self.overlay.hide()
            self.sound(reason.hasPrefix("error") || reason == "connection_lost" || reason == "audio_error" ? "Basso" : "Blow")
        }
        self.session = session
        session.start()
    }

    private func sound(_ name: String) {
        guard config.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: Mic

    /// Listens for Core Audio device-list changes (plug/unplug) and refreshes the submenu.
    private func registerMicChangeListener() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.rebuildMicMenu()
        }
    }

    /// NSMenuDelegate — rebuild list every time the submenu opens (catches late changes).
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === micMenu else { return }
        rebuildMicMenu()
    }

    private func rebuildMicMenu() {
        micMenu.removeAllItems()
        let defaultItem = NSMenuItem(title: "Padrão do sistema", action: #selector(selectMic(_:)), keyEquivalent: "")
        defaultItem.representedObject = nil as String?
        defaultItem.target = self
        defaultItem.state = config.inputDevice == nil ? .on : .off
        micMenu.addItem(defaultItem)
        let devices = AudioIO.availableInputDevices()
        if !devices.isEmpty { micMenu.addItem(.separator()) }
        for name in devices {
            let it = NSMenuItem(title: name, action: #selector(selectMic(_:)), keyEquivalent: "")
            it.representedObject = name
            it.target = self
            it.state = config.inputDevice == name ? .on : .off
            micMenu.addItem(it)
        }
        micItem.title = config.inputDevice.map { "Microfone: \($0)" } ?? "Microfone"
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String
        config.inputDevice = name
        Config.persistInputDevice(name)
        audio.inputDevice = name
        rebuildMicMenu()
        Log.info("microfone: \(name ?? "padrão do sistema")")
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        toggleItem.target = self
        muteItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(muteItem)
        micItem.submenu = micMenu
        micMenu.delegate = self
        menu.addItem(micItem)
        menu.addItem(.separator())
        menu.addItem(item("Abrir config", #selector(openConfig)))
        menu.addItem(item("Recarregar config", #selector(reloadConfig)))
        menu.addItem(item("Abrir transcrições", #selector(openTranscripts)))
        menu.addItem(item("Esquecer conversas anteriores", #selector(forgetConversations)))
        menu.addItem(item("Abrir log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("Sair", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func render(_ state: LiveSession.State) {
        let muted = session?.isMuted == true
        let symbol: String
        let status: String
        switch state {
        case .idle:
            symbol = "waveform.circle"
            status = lastEndReason.map { "Inativo · última: \($0)" } ?? "Inativo"
        case .connecting:
            symbol = "ellipsis.circle"
            status = "Conectando…"
        case .live:
            symbol = muted ? "mic.slash.circle.fill" : "waveform.circle.fill"
            status = muted ? "Ao vivo · mic mutado" : "Ao vivo · ouvindo"
        case .closing:
            symbol = "ellipsis.circle"
            status = "Encerrando…"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Ravi Voice")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Ravi Voice — \(status)"
        statusLine.title = status
        toggleItem.title = state == .idle ? "Iniciar conversa (\(config.hotkey))" : "Encerrar conversa"
        muteItem.isEnabled = state == .live
        muteItem.title = muted ? "Desmutar microfone" : "Mutar microfone"
    }

    @objc private func openConfig() { NSWorkspace.shared.open(Config.fileURL) }
    @objc private func openTranscripts() { NSWorkspace.shared.open(Log.transcriptURL) }

    @objc private func forgetConversations() {
        memory.clear()
        Log.info("memória de conversas apagada")
    }
    @objc private func openLog() { NSWorkspace.shared.open(Log.logURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func reloadConfig() {
        config = Config.load()
        turnEnd = TurnEndService(config: config.turnEnd)
        installHotkey()
        render(session?.state ?? .idle)
        Log.info("config recarregado (vale a partir da próxima sessão)")
    }
}
