//
//  SettingsView.swift
//  Screendrop
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

    var id: Self { self }

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
        case .general: "gearshape"
        case .screenshots: "camera.viewfinder"
        case .video: "video"
        case .overlay: "rectangle.on.rectangle"
        case .cloud: "cloud"
        case .history: "clock.arrow.circlepath"
        case .about: "info.circle"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()

    var selectedTab: SettingsTab? = .general

    private init() {}
}

private enum AppVersion {
    static let displayString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }()
}

// MARK: - Main Settings View

struct SettingsView: View {
    @State private var navigation = SettingsNavigation.shared

    private var activeTab: SettingsTab {
        navigation.selectedTab ?? .general
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SettingsTab.allCases, selection: $navigation.selectedTab) { tab in
                    SettingsSidebarRow(tab: tab)
                        .tag(tab)
                }
                .listStyle(.sidebar)

                SettingsSidebarFooter()
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            settingsDetail(for: activeTab)
                .navigationTitle(activeTab.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .background(SettingsWindowConfigurator())
        .frame(minWidth: 620, minHeight: 460)
        .onAppear {
            AppActivationPolicy.enter()
        }
        .onDisappear {
            AppActivationPolicy.leave()
        }
    }

    @ViewBuilder
    private func settingsDetail(for tab: SettingsTab) -> some View {
        switch tab {
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

// MARK: - Sidebar Components

private struct SettingsSidebarRow: View {
    let tab: SettingsTab

    var body: some View {
        Label {
            Text(tab.title)
        } icon: {
            Group {
                Image(systemName: tab.systemImage)
            }
            .frame(width: 18)
        }
    }
}

private struct SettingsSidebarFooter: View {
    var body: some View {
        Text(AppVersion.displayString)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
    }
}

// MARK: - Window Configuration

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.isMovableByWindowBackground = true
    }
}

// MARK: - Helpers

extension URL {
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
