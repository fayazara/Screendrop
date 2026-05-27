//
//  CaptureHotkeys.swift
//  Screendrop
//

import AppKit
import Carbon.HIToolbox
import Foundation

struct HotkeyShortcut: Codable, Equatable, Hashable {
    struct Modifiers: OptionSet, Codable, Equatable, Hashable {
        let rawValue: Int

        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        init(from eventFlags: NSEvent.ModifierFlags) {
            var modifiers: Modifiers = []
            if eventFlags.contains(.command) { modifiers.insert(.command) }
            if eventFlags.contains(.option) { modifiers.insert(.option) }
            if eventFlags.contains(.control) { modifiers.insert(.control) }
            if eventFlags.contains(.shift) { modifiers.insert(.shift) }
            self = modifiers
        }

        var carbonEventModifiers: UInt32 {
            var flags: UInt32 = 0
            if contains(.command) { flags |= UInt32(cmdKey) }
            if contains(.option) { flags |= UInt32(optionKey) }
            if contains(.control) { flags |= UInt32(controlKey) }
            if contains(.shift) { flags |= UInt32(shiftKey) }
            return flags
        }

        var symbols: [String] {
            var result: [String] = []
            if contains(.control) { result.append("⌃") }
            if contains(.option) { result.append("⌥") }
            if contains(.shift) { result.append("⇧") }
            if contains(.command) { result.append("⌘") }
            return result
        }
    }

    let modifiers: Modifiers
    let keyCode: Int

    var displayTokens: [String] {
        modifiers.symbols + [Self.keyLabel(for: keyCode)]
    }

    var displayString: String {
        displayTokens.joined(separator: " ")
    }

    var isValid: Bool {
        !modifiers.isEmpty
    }

    private static func keyLabel(for keyCode: Int) -> String {
        switch keyCode {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            return ansiKeyLabel(for: keyCode) ?? "Key \(keyCode)"
        }
    }

    private static func ansiKeyLabel(for keyCode: Int) -> String? {
        switch keyCode {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        default: return nil
        }
    }
}

enum CaptureHotkeyAction: String, CaseIterable, Identifiable {
    case fullscreen
    case window
    case area
    case screenRecording

    var id: Self { self }

    var hotKeyID: UInt32 {
        switch self {
        case .fullscreen: 1
        case .window: 2
        case .area: 3
        case .screenRecording: 4
        }
    }

    var title: String {
        switch self {
        case .fullscreen: "Fullscreen"
        case .window: "Window"
        case .area: "Area"
        case .screenRecording: "Screen Recording"
        }
    }

    var defaultShortcut: HotkeyShortcut {
        switch self {
        case .fullscreen:
            HotkeyShortcut(modifiers: [.option], keyCode: Int(kVK_ANSI_1))
        case .window:
            HotkeyShortcut(modifiers: [.option], keyCode: Int(kVK_ANSI_2))
        case .area:
            HotkeyShortcut(modifiers: [.option], keyCode: Int(kVK_ANSI_3))
        case .screenRecording:
            HotkeyShortcut(modifiers: [.option], keyCode: Int(kVK_ANSI_4))
        }
    }

    var preferencesKey: String {
        switch self {
        case .fullscreen:
            ScreendropPreferences.fullscreenHotkeyKey
        case .window:
            ScreendropPreferences.windowHotkeyKey
        case .area:
            ScreendropPreferences.areaHotkeyKey
        case .screenRecording:
            ScreendropPreferences.screenRecordingHotkeyKey
        }
    }

    init?(hotKeyID: UInt32) {
        guard let action = Self.allCases.first(where: { $0.hotKeyID == hotKeyID }) else {
            return nil
        }

        self = action
    }

    func perform() {
        switch self {
        case .fullscreen:
            CaptureCoordinator.shared.captureFullscreen()
        case .window:
            CaptureCoordinator.shared.captureWindow()
        case .area:
            CaptureCoordinator.shared.captureArea()
        case .screenRecording:
            CaptureCoordinator.shared.recordScreen()
        }
    }
}

enum CaptureHotkeyPreferences {
    static func shortcut(for action: CaptureHotkeyAction, defaults: UserDefaults = .standard) -> HotkeyShortcut {
        guard
            let data = defaults.data(forKey: action.preferencesKey),
            let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data),
            shortcut.isValid
        else {
            return action.defaultShortcut
        }

        return shortcut
    }

    static func saveShortcut(
        _ shortcut: HotkeyShortcut,
        for action: CaptureHotkeyAction,
        defaults: UserDefaults = .standard
    ) {
        guard shortcut != action.defaultShortcut else {
            defaults.removeObject(forKey: action.preferencesKey)
            return
        }

        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: action.preferencesKey)
    }

    static func shortcuts(
        for actions: [CaptureHotkeyAction] = CaptureHotkeyAction.allCases,
        defaults: UserDefaults = .standard
    ) -> [CaptureHotkeyAction: HotkeyShortcut] {
        Dictionary(uniqueKeysWithValues: actions.map { action in
            (action, shortcut(for: action, defaults: defaults))
        })
    }

    static func conflictingAction(
        for shortcut: HotkeyShortcut,
        excluding action: CaptureHotkeyAction,
        defaults: UserDefaults = .standard
    ) -> CaptureHotkeyAction? {
        CaptureHotkeyAction.allCases.first { candidate in
            candidate != action && self.shortcut(for: candidate, defaults: defaults) == shortcut
        }
    }
}
