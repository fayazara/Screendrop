//
//  SettingsView.swift
//  OpenShot
//
//  Created by Codex on 26/04/26.
//

import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case screenshots
    case video
    case overlay
    case cloud
    case history
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .screenshots: "Screenshots"
        case .video: "Video"
        case .overlay: "Overlay"
        case .cloud: "Cloud"
        case .history: "History"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .screenshots: "camera.viewfinder"
        case .video: "video.fill"
        case .overlay: "rectangle.on.rectangle"
        case .cloud: "cloud.fill"
        case .history: "clock.arrow.circlepath"
        case .about: "info.circle.fill"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()

    var selectedTab: SettingsTab = .general

    private init() {}
}

// MARK: - Main Settings View

struct SettingsView: View {
    @State private var navigation = SettingsNavigation.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: Binding(
                get: { navigation.selectedTab },
                set: { navigation.selectedTab = $0 }
            ))
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 660, height: 580)
        .background {
            SettingsWindowTitleUpdater(title: navigation.selectedTab.title)
        }
        .onAppear {
            AppActivationPolicy.enter()
        }
        .onDisappear {
            AppActivationPolicy.leave()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch navigation.selectedTab {
        case .general:
            GeneralSettingsPane()
        case .screenshots:
            ScreenshotsSettingsPane()
        case .video:
            VideoSettingsPane()
        case .overlay:
            OverlaySettingsPane()
        case .cloud:
            CloudSettingsPane()
        case .history:
            SettingsHistoryPane()
        case .about:
            SettingsAboutPane()
        }
    }
}

// MARK: - Tab Bar

private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 20))
                            .symbolRenderingMode(.hierarchical)
                            .frame(height: 24)

                        Text(tab.title)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .frame(width: 72, height: 48)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared Layout Components

struct SettingsPane<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(.vertical, 16)
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
                .padding(.trailing, 20)

            content
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsSectionDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 150)
    }
}

// MARK: - Helpers

private struct SettingsWindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}

extension URL {
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
