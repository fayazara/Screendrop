//
//  SettingsView.swift
//  Screendrop
//

import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case screenshots
    case video
    case annotate
    case overlay
    case library
    case cloud
    case mcp
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .screenshots: "Screenshots"
        case .video: "Screen Recording"
        case .annotate: "Annotate"
        case .overlay: "Capture Cards"
        case .library: "Library"
        case .cloud: "Cloud"
        case .mcp: "AI Agents"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcuts: "command"
        case .screenshots: "camera.fill"
        case .video: "video.fill"
        case .annotate: "pencil.tip.crop.circle"
        case .overlay: "photo.on.rectangle"
        case .library: "photo.on.rectangle.angled"
        case .cloud: "cloud.fill"
        case .mcp: "sparkle"
        case .about: "info.circle.fill"
        }
    }

    /// Words a search for this pane should match besides its title: the
    /// settings it holds, and what people are likely to call them.
    var keywords: [String] {
        switch self {
        case .general: ["permissions", "screen recording", "microphone", "camera", "privacy", "allow", "access", "launch at login", "startup", "menu bar", "dock", "sounds", "shutter", "save location", "export folder", "include windows", "visibility"]
        case .shortcuts: ["hotkeys", "keyboard", "keys", "fullscreen", "window", "area", "capture text", "ocr", "record"]
        case .screenshots: ["self-timer", "delay", "countdown", "shadow", "menu bar", "notch", "after capture", "copy", "clipboard", "format", "png", "jpeg", "heic", "compression", "quality"]
        case .video: ["recording", "after recording", "export", "reveal in finder", "projects", "studio"]
        case .annotate: ["editor", "starting tool", "preview", "memory", "resolution", "markup"]
        case .overlay: ["shelf", "quick access", "preview", "screen edge", "auto-close", "drag", "actions", "cards"]
        case .library: ["analyze", "ocr", "search", "text", "categories", "sort", "apple intelligence", "similar"]
        case .cloud: ["upload", "worker", "token", "cloudflare", "r2", "share", "link"]
        case .mcp: ["mcp", "claude", "codex", "agent", "server", "ai"]
        case .about: ["version", "updates", "github", "license"]
        }
    }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return ([title] + keywords).contains {
            $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
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
    @State private var searchText = ""

    private var activeTab: SettingsTab {
        navigation.selectedTab ?? .general
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebarView(
                selectedTab: $navigation.selectedTab,
                searchText: searchText
            )
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
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search Settings")
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: SettingsWindowController.minimumSize.width,
            minHeight: SettingsWindowController.minimumSize.height
        )
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
        .onChange(of: searchText) { _, query in
            // Typing jumps to the first pane that matches, so a search for
            // "shadow" lands on Screenshots without another click.
            guard !query.isEmpty, !activeTab.matches(query) else { return }
            if let first = SettingsTab.allCases.first(where: { $0.matches(query) }) {
                navigation.selectedTab = first
            }
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
    let searchText: String

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        List(selection: $selectedTab) {
            if isSearching {
                let results = SettingsTab.allCases.filter { $0.matches(searchText) }
                if results.isEmpty {
                    Text("No Results")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, Space.xl)
                        .selectionDisabled()
                } else {
                    ForEach(results) { tab in
                        SettingsSidebarRow(tab: tab).tag(tab)
                    }
                }
            } else {
                ForEach(SettingsTab.allCases) { tab in
                    SettingsSidebarRow(tab: tab).tag(tab)
                }
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
            case .shortcuts:
                ShortcutsSettingsPane()
            case .screenshots:
                ScreenshotsSettingsPane()
            case .video:
                VideoSettingsPane()
            case .annotate:
                AnnotateSettingsPane()
            case .overlay:
                OverlaySettingsPane()
            case .library:
                LibrarySettingsPane()
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
