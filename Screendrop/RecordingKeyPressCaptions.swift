//
//  RecordingKeyPressCaptions.swift
//  Screendrop
//
//  Created by Codex on 09/05/26.
//
//  Renders a Keystroke-Pro style "tray of keycaps" caption while recording:
//  separate translucent grey keycaps for held modifiers (with the symbol on
//  top and the spelled-out word below) and a deep-black trigger keycap with
//  a single white glyph centred. Modifier keycaps stay visible while held;
//  the chord fades out shortly after a trigger key fires or when all
//  modifiers release without one.
//
//  Both the on-screen overlay and the per-frame video bake share a single
//  `KeycapLayoutEngine`, so the live preview matches what gets exported
//  pixel-for-pixel.
//

import AppKit
import CoreText
import CoreVideo
import Foundation
import QuartzCore

// MARK: - Keycap data model

/// A single keycap rendered in the caption tray.
nonisolated struct Keycap: Sendable, Equatable {
    enum Role: Sendable, Equatable {
        case modifier
        case trigger
    }

    enum Kind: Sendable, Equatable {
        case command
        case shift
        case option
        case control
        case function
        case capsLock
        case letter(Character)
        case named(String, glyph: String)
        case fKey(Int)
        case arrow(Arrow)
    }

    enum Arrow: Sendable, Equatable {
        case left, right, up, down
    }

    let role: Role
    let kind: Kind

    /// Symbol shown either at the top of a modifier keycap or as the single
    /// glyph of a trigger keycap.
    var glyph: String {
        switch kind {
        case .command: return "\u{2318}"
        case .shift: return "\u{21E7}"
        case .option: return "\u{2325}"
        case .control: return "\u{2303}"
        case .function: return "fn"
        case .capsLock: return "\u{21EA}"
        case .letter(let character): return String(character).uppercased()
        case .named(_, let glyph): return glyph
        case .fKey(let index): return "F\(index)"
        case .arrow(let direction):
            switch direction {
            case .left: return "\u{2190}"
            case .right: return "\u{2192}"
            case .up: return "\u{2191}"
            case .down: return "\u{2193}"
            }
        }
    }

    /// Spelled-out label rendered below the glyph on modifier keycaps. Trigger
    /// keycaps don't carry a word — only the glyph is shown.
    var word: String? {
        guard role == .modifier else { return nil }
        switch kind {
        case .command: return "command"
        case .shift: return "shift"
        case .option: return "option"
        case .control: return "control"
        case .function: return "fn"
        case .capsLock: return "caps lock"
        default: return nil
        }
    }

    /// Identity key used by the live overlay to keep the same CALayer for the
    /// "same" keycap across re-layouts (so a slide animation can interpolate
    /// the layer's position rather than flashing).
    var identity: String {
        switch kind {
        case .command: return "mod.command"
        case .shift: return "mod.shift"
        case .option: return "mod.option"
        case .control: return "mod.control"
        case .function: return "mod.function"
        case .capsLock: return "mod.capsLock"
        case .letter(let character): return "trig.letter.\(character)"
        case .named(let name, _): return "trig.named.\(name)"
        case .fKey(let index): return "trig.f\(index)"
        case .arrow(let direction): return "trig.arrow.\(direction)"
        }
    }
}

// MARK: - Public types consumed by the writer

nonisolated struct RecordingKeyCaptionMapping: Sendable {
    let captureRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    var pointPixelScale: Double {
        guard captureRect.width > 0 else { return 1 }
        return max(1, Double(CGFloat(pixelWidth) / captureRect.width))
    }
}

nonisolated struct RecordingKeyCaptionAppearance: Sendable {
    // Keycap geometry (point-space; the video renderer multiplies by scale).
    let modifierKeycapSize: CGSize
    let triggerKeycapSize: CGSize
    let keycapCornerRadius: CGFloat
    let keycapSpacing: CGFloat

    // Tray chrome.
    let trayPadding: CGFloat
    let trayCornerRadius: CGFloat
    let trayBottomMargin: CGFloat

    // Typography.
    let modifierGlyphFontSize: CGFloat
    let modifierWordFontSize: CGFloat
    let triggerGlyphFontSize: CGFloat

    static let `default` = RecordingKeyCaptionAppearance(
        modifierKeycapSize: CGSize(width: 90, height: 64),
        triggerKeycapSize: CGSize(width: 72, height: 64),
        keycapCornerRadius: 10,
        keycapSpacing: 6,
        trayPadding: 8,
        trayCornerRadius: 18,
        trayBottomMargin: 56,
        modifierGlyphFontSize: 18,
        modifierWordFontSize: 11,
        triggerGlyphFontSize: 30
    )
}

nonisolated struct RecordingKeyCaptionSnapshot: Sendable {
    let time: TimeInterval
    let appearance: RecordingKeyCaptionAppearance
    let pixelScale: Double
    let keycaps: [Keycap]
    let pressBaseTime: TimeInterval
    let fadeStartTime: TimeInterval?
}

// MARK: - Animation timings

nonisolated private enum RecordingKeyCaptionStyle {
    /// How long a chord stays fully visible after the trigger fires (or after
    /// all modifiers are released without a trigger) before pop-out begins.
    static let postTriggerVisibleDuration: TimeInterval = 0.9
    static let postReleaseVisibleDuration: TimeInterval = 0.4
    static let popInDuration: TimeInterval = 0.18
    static let popOutDuration: TimeInterval = 0.22
    static let slideDuration: CFTimeInterval = 0.16
    static let maximumStoredBlocks = 12
}

nonisolated private struct RecordingKeyCaptionAnimationMetrics: Sendable {
    let scale: CGFloat
    let alpha: CGFloat
}

nonisolated private enum KeycapAnimation {
    static func metrics(
        timeSincePress: TimeInterval,
        timeUntilFadeOut: TimeInterval?
    ) -> RecordingKeyCaptionAnimationMetrics {
        // Fade-out phase.
        if let timeUntilFadeOut, timeUntilFadeOut < 0 {
            let progress = clamp(-timeUntilFadeOut / RecordingKeyCaptionStyle.popOutDuration)
            let eased = easeOutCubic(progress)
            return RecordingKeyCaptionAnimationMetrics(
                scale: 1 - 0.04 * eased,
                alpha: max(0, 1 - eased)
            )
        }

        // Pop-in phase.
        if timeSincePress < RecordingKeyCaptionStyle.popInDuration {
            let progress = clamp(timeSincePress / RecordingKeyCaptionStyle.popInDuration)
            return RecordingKeyCaptionAnimationMetrics(
                scale: springInScale(progress),
                alpha: progress
            )
        }

        return RecordingKeyCaptionAnimationMetrics(scale: 1, alpha: 1)
    }

    private static func clamp(_ value: TimeInterval) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }

    private static func easeOutBack(_ progress: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158
        let c3 = c1 + 1
        let shifted = progress - 1
        return 1 + c3 * shifted * shifted * shifted + c1 * shifted * shifted
    }

    private static func easeOutCubic(_ progress: CGFloat) -> CGFloat {
        1 - pow(1 - progress, 3)
    }

    /// Spring-ish approximation of the live CASpringAnimation so baked video
    /// has the same lively entry instead of a linear scale. This is
    /// deterministic from the recorded frame time, unlike Core Animation.
    private static func springInScale(_ progress: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        let overshoot = sin(clamped * .pi) * 0.08 * (1 - clamped)
        return 0.84 + 0.16 * easeOutBack(clamped) + overshoot
    }
}

// MARK: - Controller

@MainActor
final class RecordingKeyCaptionController {
    static let shared = RecordingKeyCaptionController()

    private let store = RecordingKeyCaptionStore()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var appearance = RecordingKeyCaptionAppearance.default

    /// Tracks the held modifiers so we can build chords that show "while you
    /// hold ⌘ ⇧". Updated on every flagsChanged event.
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var lastModifierFlags: NSEvent.ModifierFlags = []

    /// keyCode -> press uptime, used to suppress duplicate keyUp captions for
    /// already-displayed keyDowns.
    private var lastKeyDownUptimeByKeyCode: [UInt16: TimeInterval] = [:]

    /// Same physical keystroke can arrive from both the CGEventTap and the
    /// NSEvent global monitor. Drop duplicates within `duplicateEventWindow`.
    private var lastProcessedEventTimes: [Int: TimeInterval] = [:]
    private static let duplicateEventWindow: TimeInterval = 0.05

    private init() {}

    func start(mapping: RecordingKeyCaptionMapping) -> RecordingKeyCaptionStore {
        stop()
        let appearance = RecordingKeyCaptionAppearance.default
        self.appearance = appearance
        heldModifiers = []
        lastModifierFlags = []
        lastKeyDownUptimeByKeyCode = [:]
        lastProcessedEventTimes = [:]
        store.start(mapping: mapping, appearance: appearance)
        RecordingKeyCaptionOverlayPresenter.shared.show(mapping: mapping, appearance: appearance)

        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }

        installEventTap()

        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }

        return store
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        eventTap = nil
        runLoopSource = nil
        globalMonitor = nil
        localMonitor = nil
        heldModifiers = []
        lastModifierFlags = []
        lastKeyDownUptimeByKeyCode = [:]
        lastProcessedEventTimes = [:]
        store.stop()
        RecordingKeyCaptionOverlayPresenter.shared.hide()
    }

    func pause() {
        store.pause(at: ProcessInfo.processInfo.systemUptime)
        RecordingKeyCaptionOverlayPresenter.shared.clear()
    }

    func resume() {
        store.resume(at: ProcessInfo.processInfo.systemUptime)
    }

    /// Listen-only session-level CGEventTap. Required to observe Tab and a
    /// few other keys NSEvent's global monitor doesn't reliably deliver.
    private func installEventTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, cgEvent, refcon in
            guard let refcon else { return Unmanaged.passUnretained(cgEvent) }

            let controller = Unmanaged<RecordingKeyCaptionController>
                .fromOpaque(refcon)
                .takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = controller.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(cgEvent)
            }

            if let nsEvent = NSEvent(cgEvent: cgEvent) {
                DispatchQueue.main.async {
                    controller.handle(nsEvent)
                }
            }
            return Unmanaged.passUnretained(cgEvent)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            NSLog("[Screendrop] Could not install key-press event tap. Falling back to NSEvent monitor only.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
    }

    private func handle(_ event: NSEvent) {
        let uptime = event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime

        // Drop tap+monitor duplicates of the same physical keystroke.
        let dedupeKey = Self.duplicateKey(for: event)
        if let lastTime = lastProcessedEventTimes[dedupeKey],
           uptime - lastTime < Self.duplicateEventWindow {
            return
        }

        // Suppress keyUp for a special key whose keyDown was already shown.
        if event.type == .keyUp,
           Self.triggerKeycap(for: event) != nil,
           lastKeyDownUptimeByKeyCode.removeValue(forKey: event.keyCode) != nil {
            lastProcessedEventTimes[dedupeKey] = uptime
            return
        }

        lastProcessedEventTimes[dedupeKey] = uptime

        switch event.type {
        case .flagsChanged:
            let currentFlags = event.modifierFlags.intersection(Self.trackedModifierMask)
            let pressedFlags = currentFlags.subtracting(lastModifierFlags)
            let releasedFlags = lastModifierFlags.subtracting(currentFlags)
            lastModifierFlags = currentFlags

            // Caps Lock toggles in/out — surface as a one-shot trigger event.
            if pressedFlags.contains(.capsLock) || releasedFlags.contains(.capsLock) {
                store.recordTrigger(
                    keycaps: [Keycap(role: .trigger, kind: .capsLock)],
                    uptime: uptime
                )
                RecordingKeyCaptionOverlayPresenter.shared.applyKeycaps(
                    keycaps: [Keycap(role: .trigger, kind: .capsLock)],
                    state: .triggered,
                    uptime: uptime
                )
            }

            // Update held-modifier state and refresh the on-screen building
            // block. The store keeps the block "live" (no fade) until either
            // a trigger key fires or all modifiers release.
            heldModifiers = currentFlags.intersection(Self.displayModifierMask)
            let modifierKeycaps = Self.modifierKeycaps(for: heldModifiers)
            if modifierKeycaps.isEmpty {
                // All modifiers released without a trigger: start the fade.
                store.markBuildingBlockReleased(uptime: uptime)
                RecordingKeyCaptionOverlayPresenter.shared.applyKeycaps(
                    keycaps: [],
                    state: .released,
                    uptime: uptime
                )
            } else {
                store.updateBuildingBlock(
                    keycaps: modifierKeycaps,
                    uptime: uptime
                )
                RecordingKeyCaptionOverlayPresenter.shared.applyKeycaps(
                    keycaps: modifierKeycaps,
                    state: .building,
                    uptime: uptime
                )
            }

        case .keyDown:
            // Skip auto-repeats so a held key doesn't spam the overlay.
            guard !event.isARepeat else { return }
            guard let triggerKeycap = Self.triggerKeycap(for: event) else {
                // Letter / number / punctuation keys without modifiers held
                // are ignored — captions are only useful for special keys
                // and chord shortcuts. With at least one modifier held we
                // *do* want to show the chord, so synthesize a letter/number
                // trigger from the event characters in that case.
                if !heldModifiers.isEmpty,
                   let synthesized = Self.letterTriggerKeycap(for: event) {
                    lastKeyDownUptimeByKeyCode[event.keyCode] = uptime
                    let keycaps = Self.modifierKeycaps(for: heldModifiers) + [synthesized]
                    store.recordTrigger(keycaps: keycaps, uptime: uptime)
                    RecordingKeyCaptionOverlayPresenter.shared.applyKeycaps(
                        keycaps: keycaps,
                        state: .triggered,
                        uptime: uptime
                    )
                }
                return
            }

            lastKeyDownUptimeByKeyCode[event.keyCode] = uptime
            let modifiersForTrigger = Self.effectiveModifiers(
                rawFlags: event.modifierFlags,
                triggerKeyCode: event.keyCode
            )
            let keycaps = Self.modifierKeycaps(for: modifiersForTrigger) + [triggerKeycap]
            store.recordTrigger(keycaps: keycaps, uptime: uptime)
            RecordingKeyCaptionOverlayPresenter.shared.applyKeycaps(
                keycaps: keycaps,
                state: .triggered,
                uptime: uptime
            )

        default:
            break
        }
    }

    // MARK: Static helpers

    private static func duplicateKey(for event: NSEvent) -> Int {
        (Int(event.type.rawValue) << 16) | Int(event.keyCode)
    }

    /// Modifiers we display in the caption tray.
    private static let displayModifierMask: NSEvent.ModifierFlags = [
        .command, .shift, .option, .control, .function
    ]

    /// All modifiers we track (display + capsLock for the toggle event).
    private static let trackedModifierMask: NSEvent.ModifierFlags = [
        .command, .shift, .option, .control, .function, .capsLock
    ]

    /// Apple keyboards report these key codes with `.function` already set
    /// in the event's modifier flags whether or not the user is actually
    /// holding fn. Treat the bit as a hardware artefact for these keys.
    private static let implicitFunctionKeyCodes: Set<UInt16> = [
        // Arrow cluster
        123, 124, 125, 126,
        // Navigation cluster
        115, 116, 117, 119, 121,
        // Function row F1–F19
        96, 97, 98, 99, 100, 101, 103, 105, 106, 107,
        109, 111, 113, 118, 120, 122, 64, 79, 80
    ]

    /// Strip the implicit `.function` bit when the trigger key already
    /// "carries" it as part of the hardware encoding.
    static func effectiveModifiers(
        rawFlags: NSEvent.ModifierFlags,
        triggerKeyCode: UInt16
    ) -> NSEvent.ModifierFlags {
        var modifiers = rawFlags.intersection(displayModifierMask)
        if implicitFunctionKeyCodes.contains(triggerKeyCode) {
            modifiers.remove(.function)
        }
        return modifiers
    }

    /// Modifier keycaps in left-to-right keyboard order.
    static func modifierKeycaps(for modifiers: NSEvent.ModifierFlags) -> [Keycap] {
        var keycaps: [Keycap] = []
        if modifiers.contains(.control) {
            keycaps.append(Keycap(role: .modifier, kind: .control))
        }
        if modifiers.contains(.option) {
            keycaps.append(Keycap(role: .modifier, kind: .option))
        }
        if modifiers.contains(.shift) {
            keycaps.append(Keycap(role: .modifier, kind: .shift))
        }
        if modifiers.contains(.command) {
            keycaps.append(Keycap(role: .modifier, kind: .command))
        }
        if modifiers.contains(.function) {
            keycaps.append(Keycap(role: .modifier, kind: .function))
        }
        return keycaps
    }

    /// Trigger keycap for special keys (Tab, arrows, F-keys, navigation).
    /// Returns nil for letter/number/punctuation keys; those are synthesized
    /// only when a modifier is held (so plain typing isn't displayed).
    private static func triggerKeycap(for event: NSEvent) -> Keycap? {
        switch event.keyCode {
        case 36: return Keycap(role: .trigger, kind: .named("Return", glyph: "\u{23CE}"))
        case 48: return Keycap(role: .trigger, kind: .named("Tab", glyph: "\u{21E5}"))
        case 49: return Keycap(role: .trigger, kind: .named("Space", glyph: "\u{2423}"))
        case 51: return Keycap(role: .trigger, kind: .named("Delete", glyph: "\u{232B}"))
        case 53: return Keycap(role: .trigger, kind: .named("Esc", glyph: "esc"))
        case 71: return Keycap(role: .trigger, kind: .named("Clear", glyph: "clear"))
        case 76: return Keycap(role: .trigger, kind: .named("Enter", glyph: "\u{2305}"))
        case 115: return Keycap(role: .trigger, kind: .named("Home", glyph: "\u{2196}"))
        case 116: return Keycap(role: .trigger, kind: .named("Page Up", glyph: "\u{21DE}"))
        case 117: return Keycap(role: .trigger, kind: .named("Forward Delete", glyph: "\u{2326}"))
        case 119: return Keycap(role: .trigger, kind: .named("End", glyph: "\u{2198}"))
        case 121: return Keycap(role: .trigger, kind: .named("Page Down", glyph: "\u{21DF}"))
        case 123: return Keycap(role: .trigger, kind: .arrow(.left))
        case 124: return Keycap(role: .trigger, kind: .arrow(.right))
        case 125: return Keycap(role: .trigger, kind: .arrow(.down))
        case 126: return Keycap(role: .trigger, kind: .arrow(.up))
        case 122: return Keycap(role: .trigger, kind: .fKey(1))
        case 120: return Keycap(role: .trigger, kind: .fKey(2))
        case 99:  return Keycap(role: .trigger, kind: .fKey(3))
        case 118: return Keycap(role: .trigger, kind: .fKey(4))
        case 96:  return Keycap(role: .trigger, kind: .fKey(5))
        case 97:  return Keycap(role: .trigger, kind: .fKey(6))
        case 98:  return Keycap(role: .trigger, kind: .fKey(7))
        case 100: return Keycap(role: .trigger, kind: .fKey(8))
        case 101: return Keycap(role: .trigger, kind: .fKey(9))
        case 109: return Keycap(role: .trigger, kind: .fKey(10))
        case 103: return Keycap(role: .trigger, kind: .fKey(11))
        case 111: return Keycap(role: .trigger, kind: .fKey(12))
        case 105: return Keycap(role: .trigger, kind: .fKey(13))
        case 107: return Keycap(role: .trigger, kind: .fKey(14))
        case 113: return Keycap(role: .trigger, kind: .fKey(15))
        case 106: return Keycap(role: .trigger, kind: .fKey(16))
        case 64:  return Keycap(role: .trigger, kind: .fKey(17))
        case 79:  return Keycap(role: .trigger, kind: .fKey(18))
        case 80:  return Keycap(role: .trigger, kind: .fKey(19))
        default: return nil
        }
    }

    /// Letter / number / punctuation trigger built from the event's typed
    /// characters. Used when a modifier is held so chord shortcuts like ⌘C
    /// can be rendered, but plain typing without modifiers stays silent.
    private static func letterTriggerKeycap(for event: NSEvent) -> Keycap? {
        guard let raw = event.charactersIgnoringModifiers,
              let first = raw.first,
              !first.isWhitespace,
              !first.isNewline else {
            return nil
        }
        return Keycap(role: .trigger, kind: .letter(first))
    }
}

// MARK: - Store

nonisolated final class RecordingKeyCaptionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var mapping: RecordingKeyCaptionMapping?
    private var appearance = RecordingKeyCaptionAppearance.default
    private var pixelScale: Double = 1
    private var startUptime: TimeInterval = 0
    private var pauseStartedUptime: TimeInterval?
    private var accumulatedPauseDuration: TimeInterval = 0
    private var blocks: [Block] = []

    /// A live block represents a chord that's either currently being built
    /// (modifiers held, no trigger yet) or has been triggered/released and is
    /// fading out. `fadeStartUptime` is the moment its visible window ends —
    /// nil means "stay alive forever" (still being built).
    private struct Block {
        var keycaps: [Keycap]
        let pressBaseUptime: TimeInterval
        var fadeStartUptime: TimeInterval?
        var isBuilding: Bool

        var fadeEndUptime: TimeInterval? {
            guard let fadeStartUptime else { return nil }
            return fadeStartUptime + RecordingKeyCaptionStyle.popOutDuration
        }
    }

    func start(mapping: RecordingKeyCaptionMapping, appearance: RecordingKeyCaptionAppearance) {
        lock.withLock {
            self.mapping = mapping
            self.appearance = appearance
            pixelScale = mapping.pointPixelScale
            startUptime = ProcessInfo.processInfo.systemUptime
            pauseStartedUptime = nil
            accumulatedPauseDuration = 0
            blocks = []
        }
    }

    func stop() {
        lock.withLock {
            mapping = nil
            appearance = .default
            pixelScale = 1
            pauseStartedUptime = nil
            accumulatedPauseDuration = 0
            blocks = []
        }
    }

    func pause(at uptime: TimeInterval) {
        lock.withLock {
            guard pauseStartedUptime == nil else { return }
            pauseStartedUptime = uptime
        }
    }

    func resume(at uptime: TimeInterval) {
        lock.withLock {
            guard let pauseStartedUptime else { return }
            accumulatedPauseDuration += max(0, uptime - pauseStartedUptime)
            self.pauseStartedUptime = nil
        }
    }

    /// Update or create the "currently building" block — modifiers are held
    /// but no trigger has fired yet. Block stays visible until released or
    /// triggered.
    func updateBuildingBlock(keycaps: [Keycap], uptime: TimeInterval) {
        lock.withLock {
            guard pauseStartedUptime == nil, mapping != nil else { return }

            if let lastIndex = blocks.indices.last,
               blocks[lastIndex].isBuilding,
               blocks[lastIndex].fadeStartUptime == nil {
                blocks[lastIndex].keycaps = keycaps
            } else {
                blocks.append(Block(
                    keycaps: keycaps,
                    pressBaseUptime: uptime,
                    fadeStartUptime: nil,
                    isBuilding: true
                ))
                trimIfNeeded()
            }
        }
    }

    /// All modifiers released without a trigger key. The currently-building
    /// block (if any) starts its short fade.
    func markBuildingBlockReleased(uptime: TimeInterval) {
        lock.withLock {
            guard pauseStartedUptime == nil else { return }
            guard let lastIndex = blocks.indices.last,
                  blocks[lastIndex].isBuilding,
                  blocks[lastIndex].fadeStartUptime == nil else {
                return
            }
            blocks[lastIndex].fadeStartUptime = uptime + RecordingKeyCaptionStyle.postReleaseVisibleDuration
            blocks[lastIndex].isBuilding = false
        }
    }

    /// A trigger key fired. Replace the building block (if any) with this
    /// final chord and start its fade timer; otherwise create a fresh block.
    func recordTrigger(keycaps: [Keycap], uptime: TimeInterval) {
        lock.withLock {
            guard pauseStartedUptime == nil, mapping != nil else { return }

            let fadeStart = uptime + RecordingKeyCaptionStyle.postTriggerVisibleDuration

            if let lastIndex = blocks.indices.last,
               blocks[lastIndex].isBuilding,
               blocks[lastIndex].fadeStartUptime == nil {
                blocks[lastIndex].keycaps = keycaps
                blocks[lastIndex].fadeStartUptime = fadeStart
                blocks[lastIndex].isBuilding = false
            } else {
                blocks.append(Block(
                    keycaps: keycaps,
                    pressBaseUptime: uptime,
                    fadeStartUptime: fadeStart,
                    isBuilding: false
                ))
                trimIfNeeded()
            }
        }
    }

    func snapshot(at time: TimeInterval) -> RecordingKeyCaptionSnapshot? {
        lock.withLock {
            guard let mapping else { return nil }
            let absoluteTime = absoluteUptime(forRelative: time)
            prune(beforeUptime: absoluteTime)

            // Find the most recent block whose visible window includes this
            // time. A live block (no fadeStartUptime) is always visible.
            guard let block = blocks.last(where: { block in
                if let fadeEnd = block.fadeEndUptime {
                    return absoluteTime >= block.pressBaseUptime - 0.05
                        && absoluteTime <= fadeEnd
                }
                return absoluteTime >= block.pressBaseUptime - 0.05
            }) else {
                return nil
            }

            _ = mapping // captured guard above; suppresses unused-binding warning
            return RecordingKeyCaptionSnapshot(
                time: time,
                appearance: appearance,
                pixelScale: pixelScale,
                keycaps: block.keycaps,
                pressBaseTime: relativeTime(forAbsoluteUptime: block.pressBaseUptime),
                fadeStartTime: block.fadeStartUptime.map(relativeTime(forAbsoluteUptime:))
            )
        }
    }

    private func absoluteUptime(forRelative time: TimeInterval) -> TimeInterval {
        startUptime + accumulatedPauseDuration + time
    }

    private func relativeTime(forAbsoluteUptime uptime: TimeInterval) -> TimeInterval {
        max(0, uptime - startUptime - accumulatedPauseDuration)
    }

    private func prune(beforeUptime uptime: TimeInterval) {
        blocks.removeAll { block in
            guard let fadeEnd = block.fadeEndUptime else { return false }
            return uptime > fadeEnd + 0.5
        }
    }

    private func trimIfNeeded() {
        if blocks.count > RecordingKeyCaptionStyle.maximumStoredBlocks {
            blocks.removeFirst(blocks.count - RecordingKeyCaptionStyle.maximumStoredBlocks)
        }
    }
}

// MARK: - Layout

nonisolated struct KeycapLayout: Sendable {
    let trayRect: CGRect
    let keycapFrames: [CGRect]
    let glyphFontSize: CGFloat
    let wordFontSize: CGFloat
    let triggerFontSize: CGFloat
    let scale: CGFloat
}

nonisolated enum KeycapLayoutEngine {
    static func layout(
        keycaps: [Keycap],
        appearance: RecordingKeyCaptionAppearance,
        canvasWidth: CGFloat,
        bottom: CGFloat,
        scale: CGFloat
    ) -> KeycapLayout {
        let modifierSize = CGSize(
            width: appearance.modifierKeycapSize.width * scale,
            height: appearance.modifierKeycapSize.height * scale
        )
        let triggerSize = CGSize(
            width: appearance.triggerKeycapSize.width * scale,
            height: appearance.triggerKeycapSize.height * scale
        )
        let spacing = appearance.keycapSpacing * scale
        let trayPadding = appearance.trayPadding * scale

        // Measure each keycap.
        var keycapSizes: [CGSize] = []
        keycapSizes.reserveCapacity(keycaps.count)
        for keycap in keycaps {
            keycapSizes.append(keycap.role == .modifier ? modifierSize : triggerSize)
        }

        let totalKeycapWidth = keycapSizes.reduce(into: CGFloat(0)) { $0 += $1.width }
        let totalSpacing = max(0, CGFloat(keycaps.count - 1)) * spacing
        let trayHeight = (keycapSizes.map(\.height).max() ?? 0) + trayPadding * 2

        // Shrink horizontally if the tray would overflow the canvas.
        let maxTrayWidth = max(120 * scale, canvasWidth - 48 * scale)
        var keycapWidths = keycapSizes.map(\.width)
        var trayContentWidth = totalKeycapWidth + totalSpacing
        var trayWidth = trayContentWidth + trayPadding * 2

        if trayWidth > maxTrayWidth {
            let shrink = max(0.6, (maxTrayWidth - trayPadding * 2 - totalSpacing) / max(1, totalKeycapWidth))
            keycapWidths = keycapWidths.map { $0 * shrink }
            trayContentWidth = keycapWidths.reduce(0, +) + totalSpacing
            trayWidth = trayContentWidth + trayPadding * 2
        }

        let trayOriginX = (canvasWidth - trayWidth) / 2
        let trayOriginY = bottom - trayHeight
        let trayRect = CGRect(x: trayOriginX, y: trayOriginY, width: trayWidth, height: trayHeight)

        var frames: [CGRect] = []
        frames.reserveCapacity(keycaps.count)
        var cursor = trayOriginX + trayPadding
        for index in keycaps.indices {
            let size = CGSize(width: keycapWidths[index], height: keycapSizes[index].height)
            let originY = trayOriginY + (trayHeight - size.height) / 2
            frames.append(CGRect(x: cursor, y: originY, width: size.width, height: size.height))
            cursor += size.width + spacing
        }

        return KeycapLayout(
            trayRect: trayRect,
            keycapFrames: frames,
            glyphFontSize: appearance.modifierGlyphFontSize * scale,
            wordFontSize: appearance.modifierWordFontSize * scale,
            triggerFontSize: appearance.triggerGlyphFontSize * scale,
            scale: scale
        )
    }
}

// MARK: - Live overlay (CALayer based)

@MainActor
private final class RecordingKeyCaptionOverlayPresenter {
    static let shared = RecordingKeyCaptionOverlayPresenter()

    private var panel: NSPanel?
    private var overlayView: KeycapOverlayView?

    private init() {}

    func show(mapping: RecordingKeyCaptionMapping, appearance: RecordingKeyCaptionAppearance) {
        hide()

        guard mapping.captureRect.width > 0,
              mapping.captureRect.height > 0 else {
            return
        }

        let panel = NSPanel(
            contentRect: mapping.captureRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none

        let overlayView = KeycapOverlayView(
            frame: CGRect(origin: .zero, size: mapping.captureRect.size),
            appearance: appearance
        )
        panel.contentView = overlayView
        panel.orderFrontRegardless()

        self.panel = panel
        self.overlayView = overlayView
    }

    func hide() {
        overlayView?.clear(animated: false)
        overlayView = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func clear() {
        overlayView?.clear(animated: false)
    }

    enum BlockState {
        case building
        case triggered
        case released
    }

    func applyKeycaps(keycaps: [Keycap], state: BlockState, uptime: TimeInterval) {
        overlayView?.apply(keycaps: keycaps, state: state, uptime: uptime)
    }
}

@MainActor
private final class KeycapOverlayView: NSView {
    private let captionAppearance: RecordingKeyCaptionAppearance
    private let trayLayer = CALayer()
    private var trayShadowApplied = false
    private var keycapLayers: [String: KeycapHostLayer] = [:]
    /// Order of keycap identities currently composed into the tray. Drives
    /// horizontal slide animations when the order changes.
    private var orderedIdentities: [String] = []
    private var fadeOutWorkItem: DispatchWorkItem?

    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect, appearance: RecordingKeyCaptionAppearance) {
        self.captionAppearance = appearance
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        trayLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        trayLayer.opacity = 0
        layer?.addSublayer(trayLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        trayLayer.contentsScale = scale
        for hostLayer in keycapLayers.values {
            hostLayer.updateContentsScale(scale)
        }
    }

    func apply(
        keycaps: [Keycap],
        state: RecordingKeyCaptionOverlayPresenter.BlockState,
        uptime: TimeInterval
    ) {
        fadeOutWorkItem?.cancel()
        fadeOutWorkItem = nil

        if keycaps.isEmpty {
            scheduleFadeOut(after: state == .released
                ? RecordingKeyCaptionStyle.postReleaseVisibleDuration
                : RecordingKeyCaptionStyle.postTriggerVisibleDuration)
            return
        }

        let layout = KeycapLayoutEngine.layout(
            keycaps: keycaps,
            appearance: captionAppearance,
            canvasWidth: bounds.width,
            bottom: bounds.height - captionAppearance.trayBottomMargin,
            scale: 1
        )

        // Was the tray hidden a moment ago? If so, this is a fresh "press"
        // and we want the tray to spring in from its own centre — not slide
        // from its previous (or zero) frame.
        let trayWasHidden = trayLayer.opacity < 0.01

        if trayWasHidden {
            // Snap the tray to its final geometry without an implicit
            // position/bounds animation, so the spring pop-in scales from
            // the correct centre.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            trayLayer.frame = layout.trayRect
            styleTray(trayLayer, cornerRadius: captionAppearance.trayCornerRadius)
            CATransaction.commit()

            runTrayPopIn()
        } else {
            // Tray is already visible — let it slide between layouts.
            CATransaction.begin()
            CATransaction.setAnimationDuration(RecordingKeyCaptionStyle.slideDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            trayLayer.frame = layout.trayRect
            styleTray(trayLayer, cornerRadius: captionAppearance.trayCornerRadius)
            CATransaction.commit()
        }

        // Wrap keycap layout updates in a slide-animation transaction.
        CATransaction.begin()
        CATransaction.setAnimationDuration(RecordingKeyCaptionStyle.slideDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))

        // Diff keycap layers.
        var newIdentities: [String] = []
        newIdentities.reserveCapacity(keycaps.count)

        for (index, keycap) in keycaps.enumerated() {
            let identity = keycap.identity
            newIdentities.append(identity)

            let frame = layout.keycapFrames[index]
            let isNew = keycapLayers[identity] == nil
            let host: KeycapHostLayer
            if let existing = keycapLayers[identity] {
                host = existing
            } else {
                host = KeycapHostLayer()
                host.contentsScale = trayLayer.contentsScale
                layer?.addSublayer(host)
                keycapLayers[identity] = host
            }

            // For brand-new keycaps, snap to the target frame without an
            // implicit slide so the spring pop-in scales from the correct
            // centre rather than sliding in from the layer's old origin.
            if isNew {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                host.configure(
                    keycap: keycap,
                    frame: frame,
                    glyphFontSize: layout.glyphFontSize,
                    wordFontSize: layout.wordFontSize,
                    triggerFontSize: layout.triggerFontSize,
                    cornerRadius: captionAppearance.keycapCornerRadius * layout.scale
                )
                CATransaction.commit()
                host.runPopIn()
            } else {
                host.configure(
                    keycap: keycap,
                    frame: frame,
                    glyphFontSize: layout.glyphFontSize,
                    wordFontSize: layout.wordFontSize,
                    triggerFontSize: layout.triggerFontSize,
                    cornerRadius: captionAppearance.keycapCornerRadius * layout.scale
                )
            }
        }

        // Remove keycaps that are no longer part of the chord.
        for (identity, host) in keycapLayers where !newIdentities.contains(identity) {
            host.runPopOut { [weak self] in
                guard let self else { return }
                if self.keycapLayers[identity] === host {
                    host.removeFromSuperlayer()
                    self.keycapLayers.removeValue(forKey: identity)
                }
            }
        }

        orderedIdentities = newIdentities

        CATransaction.commit()

        if state == .triggered {
            scheduleFadeOut(after: RecordingKeyCaptionStyle.postTriggerVisibleDuration)
        }
    }

    func clear(animated: Bool) {
        fadeOutWorkItem?.cancel()
        fadeOutWorkItem = nil

        if animated {
            scheduleFadeOut(after: 0)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for host in keycapLayers.values {
                host.removeFromSuperlayer()
            }
            keycapLayers.removeAll()
            orderedIdentities.removeAll()
            trayLayer.opacity = 0
            CATransaction.commit()
        }
    }

    private func scheduleFadeOut(after delay: TimeInterval) {
        fadeOutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.runFadeOut()
            }
        }
        fadeOutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    /// Springy entry for the tray. Scales from ~0.86 → 1 with a soft bounce
    /// while fading opacity in. Layout is already final at this point so we
    /// only animate transform.scale + opacity (anchored at the layer
    /// centre).
    private func runTrayPopIn() {
        // Clear any in-flight pop-out animations from a previous fade so
        // they don't fight or override the new pop-in. Snap the model
        // opacity to 1 without an implicit transition.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trayLayer.removeAnimation(forKey: "trayPopOut.scale")
        trayLayer.removeAnimation(forKey: "trayPopOut.opacity")
        trayLayer.removeAnimation(forKey: "trayPopIn.scale")
        trayLayer.removeAnimation(forKey: "trayPopIn.opacity")
        trayLayer.opacity = 1
        trayLayer.transform = CATransform3DIdentity
        CATransaction.commit()

        let scaleSpring = CASpringAnimation(keyPath: "transform.scale")
        scaleSpring.fromValue = 0.86
        scaleSpring.toValue = 1
        scaleSpring.damping = 12
        scaleSpring.mass = 1
        scaleSpring.stiffness = 220
        scaleSpring.initialVelocity = 6
        scaleSpring.duration = scaleSpring.settlingDuration

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = RecordingKeyCaptionStyle.popInDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        trayLayer.add(scaleSpring, forKey: "trayPopIn.scale")
        trayLayer.add(fade, forKey: "trayPopIn.opacity")
    }

    private func runFadeOut() {
        // Springy pop-out for the tray: shrinks slightly while fading.
        // Persist the final opacity on the model layer first so the
        // explicit animations have a clean toValue match. Don't use
        // isRemovedOnCompletion = false — that traps the layer in a
        // permanently-hidden state and breaks the next pop-in.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trayLayer.opacity = 0
        CATransaction.commit()

        let scaleSpring = CASpringAnimation(keyPath: "transform.scale")
        scaleSpring.fromValue = (trayLayer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        scaleSpring.toValue = 0.92
        scaleSpring.damping = 14
        scaleSpring.mass = 1
        scaleSpring.stiffness = 200
        scaleSpring.initialVelocity = -4
        scaleSpring.duration = scaleSpring.settlingDuration

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = (trayLayer.presentation()?.opacity).map(CGFloat.init) ?? 1
        fade.toValue = 0
        fade.duration = RecordingKeyCaptionStyle.popOutDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        trayLayer.add(scaleSpring, forKey: "trayPopOut.scale")
        trayLayer.add(fade, forKey: "trayPopOut.opacity")

        for host in keycapLayers.values {
            host.runPopOut(completion: nil)
        }

        let cleanup = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for host in self.keycapLayers.values {
                    host.removeFromSuperlayer()
                }
                self.keycapLayers.removeAll()
                self.orderedIdentities.removeAll()
                // Reset the tray's transform so the next pop-in starts from
                // identity rather than the 0.92 we shrunk to.
                self.trayLayer.removeAnimation(forKey: "trayPopOut.scale")
                self.trayLayer.removeAnimation(forKey: "trayPopOut.opacity")
                self.trayLayer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + RecordingKeyCaptionStyle.popOutDuration + 0.1,
            execute: cleanup
        )
    }

    private func styleTray(_ layer: CALayer, cornerRadius: CGFloat) {
        layer.backgroundColor = NSColor(white: 0.06, alpha: 0.72).cgColor
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer.borderWidth = 1
        layer.masksToBounds = false

        if !trayShadowApplied {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.35
            layer.shadowRadius = 16
            layer.shadowOffset = CGSize(width: 0, height: -4)
            trayShadowApplied = true
        }
    }
}

@MainActor
private final class KeycapHostLayer: CALayer {
    private let bodyLayer = CALayer()
    private let highlightLayer = CALayer()
    private let glyphLayer = CATextLayer()
    private let wordLayer = CATextLayer()
    private var currentRole: Keycap.Role = .modifier

    override init() {
        super.init()
        glyphLayer.alignmentMode = .center
        glyphLayer.foregroundColor = NSColor.white.cgColor
        glyphLayer.contentsScale = 2
        glyphLayer.allowsFontSubpixelQuantization = true

        wordLayer.alignmentMode = .center
        wordLayer.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        wordLayer.contentsScale = 2

        addSublayer(bodyLayer)
        addSublayer(highlightLayer)
        addSublayer(glyphLayer)
        addSublayer(wordLayer)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    func updateContentsScale(_ scale: CGFloat) {
        contentsScale = scale
        bodyLayer.contentsScale = scale
        highlightLayer.contentsScale = scale
        glyphLayer.contentsScale = scale
        wordLayer.contentsScale = scale
    }

    func configure(
        keycap: Keycap,
        frame: CGRect,
        glyphFontSize: CGFloat,
        wordFontSize: CGFloat,
        triggerFontSize: CGFloat,
        cornerRadius: CGFloat
    ) {
        currentRole = keycap.role
        self.frame = frame

        bodyLayer.frame = bounds
        bodyLayer.cornerRadius = cornerRadius
        bodyLayer.cornerCurve = .continuous
        bodyLayer.masksToBounds = true

        highlightLayer.cornerRadius = cornerRadius
        highlightLayer.cornerCurve = .continuous
        highlightLayer.masksToBounds = true
        highlightLayer.frame = CGRect(x: 0, y: 0, width: frame.width, height: max(2, frame.height * 0.45))

        // All keycaps share the same dark body — modifier vs trigger is
        // differentiated only by content (two-line glyph + word vs single
        // centred glyph), never by colour.
        bodyLayer.backgroundColor = NSColor(white: 0.10, alpha: 0.92).cgColor
        highlightLayer.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        glyphLayer.foregroundColor = NSColor.white.cgColor
        if keycap.role == .modifier {
            wordLayer.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        }

        // Multi-character trigger glyphs ("esc", "clear", "F12") need a
        // smaller font so they don't visually dwarf single-character ones
        // like "X" or "←".
        let effectiveTriggerFontSize: CGFloat = {
            guard keycap.role == .trigger else { return triggerFontSize }
            return Self.triggerFontSize(for: keycap.glyph, baseSize: triggerFontSize)
        }()

        let glyphFont = Self.roundedFont(
            size: keycap.role == .trigger ? effectiveTriggerFontSize : glyphFontSize,
            weight: keycap.role == .trigger ? .semibold : .medium
        )
        glyphLayer.font = glyphFont
        glyphLayer.fontSize = keycap.role == .trigger ? effectiveTriggerFontSize : glyphFontSize
        glyphLayer.string = keycap.glyph

        if keycap.role == .modifier {
            // Two-line layout: glyph in the upper third, word in the lower third.
            let glyphHeight = glyphFontSize * 1.4
            glyphLayer.frame = CGRect(
                x: 0,
                y: frame.height * 0.18,
                width: frame.width,
                height: glyphHeight
            )

            let wordFont = Self.compactFont(size: wordFontSize, weight: .medium)
            wordLayer.font = wordFont
            wordLayer.fontSize = wordFontSize
            wordLayer.string = keycap.word ?? ""
            let wordHeight = wordFontSize * 1.4
            wordLayer.frame = CGRect(
                x: 0,
                y: frame.height - wordHeight - frame.height * 0.10,
                width: frame.width,
                height: wordHeight
            )
            wordLayer.isHidden = false
        } else {
            // Trigger: single glyph centred. Use the effective (possibly
            // shrunk) font size so multi-char labels like "esc" are sized
            // correctly.
            let glyphHeight = effectiveTriggerFontSize * 1.3
            glyphLayer.frame = CGRect(
                x: 0,
                y: (frame.height - glyphHeight) / 2,
                width: frame.width,
                height: glyphHeight
            )
            wordLayer.isHidden = true
        }
    }

    /// Multi-character trigger labels ("esc", "clear", "F12") need to render
    /// smaller than single-glyph triggers ("X", "←") so they don't overflow
    /// the keycap or visually overpower neighbouring keys.
    static func triggerFontSize(for glyph: String, baseSize: CGFloat) -> CGFloat {
        switch glyph.count {
        case 0, 1: return baseSize
        case 2: return baseSize * 0.62
        default: return baseSize * 0.52
        }
    }

    func runPopIn() {
        let scaleSpring = CASpringAnimation(keyPath: "transform.scale")
        scaleSpring.fromValue = 0.84
        scaleSpring.toValue = 1
        scaleSpring.damping = 13
        scaleSpring.mass = 1
        scaleSpring.stiffness = 240
        scaleSpring.initialVelocity = 6
        scaleSpring.duration = scaleSpring.settlingDuration
        scaleSpring.fillMode = .both

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = RecordingKeyCaptionStyle.popInDuration
        opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)
        opacity.fillMode = .both

        add(scaleSpring, forKey: "popIn.scale")
        add(opacity, forKey: "popIn.opacity")
    }

    func runPopOut(completion: (() -> Void)?) {
        // Persist the target opacity on the model first so the implicit
        // CALayer presentation matches once the explicit animation removes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opacity = 0
        CATransaction.commit()

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = (presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        scale.toValue = 0.92
        scale.duration = RecordingKeyCaptionStyle.popOutDuration
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = (presentation()?.opacity).map(CGFloat.init) ?? 1
        opacityAnim.toValue = 0
        opacityAnim.duration = RecordingKeyCaptionStyle.popOutDuration
        opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            completion?()
        }
        add(scale, forKey: "popOut.scale")
        add(opacityAnim, forKey: "popOut.opacity")
        CATransaction.commit()
    }

    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> CTFont {
        let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        let rounded = descriptor.withDesign(.rounded) ?? descriptor
        return CTFontCreateWithFontDescriptor(rounded as CTFontDescriptor, size, nil)
    }

    private static func compactFont(size: CGFloat, weight: NSFont.Weight) -> CTFont {
        // SF Compact isn't always available via NSFont API; fall back to
        // system rounded for a similarly clean look on macOS Tahoe.
        let descriptor: NSFontDescriptor
        if let compactFont = NSFont(name: "SFCompactDisplay-Medium", size: size) {
            descriptor = compactFont.fontDescriptor
        } else {
            descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        }
        return CTFontCreateWithFontDescriptor(descriptor as CTFontDescriptor, size, nil)
    }
}

// MARK: - Video bake renderer

nonisolated enum RecordingKeyCaptionRenderer {
    static func render(snapshot: RecordingKeyCaptionSnapshot, into pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              !snapshot.keycaps.isEmpty else {
            return
        }

        let lockFlags = CVPixelBufferLockFlags(rawValue: 0)
        guard CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, lockFlags) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return
        }

        // Flip into top-left origin so coordinates align with the live overlay.
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let scale = CGFloat(snapshot.pixelScale)
        let bottom = CGFloat(height) - snapshot.appearance.trayBottomMargin * scale

        let layout = KeycapLayoutEngine.layout(
            keycaps: snapshot.keycaps,
            appearance: snapshot.appearance,
            canvasWidth: CGFloat(width),
            bottom: bottom,
            scale: scale
        )

        // Animation state must be derived from the recorded frame timestamp,
        // not wall-clock time during export. Otherwise the baked video loses
        // the spring/fade state after recording stops.
        let timeSincePress = max(0, snapshot.time - snapshot.pressBaseTime)
        let timeUntilFadeOut = snapshot.fadeStartTime.map { $0 - snapshot.time }
        let metrics = KeycapAnimation.metrics(
            timeSincePress: timeSincePress,
            timeUntilFadeOut: timeUntilFadeOut
        )

        guard metrics.alpha > 0.01, metrics.scale > 0.01 else {
            context.restoreGState()
            return
        }

        // Pop-in/out scale around the tray centre for the whole composition.
        context.saveGState()
        context.translateBy(x: layout.trayRect.midX, y: layout.trayRect.midY)
        context.scaleBy(x: metrics.scale, y: metrics.scale)
        context.translateBy(x: -layout.trayRect.midX, y: -layout.trayRect.midY)

        // Tray.
        drawTray(layout.trayRect, cornerRadius: snapshot.appearance.trayCornerRadius * scale, alpha: metrics.alpha, context: context)

        // Keycaps.
        for (index, keycap) in snapshot.keycaps.enumerated() {
            let frame = layout.keycapFrames[index]
            drawKeycap(
                keycap,
                frame: frame,
                cornerRadius: snapshot.appearance.keycapCornerRadius * scale,
                glyphFontSize: layout.glyphFontSize,
                wordFontSize: layout.wordFontSize,
                triggerFontSize: layout.triggerFontSize,
                alpha: metrics.alpha,
                context: context
            )
        }

        context.restoreGState()
        context.restoreGState()
    }

    private static func drawTray(
        _ rect: CGRect,
        cornerRadius: CGFloat,
        alpha: CGFloat,
        context: CGContext
    ) {
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0.06, alpha: 0.72 * alpha))
        context.fillPath()

        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.14 * alpha))
        context.setLineWidth(max(1, cornerRadius * 0.06))
        context.strokePath()
    }

    private static func drawKeycap(
        _ keycap: Keycap,
        frame: CGRect,
        cornerRadius: CGFloat,
        glyphFontSize: CGFloat,
        wordFontSize: CGFloat,
        triggerFontSize: CGFloat,
        alpha: CGFloat,
        context: CGContext
    ) {
        let bodyPath = CGPath(
            roundedRect: frame,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.addPath(bodyPath)
        // All keycaps share the same dark body. Modifier vs trigger is
        // differentiated only by content (two-line glyph + word vs single
        // centred glyph), never by colour.
        context.setFillColor(CGColor(gray: 0.10, alpha: 0.92 * alpha))
        context.fillPath()

        // Subtle top highlight.
        let highlightHeight = frame.height * 0.45
        let highlightRect = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: highlightHeight)
        context.saveGState()
        context.addPath(CGPath(
            roundedRect: highlightRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        ))
        context.clip()
        context.setFillColor(CGColor(gray: 1, alpha: 0.05 * alpha))
        context.fill(highlightRect)
        context.restoreGState()

        switch keycap.role {
        case .modifier:
            // Glyph (top) + word (bottom).
            let glyphFont = roundedFont(size: glyphFontSize, weight: .medium)
            drawText(
                keycap.glyph,
                font: glyphFont,
                in: CGRect(
                    x: frame.minX,
                    y: frame.minY + frame.height * 0.18,
                    width: frame.width,
                    height: glyphFontSize * 1.4
                ),
                color: CGColor(gray: 1, alpha: alpha),
                context: context
            )

            if let word = keycap.word {
                let wordFont = compactFont(size: wordFontSize, weight: .medium)
                drawText(
                    word,
                    font: wordFont,
                    in: CGRect(
                        x: frame.minX,
                        y: frame.maxY - wordFontSize * 1.4 - frame.height * 0.10,
                        width: frame.width,
                        height: wordFontSize * 1.4
                    ),
                    color: CGColor(gray: 1, alpha: 0.92 * alpha),
                    context: context
                )
            }

        case .trigger:
            let effectiveSize = effectiveTriggerSize(for: keycap.glyph, baseSize: triggerFontSize)
            let glyphFont = roundedFont(size: effectiveSize, weight: .semibold)
            let glyphHeight = effectiveSize * 1.3
            drawText(
                keycap.glyph,
                font: glyphFont,
                in: CGRect(
                    x: frame.minX,
                    y: frame.midY - glyphHeight / 2,
                    width: frame.width,
                    height: glyphHeight
                ),
                color: CGColor(gray: 1, alpha: alpha),
                context: context
            )
        }
    }

    private static func drawText(
        _ text: String,
        font: CTFont,
        in rect: CGRect,
        color: CGColor,
        context: CGContext
    ) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        guard let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault,
            text as CFString,
            attributes as CFDictionary
        ) else {
            return
        }
        let line = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let textX = rect.minX + (rect.width - textWidth) / 2
        let textHeight = ascent + descent
        let topY = rect.minY + (rect.height - textHeight) / 2
        let baselineY = topY + ascent

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: textX, y: baselineY)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> CTFont {
        let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        let rounded = descriptor.withDesign(.rounded) ?? descriptor
        return CTFontCreateWithFontDescriptor(rounded as CTFontDescriptor, size, nil)
    }

    private static func compactFont(size: CGFloat, weight: NSFont.Weight) -> CTFont {
        let descriptor: NSFontDescriptor
        if let compactFont = NSFont(name: "SFCompactDisplay-Medium", size: size) {
            descriptor = compactFont.fontDescriptor
        } else {
            descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        }
        return CTFontCreateWithFontDescriptor(descriptor as CTFontDescriptor, size, nil)
    }

    /// Mirrors `KeycapHostLayer.triggerFontSize(for:baseSize:)` so the video
    /// bake matches the live overlay's down-sizing of multi-character trigger
    /// labels like "esc" or "F12".
    private static func effectiveTriggerSize(for glyph: String, baseSize: CGFloat) -> CGFloat {
        switch glyph.count {
        case 0, 1: return baseSize
        case 2: return baseSize * 0.62
        default: return baseSize * 0.52
        }
    }
}
