//
//  HotkeyManager.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit
import Observation
import Carbon.HIToolbox

/// Registers system-wide global keyboard shortcuts for capture actions.
@Observable
final class HotkeyManager {
    
    static let shared = HotkeyManager()
    
    private static let hotKeySignature = OSType(0x4F53_4854)

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [CaptureHotkeyAction: EventHotKeyRef] = [:]
    private(set) var registrationErrors: [CaptureHotkeyAction: String] = [:]
    
    private init() {}

    deinit {
        unregisterHotkeys()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
    
    func registerHotkeys() {
        installEventHandlerIfNeeded()
        reloadHotkeys()
    }

    func reloadHotkeys() {
        unregisterHotkeys()
        registrationErrors.removeAll()

        var registeredShortcuts: Set<HotkeyShortcut> = []
        for action in CaptureHotkeyAction.allCases {
            let shortcut = CaptureHotkeyPreferences.shortcut(for: action)
            guard registeredShortcuts.insert(shortcut).inserted else {
                print("Skipping duplicate hotkey for \(action.title): \(shortcut.displayString)")
                continue
            }

            do {
                hotKeyRefs[action] = try registerHotKey(action: action, shortcut: shortcut)
            } catch {
                registrationErrors[action] = error.localizedDescription
            }
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handlerRef
        )

        if status == noErr {
            eventHandlerRef = handlerRef
        } else {
            print("Failed to install hotkey handler, status=\(status)")
        }
    }
    
    /// Register the replacement before releasing the working shortcut. A
    /// rejected shortcut never changes either the preference or old binding.
    func setShortcut(_ shortcut: HotkeyShortcut, for action: CaptureHotkeyAction) throws {
        if shortcut == CaptureHotkeyPreferences.shortcut(for: action), hotKeyRefs[action] != nil { return }
        installEventHandlerIfNeeded()
        let newRef = try registerHotKey(action: action, shortcut: shortcut)
        if let oldRef = hotKeyRefs[action] { UnregisterEventHotKey(oldRef) }
        hotKeyRefs[action] = newRef
        CaptureHotkeyPreferences.saveShortcut(shortcut, for: action)
        registrationErrors[action] = nil
    }

    private func registerHotKey(action: CaptureHotkeyAction, shortcut: HotkeyShortcut) throws -> EventHotKeyRef {
        guard eventHandlerRef != nil else {
            throw NSError(domain: "Screendrop.Hotkeys", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Keyboard shortcuts could not be initialized. Try reopening Screendrop."
            ])
        }
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: action.hotKeyID)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.modifiers.carbonEventModifiers,
            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "\(shortcut.displayString) could not be registered. It may be used by another app. Choose a different shortcut."
            ])
        }
        return hotKeyRef
    }

    private func unregisterHotkeys() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }

        hotKeyRefs.removeAll()
    }
    
    func handleHotKey(id: UInt32) {
        CaptureHotkeyAction(hotKeyID: id)?.perform()
    }
}

// MARK: - Carbon Event Handler

private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }
    
    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleHotKey(id: hotKeyID.id)
    
    return noErr
}
