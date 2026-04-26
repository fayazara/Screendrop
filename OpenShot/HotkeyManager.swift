//
//  HotkeyManager.swift
//  OpenShot
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit
import Carbon.HIToolbox

/// Registers system-wide global keyboard shortcuts.
///   - Option+1 → Fullscreen
///   - Option+2 → Window
///   - Option+3 → Area
final class HotkeyManager {
    
    static let shared = HotkeyManager()
    
    private var hotKeyRefs: [EventHotKeyRef?] = []
    
    private init() {}
    
    func registerHotkeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            nil
        )
        
        registerHotKey(id: 1, keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey))
        registerHotKey(id: 2, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey))
        registerHotKey(id: 3, keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(optionKey))
    }
    
    private func registerHotKey(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        var hotKeyID = EventHotKeyID(signature: OSType(0x4F53_4854), id: id)
        var hotKeyRef: EventHotKeyRef?
        
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        
        if status == noErr {
            hotKeyRefs.append(hotKeyRef)
        } else {
            print("Failed to register hotkey id=\(id), status=\(status)")
        }
    }
    
    func handleHotKey(id: UInt32) {
        let coordinator = CaptureCoordinator.shared
        switch id {
        case 1: coordinator.captureFullscreen()
        case 2: coordinator.captureWindow()
        case 3: coordinator.captureArea()
        default: break
        }
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
