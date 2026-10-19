import AVFoundation
import CoreAudio

/// Full-duplex audio for the live session: mic → PCM16 24 kHz mono chunks, and PCM16 24 kHz
/// mono from the model → speakers. Voice processing is on so the mic hears the user, not the
/// assistant coming out of the speakers (echo cancellation).
final class AudioIO {
    static let sampleRate: Double = 24_000
    /// 100 ms of 24 kHz mono PCM16.
    static let chunkBytes = 4_800

    /// Called on the audio thread with exactly `chunkBytes` of PCM16 LE.
    var onCapture: ((Data) -> Void)?
    /// Input device name as shown in System Settings › Sound › Input.
    /// nil = macOS system default. Find exact names in Audio MIDI Setup.app.
    var inputDevice: String?

    // Fresh engine per session: re-enabling voice processing on a used engine is unreliable.
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var configObserver: NSObjectProtocol?
    private var restartWork: DispatchWorkItem?
    private(set) var isRunning = false

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        guard !isRunning else { return }
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        // The output side must exist before voice processing is enabled, or the VP output
        // unit fails to initialize (-10875).
        _ = engine.outputNode
        _ = engine.mainMixerNode
        let input = engine.inputNode
        if let name = inputDevice { applyInputDevice(name, to: input) }
        do {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        } catch {
            Log.warn("voice processing indisponível (\(error)); seguindo sem AEC")
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: wireFormat)
        // With voice processing the input has several channels; channel 0 is the processed voice.
        converter?.channelMap = [0]
        input.installTap(onBus: 0, bufferSize: 2_048, format: inFormat) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
        isRunning = true
        Log.info("áudio iniciado (entrada \(Int(inFormat.sampleRate)) Hz, \(inFormat.channelCount) ch)")

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.scheduleRestart()
        }
    }

    func stop() {
        guard isRunning else { return }
        restartWork?.cancel()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        engine.detach(player)
        // Turning VP off releases the mic (and the orange indicator) between sessions.
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        pending.removeAll()
        isRunning = false
        Log.info("áudio parado")
    }

    private func applyInputDevice(_ name: String, to inputNode: AVAudioInputNode) {
        guard let id = Self.enumerateAudioDevices().first(where: { $0.name == name })?.id else {
            Log.warn("microfone '\(name)' não encontrado; usando padrão do sistema")
            return
        }
        var devID = id
        let status = AudioUnitSetProperty(
            inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &devID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr { Log.info("microfone selecionado: \(name)") }
        else { Log.warn("falha ao selecionar microfone '\(name)' (err \(status)); usando padrão do sistema") }
    }

    /// All audio devices with a name.
    static func enumerateAudioDevices() -> [(name: String, id: AudioDeviceID)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else { return [] }
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        return devices.compactMap { id in
            var ref: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &sz, &ref) == noErr, let ref else { return nil }
            return (ref.takeRetainedValue() as String, id)
        }
    }

    /// Names of devices that have at least one input stream (microphones).
    static func availableInputDevices() -> [String] {
        enumerateAudioDevices().filter { pair in
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                  mScope: kAudioObjectPropertyScopeInput,
                                                  mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(pair.id, &addr, 0, nil, &size) == noErr && size > 0
        }.map(\.name)
    }

    /// Voice processing itself posts configuration changes while it settles, so only
    /// rebuild when the engine actually stopped (e.g. AirPods connected), debounced.
    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, !self.engine.isRunning else { return }
            Log.info("dispositivo de áudio mudou; reiniciando engine")
            self.stop()
            do { try self.start() } catch { Log.error("falha ao reiniciar áudio: \(error)") }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Queue PCM16 LE mono 24 kHz for playback.
    func play(pcm16 data: Data) {
        let frames = data.count / 2
        guard isRunning, frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: samples[i])) / 32_768 }
        }
        player.scheduleBuffer(buffer)
    }

    /// Drop whatever is queued (used when the session ends mid-sentence).
    func flushPlayback() {
        player.stop()
        if isRunning { player.play() }
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            Log.error("conversão de áudio falhou: \(error)")
            return
        }
        guard out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        pending.append(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
        while pending.count >= Self.chunkBytes {
            let chunk = pending.prefix(Self.chunkBytes)
            pending.removeFirst(Self.chunkBytes)
            onCapture?(Data(chunk))
        }
    }

    /// Peak amplitude of a PCM16 LE chunk, used to tell speech from the silent frames
    /// the live model streams continuously.
    static func peak(pcm16 data: Data) -> Int {
        data.withUnsafeBytes { raw in
            var peak = 0
            for sample in raw.bindMemory(to: Int16.self) {
                let value = abs(Int(Int16(littleEndian: sample)))
                if value > peak { peak = value }
            }
            return peak
        }
    }
}
