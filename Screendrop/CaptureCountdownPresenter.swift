//
//  CaptureCountdownPresenter.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Shows a brief centered countdown before a capture is taken, so the user can
/// arrange hover states, menus, etc. Driven by the `captureDelaySeconds`
/// preference. The overlay is fully torn down before the capture fires, so it
/// never appears in the screenshot.
@MainActor
@Observable
final class CaptureCountdownPresenter {
    static let shared = CaptureCountdownPresenter()

    private var panel: NSPanel?

    private init() {}

    private(set) var isRunning = false
    private var runID: UUID?
    private var countdownTask: Task<Bool, Never>?
    private var escapeMonitor: Any?
    private var globalEscapeMonitor: Any?

    /// False means cancelled or another countdown is already in progress.
    func runIfNeeded(seconds: Int, displayID: CGDirectDisplayID?) async -> Bool {
        guard !isRunning, !Task.isCancelled else { return false }
        guard seconds > 0 else { return true }
        let id = UUID()
        runID = id
        isRunning = true
        installEscapeMonitors()
        let task = Task { @MainActor in
            guard runID == id, !Task.isCancelled else { return false }
            let model = CaptureCountdownModel(remaining: seconds, total: seconds)
            present(model: model, displayID: displayID)
            do {
                for value in stride(from: seconds, through: 1, by: -1) {
                    try Task.checkCancellation()
                    model.remaining = value
                    try await Task.sleep(for: .seconds(1))
                }
                dismiss()
                try await Task.sleep(for: .milliseconds(80))
                try Task.checkCancellation()
                return true
            } catch {
                return false
            }
        }
        countdownTask = task
        let completed = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard runID == id else { return false }
        cancel()
        return completed && !Task.isCancelled
    }

    func cancel() {
        countdownTask?.cancel()
        countdownTask = nil
        runID = nil
        isRunning = false
        dismiss()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        escapeMonitor = nil
        globalEscapeMonitor = nil
    }

    private func installEscapeMonitors() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel()
            return nil
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func present(model: CaptureCountdownModel, displayID: CGDirectDisplayID?) {
        dismiss()

        let hostingView = NSHostingView(rootView: CaptureCountdownView(model: model, onCancel: { [weak self] in self?.cancel() }))
        hostingView.sizingOptions = []
        // Room around the glass for the shadow it casts.
        let size = NSSize(
            width: CaptureCountdownView.size + 2 * CaptureCountdownView.shadowSlack,
            height: CaptureCountdownView.size + 2 * CaptureCountdownView.shadowSlack
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.setHostedContent(hostingView)
        panel.setFrame(NSRect(origin: centeredOrigin(size: size, displayID: displayID), size: size), display: true)
        panel.orderFrontRegardless()

        self.panel = panel
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func centeredOrigin(size: NSSize, displayID: CGDirectDisplayID?) -> CGPoint {
        let screen = screen(for: displayID) ?? NSScreen.main
        guard let frame = screen?.frame else { return .zero }
        return CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
    }

    private func screen(for displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }
}

@MainActor
@Observable
private final class CaptureCountdownModel {
    var remaining: Int
    let total: Int

    init(remaining: Int, total: Int) {
        self.remaining = remaining
        self.total = max(1, total)
    }
}

/// A glass square in the middle of the screen: the seconds left, a ring
/// that drains through each second, and how to call it off.
private struct CaptureCountdownView: View {
    static let size: CGFloat = 140
    static let shadowSlack: CGFloat = 32

    @State var model: CaptureCountdownModel
    let onCancel: () -> Void

    @State private var ring: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(Palette.hairline, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: ring)
                    .stroke(Palette.label, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Text("\(model.remaining)")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.label)
                    .contentTransition(.numericText(countsDown: true))
                    .motion(.morphQuick, value: model.remaining)
            }
            .frame(width: 84, height: 84)

            Button(action: onCancel) {
                HStack(spacing: 5) {
                    KeyCap(label: "esc", isSmall: true)
                    Text("to cancel")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.secondaryLabel)
                }
            }
            .buttonStyle(.plain)
            .help("Cancel countdown (Esc)")
        }
        .frame(width: Self.size, height: Self.size)
        .glassHUD()
        .padding(Self.shadowSlack)
        .onAppear { drain(from: model.remaining) }
        .onChange(of: model.remaining) { _, value in drain(from: value) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Capturing in \(model.remaining)")
    }

    /// Sets the ring to this second's start, then drains it to the next.
    private func drain(from value: Int) {
        let start = Double(value) / Double(model.total)
        let end = Double(value - 1) / Double(model.total)
        ring = start
        withAnimation(reduceMotion ? nil : .linear(duration: 1)) { ring = end }
    }
}
