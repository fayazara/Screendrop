//
//  PermissionGuidePresenter.swift
//  Screendrop
//
//  Walks the user to the exact switch a permission needs. It opens the right
//  Privacy & Security list in System Settings, then floats a small guide
//  beside the Settings window: which switch to turn on, an app icon to drag
//  into the list when Screendrop isn't in it yet, and a live status that
//  flips the moment the grant lands. The system never tells an app when a
//  switch changes, so the guide polls.
//

import AppKit
import ApplicationServices
import SwiftUI

@MainActor
@Observable
final class PermissionGuidePresenter {
    static let shared = PermissionGuidePresenter()

    enum Permission: Equatable {
        case accessibility
        case screenRecording

        var title: String {
            switch self {
            case .accessibility: "Accessibility"
            case .screenRecording: "Screen & System Audio Recording"
            }
        }

        fileprivate var settingsAnchor: String {
            switch self {
            case .accessibility: "Privacy_Accessibility"
            case .screenRecording: "Privacy_ScreenCapture"
            }
        }

        /// Screen Recording is read once per process, so the switch only
        /// takes effect after Screendrop reopens.
        fileprivate var needsRelaunch: Bool { self == .screenRecording }

        fileprivate var isGranted: Bool {
            switch self {
            case .accessibility: AXIsProcessTrusted()
            case .screenRecording: CGPreflightScreenCaptureAccess()
            }
        }
    }

    private(set) var permission: Permission?
    /// Why the permission is being asked for, in a few words.
    private(set) var reason = ""
    private(set) var isGranted = false

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private init() {}

    static var appName: String {
        FileManager.default.displayName(atPath: Bundle.main.bundlePath)
            .replacingOccurrences(of: ".app", with: "")
    }

    /// Opens System Settings at the permission's list and shows the guide.
    func show(_ permission: Permission, reason: String) {
        self.permission = permission
        self.reason = reason
        isGranted = permission.isGranted
        openSettings(for: permission)
        showPanel()
        startPolling()
    }

    func openSettings() {
        guard let permission else { return }
        openSettings(for: permission)
    }

    func hide() {
        pollTask?.cancel()
        pollTask = nil
        panel?.orderOut(nil)
        panel = nil
        permission = nil
    }

    /// Reopens Screendrop so a Screen Recording grant takes effect.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Settings

    private func openSettings(for permission: Permission) {
        // The Ventura-and-later extension ID lands on the list itself; the
        // legacy pane ID is the fallback for anything that doesn't route it.
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(permission.settingsAnchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)"
        ].compactMap(URL.init(string:))
        for url in urls where NSWorkspace.shared.open(url) {
            return
        }
    }

    // MARK: Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var closeAt: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let permission = self.permission else { return }
                self.positionPanel()
                let granted = permission.isGranted
                if granted != self.isGranted {
                    withAnimation(.easeOut(duration: 0.2)) { self.isGranted = granted }
                }
                // A granted Accessibility switch works right away; leave the
                // confirmation up briefly, then get out of the way.
                if granted, !permission.needsRelaunch {
                    if closeAt == nil { closeAt = .now + .seconds(3) }
                    if let closeAt, .now >= closeAt {
                        self.hide()
                        return
                    }
                }
            }
        }
    }

    // MARK: Panel

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        positionPanel()
        panel.orderFrontRegardless()
        // System Settings takes a moment to open and settle its window.
        Task {
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(250))
                positionPanel()
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = PermissionGuidePanel(
            contentRect: CGRect(origin: .zero, size: PermissionGuideView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: PermissionGuideView())
        hostingView.sizingOptions = []
        hostingView.frame = CGRect(origin: .zero, size: PermissionGuideView.size)
        panel.contentView = hostingView
        return panel
    }

    /// Beside the System Settings window, on whichever side has room; the
    /// bottom of the screen when Settings can't be found.
    private func positionPanel() {
        guard let panel else { return }
        let size = PermissionGuideView.size
        let gap: CGFloat = 12

        if let settings = Self.systemSettingsFrame(),
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(settings) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            var x = settings.maxX + gap
            if x + size.width > visible.maxX {
                x = settings.minX - gap - size.width
            }
            if x < visible.minX {
                x = settings.maxX - size.width - gap
            }
            let y = min(max(settings.maxY - size.height, visible.minY), visible.maxY - size.height)
            panel.setFrameOrigin(CGPoint(x: x, y: y))
            return
        }

        guard panel.frame.origin == .zero, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 80))
    }

    /// The System Settings window in AppKit coordinates.
    private static func systemSettingsFrame() -> CGRect? {
        guard let settingsApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == settingsApp.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 200, bounds.height > 200 else { continue }
            return CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        }
        return nil
    }
}

private final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

private struct PermissionGuideView: View {
    static let size = CGSize(width: 300, height: 268)

    @State private var presenter = PermissionGuidePresenter.shared

    private var appName: String { PermissionGuidePresenter.appName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if presenter.isGranted {
                grantedBody
            } else {
                steps
            }

            Spacer(minLength: 0)
            buttons
        }
        .padding(18)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow \(appName)")
                    .font(.system(size: 13, weight: .semibold))
                Text(presenter.permission?.title ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !presenter.reason.isEmpty {
                Text(presenter.reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(1, "Turn on the switch next to **\(appName)** in the list.")

            HStack(alignment: .center, spacing: 10) {
                step(2, "Not in the list? Drag this icon into it.")
                Spacer(minLength: 0)
                DraggableAppIcon()
            }

            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Waiting for the switch…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var grantedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
            Text(presenter.permission == .screenRecording
                 ? "Reopen \(appName) so macOS applies it."
                 : "You're all set. Try the capture again.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Close") { presenter.hide() }
            Spacer()
            if presenter.permission == .screenRecording {
                Button("Reopen \(appName)") { presenter.relaunch() }
                    .keyboardShortcut(.defaultAction)
            } else if !presenter.isGranted {
                Button("Show in Settings") { presenter.openSettings() }
            }
        }
        .controlSize(.regular)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .frame(width: 16, height: 16)
                .background(.quaternary, in: Circle())
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The app itself, draggable into a Privacy & Security list to add it.
private struct DraggableAppIcon: View {
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .frame(width: 44, height: 44)
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .onDrag {
                NSItemProvider(object: Bundle.main.bundleURL as NSURL)
            }
            .help("Drag into the list in System Settings")
            .accessibilityLabel("\(PermissionGuidePresenter.appName) app icon, drag into the list")
    }
}
