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
    case mcp
    case cloud
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .screenshots: "Screenshots"
        case .video: "Screen Recordings"
        case .overlay: "Overlay"
        case .mcp: "MCP"
        case .cloud: "Cloud"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .screenshots: "camera.viewfinder"
        case .video: "record.circle.fill"
        case .overlay: "square.stack.fill"
        case .mcp: "point.3.filled.connected.trianglepath.dotted"
        case .cloud: "icloud.fill"
        case .about: "info.circle.fill"
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

// MARK: - Main Settings View

struct SettingsView: View {
    @State private var navigation = SettingsNavigation.shared
    @State private var permissions = SettingsPermissions()
    @State private var navigationHistory: [SettingsTab] = [.general]
    @State private var historyIndex = 0
    @State private var isHistoryNavigation = false

    private var activeTab: SettingsTab {
        navigation.selectedTab ?? .general
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebarView(selectedTab: $navigation.selectedTab)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    SettingsStatusFooter(permissions: permissions)
                }
                .frame(width: 200)
                .navigationSplitViewColumnWidth(
                    min: 200,
                    ideal: 200,
                    max: 200
                )
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetailView(tab: activeTab)
                .environment(permissions)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 660, minHeight: 540)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoBack)
                .help("Go Back")
                .accessibilityLabel("Go Back")

                Button {
                    goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoForward)
                .help("Go Forward")
                .accessibilityLabel("Go Forward")
            }
        }
        .onAppear {
            navigationHistory = [activeTab]
            historyIndex = 0
            permissions.beginWatching()
        }
        .onDisappear { permissions.endWatching() }
        .onChange(of: navigation.selectedTab) { _, _ in
            recordNavigation()
        }
    }

    // MARK: - Navigation History

    private var canGoBack: Bool {
        historyIndex > 0
    }

    private var canGoForward: Bool {
        historyIndex < navigationHistory.count - 1
    }

    private func goBack() {
        guard canGoBack else { return }
        isHistoryNavigation = true
        historyIndex -= 1
        navigation.selectedTab = navigationHistory[historyIndex]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private func goForward() {
        guard canGoForward else { return }
        isHistoryNavigation = true
        historyIndex += 1
        navigation.selectedTab = navigationHistory[historyIndex]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private func recordNavigation() {
        guard !isHistoryNavigation else { return }
        guard let tab = navigation.selectedTab else { return }
        if navigationHistory[historyIndex] == tab { return }
        if historyIndex < navigationHistory.count - 1 {
            navigationHistory = Array(navigationHistory.prefix(historyIndex + 1))
        }
        navigationHistory.append(tab)
        historyIndex = navigationHistory.count - 1
    }
}

// MARK: - Sidebar

private struct SettingsSidebarView: View {
    @Binding var selectedTab: SettingsTab?

    var body: some View {
        List(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsSidebarRow(tab: tab)
                    .tag(tab)
            }
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectSoftIfAvailable()
        .navigationTitle("Settings")
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab

    var body: some View {
        Label {
            Text(tab.title)
        } icon: {
            // Symbols have different natural widths; a fixed slot keeps every
            // title on the same leading edge.
            Image(systemName: tab.systemImage)
                .frame(width: 20, alignment: .center)
        }
        .listItemTint(.monochrome)
    }
}

// MARK: - Detail

private struct SettingsDetailView: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general:
                GeneralSettingsPane()
            case .screenshots:
                ScreenshotsSettingsPane()
            case .video:
                VideoSettingsPane()
            case .overlay:
                OverlaySettingsPane()
            case .mcp:
                MCPSettingsPane()
            case .cloud:
                CloudSettingsPane()
            case .about:
                SettingsAboutPane()
            }
        }
        .navigationTitle(tab.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
