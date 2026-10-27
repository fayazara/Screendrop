//
//  RecentCapturesStripPresenter.swift
//  Screendrop
//  Contributed by Rochak Agrawal (Screenshot X).
//
//  The compact recent-captures strip behind ⇧⌘L: a narrow vertical filmstrip
//  of the newest screenshots on the right edge. Arrow keys move the selection,
//  Return pins the selected image and closes the strip, Escape dismisses it.
//

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

@MainActor
@Observable
final class RecentCapturesStripModel {
    static let shared = RecentCapturesStripModel()

    private(set) var items: [ScreenshotHistoryItem] = []
    private(set) var thumbnails: [UUID: NSImage] = [:]
    var selection = 0

    private init() {}

    func reload() {
        items = Array(
            ScreenshotHistoryStore.shared.items
                .filter {
                    !$0.isVideo
                        && FileManager.default.fileExists(atPath: $0.url.path)
                }
                .prefix(50)
        )
        selection = min(selection, max(0, items.count - 1))

        for item in items where thumbnails[item.id] == nil {
            Task { @MainActor in
                guard let image = ScreenshotImageLoader.downsampledImage(
                    at: item.url,
                    maxPixelSize: 320
                ) else { return }
                thumbnails[item.id] = image
            }
        }
    }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(selection + delta, 0), items.count - 1)
    }

    var selectedItem: ScreenshotHistoryItem? {
        guard items.indices.contains(selection) else { return nil }
        return items[selection]
    }
}

@MainActor
final class RecentCapturesStripPresenter {
    static let shared = RecentCapturesStripPresenter()

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var hotKeyRef: EventHotKeyRef?
    private var fallbackHotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var closeHotKeyRef: EventHotKeyRef?
    private var closeHotKeyHandler: EventHandlerRef?
    private var activationObserver: NSObjectProtocol?
    private var retryTask: Task<Void, Never>?
    private(set) var usesFallbackShortcut = false
    private static let statusKey = "recentStripShortcut"

    private static let hotKeySignature: OSType = 0x52435354 // 'RCST'
    private static let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
    private static let fallbackHotKeyID = EventHotKeyID(signature: hotKeySignature, id: 2)
    private static let closeHotKeySignature: OSType = 0x52435732 // 'RCW2'
    private static let closeHotKeyID = EventHotKeyID(signature: closeHotKeySignature, id: 1)

    /// The shortcut that actually registered; ⇧⌘L can be taken by another app
    /// (CleanShot X uses it), in which case ⌥⌘L is used instead.
    var shortcutHint: String { usesFallbackShortcut ? "⌥⌘L" : "⇧⌘L" }

    private init() {
        registerHotKey()
        // If another app held ⇧⌘L at launch, try again whenever this app comes
        // forward (e.g. after that app quits).
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { RecentCapturesStripPresenter.shared.registerHotKey() }
        }
    }

    var isShown: Bool { panel?.isVisible == true }

    #if DEBUG
    var panelForTesting: NSPanel? { panel }
    #endif

    func toggle() {
        if isShown { hide() } else { show() }
    }

    func show() {
        registerHotKey()
        let model = RecentCapturesStripModel.shared
        model.reload()
        previousApp = NSWorkspace.shared.frontmostApplication

        let panel = panel ?? makePanel()
        panel.setFrame(frame(for: panel), display: true)
        // Non-activating: showing the strip must not bring the Library (or
        // any other window of this app) forward.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
        installKeyMonitor()
        // ⌘W closes the strip only; while it is open, the underlying app must
        // not receive it. A Carbon hotkey works even when ScreenDrop is not
        // the active app.
        registerCloseHotKey()
    }

    func hide() {
        unregisterCloseHotKey()
        removeKeyMonitor()
        panel?.orderOut(nil)
        previousApp?.activate()
        previousApp = nil
    }

    private func pinSelected() {
        guard let item = RecentCapturesStripModel.shared.selectedItem else {
            hide()
            return
        }
        hide()
        PinnedScreenshotPresenter.shared.pin(url: item.url)
    }

    private func makePanel() -> NSPanel {
        let panel = RecentStripPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 210),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecentCapturesStripView())
        self.panel = panel
        return panel
    }

    private func frame(for panel: NSPanel) -> CGRect {
        let screen = ActiveDisplayResolver.activeScreen(preferPointer: true) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let height: CGFloat = 210
        return CGRect(
            x: visible.minX + 24,
            y: visible.maxY - height - 20,
            width: visible.width - 48,
            height: height
        )
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53, 13: // Escape; ⌘W (fallback when the panel has focus)
                if event.keyCode == 13, !event.modifierFlags.contains(.command) {
                    return event
                }
                self.hide()
                return nil
            case 36, 76: // Return, keypad Enter
                self.pinSelected()
                return nil
            case 123, 126: // Left, Up
                RecentCapturesStripModel.shared.move(by: -1)
                return nil
            case 124, 125: // Right, Down
                RecentCapturesStripModel.shared.move(by: 1)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: ⌘W for the strip

    private func registerCloseHotKey() {
        guard closeHotKeyRef == nil else { return }
        installCloseHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_W),
            UInt32(cmdKey),
            Self.closeHotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr {
            closeHotKeyRef = reference
        }
    }

    private func unregisterCloseHotKey() {
        if let closeHotKeyRef {
            UnregisterEventHotKey(closeHotKeyRef)
            self.closeHotKeyRef = nil
        }
    }

    private func installCloseHandlerIfNeeded() {
        guard closeHotKeyHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressed
                )
                guard status == noErr,
                      pressed.signature == RecentCapturesStripPresenter.closeHotKeySignature
                else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async {
                    RecentCapturesStripPresenter.shared.hide()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &closeHotKeyHandler
        )
    }

    // MARK: Global shortcut

    private func registerHotKey() {
        if hotKeyRef != nil { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        if hotKeyHandler == nil {
            InstallEventHandler(
                GetApplicationEventTarget(),
            { _, event, _ in
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressed
                )
                guard status == noErr,
                      pressed.signature == RecentCapturesStripPresenter.hotKeySignature
                else {
                    // Not ours: let the app's capture hotkeys handle it.
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async {
                    RecentCapturesStripPresenter.shared.toggle()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
                &hotKeyHandler
            )
        }

        var primary: EventHotKeyRef?
        let primaryStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(cmdKey | shiftKey),
            Self.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &primary
        )
        if primaryStatus == noErr {
            hotKeyRef = primary
            if let fallbackHotKeyRef {
                UnregisterEventHotKey(fallbackHotKeyRef)
                self.fallbackHotKeyRef = nil
            }
            usesFallbackShortcut = false
            UserDefaults.standard.set("shift-cmd-L", forKey: Self.statusKey)
            retryTask?.cancel()
            retryTask = nil
            return
        }

        // ⇧⌘L is held by another app. Fall back to ⌥⌘L so the strip is still
        // reachable, and keep trying ⇧⌘L on every activation.
        if fallbackHotKeyRef == nil {
            var fallback: EventHotKeyRef?
            let fallbackStatus = RegisterEventHotKey(
                UInt32(kVK_ANSI_L),
                UInt32(cmdKey | optionKey),
                Self.fallbackHotKeyID,
                GetApplicationEventTarget(),
                0,
                &fallback
            )
            if fallbackStatus == noErr {
                fallbackHotKeyRef = fallback
                usesFallbackShortcut = true
                UserDefaults.standard.set("option-cmd-L", forKey: Self.statusKey)
            }
        }

        // Another app owns ⇧⌘L right now. Try again periodically so quitting
        // that app is enough to reclaim it.
        if retryTask == nil {
            retryTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard let self else { return }
                    if self.hotKeyRef != nil { return }
                    self.registerHotKey()
                }
            }
        }
    }
}

private final class RecentStripPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct RecentCapturesStripView: View {
    @State private var model = RecentCapturesStripModel.shared
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 4) {
            header

            if model.items.isEmpty {
                Spacer()
                Text("No recent captures")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                card(item, index: index)
                                    .id(item.id)
                                    .onTapGesture { model.selection = index }
                                    .simultaneousGesture(
                                        TapGesture(count: 2).onEnded {
                                            model.selection = index
                                            PinnedScreenshotPresenter.shared.pin(url: item.url)
                                            RecentCapturesStripPresenter.shared.hide()
                                        }
                                    )
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: model.selection) { _, newValue in
                        guard model.items.indices.contains(newValue) else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(model.items[newValue].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .padding(4)
        .offset(y: hasAppeared ? 0 : -10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) {
                hasAppeared = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
            Text("Recent Captures")
                .font(.system(size: 12, weight: .semibold))
            Text("\(model.items.count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Text("← → select · Return pin · Esc close")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func card(_ item: ScreenshotHistoryItem, index: Int) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Color.black.opacity(0.25)
                if let thumbnail = model.thumbnails[item.id] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 156, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            HStack(spacing: 6) {
                Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10.5, weight: .semibold))
                Text("\(item.pixelWidth) × \(item.pixelHeight)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .padding(6)
        .background(
            model.selection == index ? Color.accentColor.opacity(0.28) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            if model.selection == index {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
