//
//  SettingsComponents.swift
//  Screendrop
//
//  The pieces every Settings pane is made of. Panes stay native grouped
//  forms - that is what a Mac settings window should feel like - but their
//  buttons, shortcuts and status marks come from the app's own glass set so
//  Settings reads as the same product as the editors.
//

import AppKit
import AVFoundation
import SwiftUI

// MARK: - Page

/// The scaffold for one pane: a grouped form with the standard insets and
/// the system's own switches, so Settings reads like the rest of the Mac.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            // A Form's toggles are checkboxes on macOS unless told otherwise.
            .toggleStyle(.switch)
    }
}

/// The same label rhythm across settings panes, with descriptions allowed to
/// wrap at the window's minimum width instead of being vertically truncated.
struct SettingsControlLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A form row with its label on the left and a control on the right,
/// centered on the row's height. `LabeledContent` in a grouped form lines
/// the control up with the label's first baseline instead, so a field or
/// button rides high, and sits on the top line of a two-line label.
struct SettingsRow<Label: View, Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
        }
    }
}

extension SettingsRow where Label == Text {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.content = content
        self.label = { Text(title) }
    }
}

/// A compact glass button for actions inside a form row.
struct SettingsButton: View {
    let title: String
    var systemImage: String? = nil
    var isProminent = false
    var avatar: Image? = nil
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, avatar: Image? = nil, isProminent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.avatar = avatar
        self.isProminent = isProminent
        self.action = action
    }

    var body: some View {
        GlassCapsuleButton(
            title: title,
            systemImage: systemImage,
            height: GlassMetrics.compactHeight,
            isProminent: isProminent,
            avatar: avatar,
            action: action
        )
        .fixedSize()
    }
}

// MARK: - Permissions

/// Live status of the system permissions Screendrop leans on. Polled while
/// Settings is open, because the system never tells an app when the user
/// flips a switch in Privacy & Security.
@MainActor
@Observable
final class SettingsPermissions {
    enum Kind: CaseIterable, Identifiable {
        case screenRecording
        case microphone
        case camera

        var id: Self { self }

        var title: String {
            switch self {
            case .screenRecording: "Screen Recording"
            case .microphone: "Microphone"
            case .camera: "Camera"
            }
        }

        var detail: String {
            switch self {
            case .screenRecording: "Required for screenshots and recordings."
            case .microphone: "Narrate recordings and transcribe captions."
            case .camera: "Add a camera bubble to recordings."
            }
        }

        var systemImage: String {
            switch self {
            case .screenRecording: "rectangle.dashed.badge.record"
            case .microphone: "mic.fill"
            case .camera: "video.fill"
            }
        }

        var isRequired: Bool { self == .screenRecording }

        fileprivate var settingsAnchor: String {
            switch self {
            case .screenRecording: "Privacy_ScreenCapture"
            case .microphone: "Privacy_Microphone"
            case .camera: "Privacy_Camera"
            }
        }
    }

    private(set) var granted: Set<Kind> = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0

    func isGranted(_ kind: Kind) -> Bool { granted.contains(kind) }

    var missingRequired: Kind? {
        Kind.allCases.first { $0.isRequired && !granted.contains($0) }
    }

    func beginWatching() {
        watchers += 1
        refresh()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                self?.refresh()
            }
        }
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() {
        var next: Set<Kind> = []
        if CGPreflightScreenCaptureAccess() { next.insert(.screenRecording) }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { next.insert(.microphone) }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { next.insert(.camera) }
        if next != granted { granted = next }
    }

    func request(_ kind: Kind) {
        switch kind {
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSettings(for: kind) }
        case .microphone, .camera:
            let mediaType: AVMediaType = kind == .microphone ? .audio : .video
            if AVCaptureDevice.authorizationStatus(for: mediaType) == .notDetermined {
                Task {
                    _ = await AVCaptureDevice.requestAccess(for: mediaType)
                    refresh()
                }
            } else {
                openSettings(for: kind)
            }
        }
    }

    private func openSettings(for kind: Kind) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct SettingsPermissionRow: View {
    let kind: SettingsPermissions.Kind
    let permissions: SettingsPermissions

    var body: some View {
        let granted = permissions.isGranted(kind)
        HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(granted ? Palette.label : (kind.isRequired ? Palette.warning : Palette.secondaryLabel))
                .frame(width: 22)

            SettingsControlLabel(kind.title, detail: kind.detail)

            Spacer(minLength: 8)

            ZStack(alignment: .trailing) {
                if granted {
                    Label("Allowed", systemImage: "checkmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.blurPop)
                } else {
                    SettingsButton("Allow", isProminent: kind.isRequired) {
                        permissions.request(kind)
                    }
                    .transition(.blurPop)
                }
            }
        }
        .motion(value: granted)
    }
}

/// Always-visible readiness summary at the bottom of the Settings sidebar:
/// whether Screendrop can capture right now, and how to start.
struct SettingsStatusFooter: View {
    let permissions: SettingsPermissions

    var body: some View {
        let missing = permissions.missingRequired
        HStack(alignment: .center, spacing: 9) {
            StatusDot(color: missing == nil ? Palette.success : Palette.warning)

            VStack(alignment: .leading, spacing: 1) {
                Text(missing == nil ? "Ready to capture" : "Needs attention")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.label)
                Text(missing.map { "Allow \($0.title)" } ?? SettingsStatusFooter.versionString)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture {
            if let missing { permissions.request(missing) }
        }
        .motion(value: missing)
    }

    static let versionString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }()
}
