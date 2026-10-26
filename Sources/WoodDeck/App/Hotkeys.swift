import AppKit
import Carbon.HIToolbox

// 快捷键的显示文本与解析，保存格式为「修饰键+按键」，例如 "control+option+B"
struct Hotkey: Equatable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }

    var encoded: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("control") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("command") }
        parts.append(key.lowercased())
        return parts.joined(separator: "+")
    }

    static func decode(_ text: String) -> Hotkey? {
        let parts = text.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last, key.count >= 1 else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "control", "ctrl": modifiers.insert(.control)
            case "option", "alt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "command", "cmd": modifiers.insert(.command)
            default: return nil
            }
        }
        guard !modifiers.isEmpty else { return nil }
        return Hotkey(key: key, modifiers: modifiers)
    }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    var carbonKey: UInt32? {
        guard let scalar = key.uppercased().unicodeScalars.first else { return nil }
        let characters = String(scalar)
        let table: [String: Int] = [
            "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E,
            "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J,
            "K": kVK_ANSI_K, "L": kVK_ANSI_L, "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O,
            "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
            "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X, "Y": kVK_ANSI_Y,
            "Z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9
        ]
        if let code = table[characters] { return UInt32(code) }
        return nil
    }
}

// 全局快捷键注册，使用 Carbon 的热键接口
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    func register(_ hotkey: Hotkey?, action: @escaping () -> Void) -> UInt32? {
        guard let hotkey, let key = hotkey.carbonKey else { return nil }
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let eventID = EventHotKeyID(signature: OSType(0x42_44_4B_31), id: id)
        let status = RegisterEventHotKey(key, hotkey.carbonModifiers, eventID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return nil }
        references[id] = reference
        handlers[id] = action
        return id
    }

    func unregister(_ id: UInt32?) {
        guard let id else { return }
        if let reference = references.removeValue(forKey: id) {
            UnregisterEventHotKey(reference)
        }
        handlers[id] = nil
    }

    func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            guard status == noErr else { return noErr }
            HotkeyCenter.shared.fire(hotkeyID.id)
            return noErr
        }, 1, &spec, nil, nil)
    }
}
