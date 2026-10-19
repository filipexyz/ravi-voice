import AppKit
import CoreGraphics

/// A parsed hotkey: either a lone modifier tapped by itself, or a modifier+key combo.
enum HotkeySpec: Equatable {
    case modifierTap(keyCode: Int64, deviceMask: UInt64)
    case combo(keyCode: Int64, modifiers: CGEventFlags)

    static func == (lhs: HotkeySpec, rhs: HotkeySpec) -> Bool {
        switch (lhs, rhs) {
        case let (.modifierTap(a, m), .modifierTap(b, n)): return a == b && m == n
        case let (.combo(a, m), .combo(b, n)): return a == b && m.rawValue == n.rawValue
        default: return false
        }
    }

    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK) tell left from right.
    static let modifierKeys: [String: (keyCode: Int64, deviceMask: UInt64)] = [
        "rightcommand": (54, 0x10), "rightcmd": (54, 0x10),
        "leftcommand": (55, 0x08), "leftcmd": (55, 0x08),
        "rightshift": (60, 0x04), "leftshift": (56, 0x02),
        "rightoption": (61, 0x40), "rightalt": (61, 0x40),
        "leftoption": (58, 0x20), "leftalt": (58, 0x20),
        "rightcontrol": (62, 0x2000), "rightctrl": (62, 0x2000),
        "leftcontrol": (59, 0x01), "leftctrl": (59, 0x01),
        "fn": (63, CGEventFlags.maskSecondaryFn.rawValue),
    ]

    static let comboModifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "ctrl": .maskControl, "control": .maskControl,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate,
        "shift": .maskShift,
    ]

    static let keyCodes: [String: Int64] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "escape": 53, "esc": 53, "`": 50,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    static let relevantComboFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    static func parse(_ raw: String) -> HotkeySpec? {
        let spec = raw.lowercased().replacingOccurrences(of: " ", with: "")
        if let mod = modifierKeys[spec] {
            return .modifierTap(keyCode: mod.keyCode, deviceMask: mod.deviceMask)
        }
        let parts = spec.split(separator: "+").map(String.init)
        guard let keyName = parts.last, let keyCode = keyCodes[keyName] else { return nil }
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            guard let flag = comboModifiers[part] else { return nil }
            flags.insert(flag)
        }
        return .combo(keyCode: keyCode, modifiers: flags)
    }
}

/// Pure state machine for "tap a modifier by itself": press and release the key within
/// `maxTapDuration`, with no other key or modifier involved. Holding right ⌘ for ⌘C never fires.
struct ModifierTapDetector {
    let keyCode: Int64
    let deviceMask: UInt64
    var maxTapDuration: TimeInterval = 0.5
    private var pressedAt: TimeInterval?

    init(keyCode: Int64, deviceMask: UInt64) {
        self.keyCode = keyCode
        self.deviceMask = deviceMask
    }

    /// Feed a flagsChanged event. Returns true when the tap completes.
    mutating func flagsChanged(keyCode: Int64, flags: UInt64, at time: TimeInterval) -> Bool {
        guard keyCode == self.keyCode else {
            pressedAt = nil
            return false
        }
        let isDown = flags & deviceMask != 0
        if isDown {
            // Only arm when no other standard modifier is held alongside it.
            let others = flags & HotkeySpec.relevantComboFlags.rawValue & ~Self.genericFlag(for: keyCode)
            pressedAt = others == 0 ? time : nil
            return false
        }
        defer { pressedAt = nil }
        guard let start = pressedAt else { return false }
        return time - start <= maxTapDuration
    }

    /// Any regular key press while the modifier is down cancels the tap.
    mutating func keyDown() { pressedAt = nil }

    private static func genericFlag(for keyCode: Int64) -> UInt64 {
        switch keyCode {
        case 54, 55: return CGEventFlags.maskCommand.rawValue
        case 56, 60: return CGEventFlags.maskShift.rawValue
        case 58, 61: return CGEventFlags.maskAlternate.rawValue
        case 59, 62: return CGEventFlags.maskControl.rawValue
        default: return 0
        }
    }
}

/// Global, listen-only keyboard monitor built on a CGEventTap.
/// Needs the Input Monitoring permission (System Settings › Privacy & Security).
final class HotkeyMonitor {
    private let spec: HotkeySpec
    private let onTrigger: () -> Void
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var detector: ModifierTapDetector?
    private var retryTimer: Timer?

    init(spec: HotkeySpec, onTrigger: @escaping () -> Void) {
        self.spec = spec
        self.onTrigger = onTrigger
        if case let .modifierTap(code, mask) = spec {
            detector = ModifierTapDetector(keyCode: code, deviceMask: mask)
        }
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
            Log.warn("sem permissão de Input Monitoring; tentando de novo a cada 3s")
            scheduleRetry()
            return false
        }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            Log.error("falha ao criar CGEventTap")
            scheduleRetry()
            return false
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        retryTimer?.invalidate()
        Log.info("hotkey ativo: \(spec)")
        return true
    }

    func stop() {
        retryTimer?.invalidate()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.start()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let now = ProcessInfo.processInfo.systemUptime
            if detector?.flagsChanged(keyCode: code, flags: event.flags.rawValue, at: now) == true {
                fire()
            }
        case .keyDown:
            detector?.keyDown()
            guard case let .combo(code, modifiers) = spec else { return }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let flags = event.flags.intersection(HotkeySpec.relevantComboFlags)
            if !isRepeat, event.getIntegerValueField(.keyboardEventKeycode) == code, flags == modifiers {
                fire()
            }
        default:
            break
        }
    }

    private func fire() {
        DispatchQueue.main.async { [onTrigger] in onTrigger() }
    }
}
