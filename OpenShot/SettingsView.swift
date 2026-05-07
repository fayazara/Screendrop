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

// MARK: - General Settings

private struct GeneralSettingsPane: View {
    @AppStorage(OpenShotPreferences.exportDirectoryPathKey) private var exportDirectoryPath = ""

    var body: some View {
        SettingsPane {
            SettingsSection {
                SettingsRow("Startup:") {
                    Text("Launch at Login is managed in\nSystem Settings → General → Login Items")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineSpacing(2)
                }
            }

            SettingsSectionDivider()

            SettingsSection {
                SettingsRow("Export location:") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                            .font(.system(size: 14))

                        Text(OpenShotPreferences.exportDirectory.abbreviatedPath)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                    )
                }

                SettingsRow("") {
                    HStack(spacing: 8) {
                        Button("Choose Folder...") {
                            chooseExportDirectory()
                        }

                        Button("Use Default") {
                            exportDirectoryPath = ""
                        }
                        .disabled(exportDirectoryPath.isEmpty)
                    }
                    .controlSize(.small)
                }
            }

            SettingsSectionDivider()

            SettingsSection {
                SettingsRow("Desktop icons:") {
                    Toggle("Hide while capturing", isOn: .constant(false))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Save Location"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = OpenShotPreferences.exportDirectory

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        exportDirectoryPath = url.path
    }
}

// MARK: - Screenshots Settings

private struct ScreenshotsSettingsPane: View {
    @AppStorage(OpenShotPreferences.autoSaveKey) private var autoSave = false
    @AppStorage(OpenShotPreferences.autoCopyKey) private var autoCopy = false
    @AppStorage(OpenShotPreferences.autoCompressKey) private var autoCompress = false
    @AppStorage(OpenShotPreferences.exportFormatKey) private var exportFormatRawValue = ""
    @AppStorage(OpenShotPreferences.compressionQualityKey) private var compressionQuality = 0.8

    private var exportFormat: ScreenshotExportFormat {
        get {
            ScreenshotExportFormat(rawValue: exportFormatRawValue) ?? (autoCompress ? .jpeg : .png)
        }
        nonmutating set {
            exportFormatRawValue = newValue.rawValue
            autoCompress = newValue.usesLossyQuality
        }
    }

    var body: some View {
        SettingsPane {
            SettingsSection {
                SettingsRow("After capture:") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Auto save screenshots", isOn: $autoSave)
                            .toggleStyle(.checkbox)
                        Toggle("Copy to clipboard", isOn: $autoCopy)
                            .toggleStyle(.checkbox)
                    }
                }
            }

            SettingsSectionDivider()

            SettingsSection {
                SettingsRow("File format:") {
                    Picker("", selection: Binding(
                        get: { exportFormat },
                        set: { exportFormat = $0 }
                    )) {
                        ForEach(ScreenshotExportFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }

                if exportFormat.usesLossyQuality {
                    SettingsRow("Quality:") {
                        HStack(spacing: 12) {
                            Slider(value: $compressionQuality, in: 0.1...1, step: 0.05)
                                .frame(width: 200)

                            Text(compressionQuality, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Video Settings (Placeholder)

private struct VideoSettingsPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text("Video Recording")
                .font(.title3.weight(.medium))

            Text("Video recording settings will appear here.\nConfigure frame rate, resolution, and output format.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Overlay Settings (Placeholder)

private struct OverlaySettingsPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text("Overlay")
                .font(.title3.weight(.medium))

            Text("Configure the preview card that appears\nafter taking a screenshot.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Cloud Settings

private struct CloudSettingsPane: View {
    @AppStorage(OpenShotPreferences.cloudWorkerURLKey) private var workerURL = ""
    @AppStorage(OpenShotPreferences.cloudUploadTokenKey) private var uploadToken = ""
    @State private var connectionStatus: CloudConnectionStatus = .unchecked
    
    private var isConfigured: Bool {
        !workerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !uploadToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        SettingsPane {
            SettingsSection {
                SettingsRow("Status:") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        
                        Text(statusText)
                            .font(.system(size: 13))
                            .foregroundStyle(isConfigured ? .primary : .secondary)
                    }
                }
            }
            
            SettingsSectionDivider()
            
            SettingsSection {
                SettingsRow("Worker URL:") {
                    TextField("https://openshot.your-name.workers.dev", text: $workerURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: workerURL) {
                            connectionStatus = .unchecked
                        }
                }
                
                SettingsRow("Upload Token:") {
                    SecureField("Paste your shared token", text: $uploadToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: uploadToken) {
                            connectionStatus = .unchecked
                        }
                }
                
                SettingsRow("") {
                    HStack(spacing: 8) {
                        Button("Test Connection") {
                            Task { await testConnection() }
                        }
                        .disabled(!isConfigured)
                        .controlSize(.small)
                        
                        if connectionStatus == .checking {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        }
                    }
                }
            }
            
            SettingsSectionDivider()
            
            if !isConfigured {
                SettingsSection {
                    SettingsRow("Setup:") {
                        VStack(alignment: .leading, spacing: 10) {
                            SetupStepView(number: 1, text: "Deploy the OpenShot worker to Cloudflare")
                            SetupStepView(number: 2, text: "Set the UPLOAD_TOKEN secret via wrangler secret put UPLOAD_TOKEN")
                            SetupStepView(number: 3, text: "Paste the worker URL and token above")
                        }
                    }
                    
                    SettingsRow("") {
                        Button("View on GitHub") {
                            if let url = URL(string: "https://github.com/fayazara/openshot-worker") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .task {
            if isConfigured && connectionStatus == .unchecked {
                await testConnection()
            }
        }
    }
    
    private var statusColor: Color {
        switch connectionStatus {
        case .unchecked:
            isConfigured ? .orange : .gray
        case .checking:
            .orange
        case .connected:
            .green
        case .failed:
            .red
        }
    }
    
    private var statusText: String {
        switch connectionStatus {
        case .unchecked:
            isConfigured ? "Not verified" : "Not configured"
        case .checking:
            "Checking..."
        case .connected:
            "Connected"
        case .failed(let message):
            "Failed: \(message)"
        }
    }
    
    private func testConnection() async {
        connectionStatus = .checking
        
        let base = workerURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let token = uploadToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let url = URL(string: "\(base)/api/ping") else {
            connectionStatus = .failed("Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                connectionStatus = .failed("No response")
                return
            }
            
            switch http.statusCode {
            case 200:
                connectionStatus = .connected
            case 401, 403:
                connectionStatus = .failed("Invalid token")
            default:
                connectionStatus = .failed("HTTP \(http.statusCode)")
            }
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }
}

private enum CloudConnectionStatus: Equatable {
    case unchecked
    case checking
    case connected
    case failed(String)
}

private struct SetupStepView: View {
    let number: Int
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.tertiary))
            
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
    }
}

// MARK: - History

private struct SettingsHistoryPane: View {
    @State private var historyStore = ScreenshotHistoryStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("History")
                            .font(.title3.weight(.semibold))

                        Text("\(historyStore.items.count) screenshots")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        historyStore.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh history")
                }

                if historyStore.items.isEmpty {
                    ContentUnavailableView(
                        "No Screenshots",
                        systemImage: "photo.stack",
                        description: Text("Captured screenshots will appear here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(historyStore.items) { item in
                            SettingsHistoryItemRow(
                                item: item,
                                onPreview: {
                                    QuickLookPreviewPresenter.show(url: item.url)
                                },
                                onCopy: {
                                    try? ScreenshotFileActions.copyPNGToClipboard(from: item.url)
                                },
                                onAnnotate: {
                                    QuickLookPreviewPresenter.dismiss()
                                    openWindow(id: "ANNOTATION_EDITOR", value: item.url)
                                },
                                onReveal: {
                                    historyStore.reveal(item)
                                },
                                onDelete: {
                                    historyStore.delete(item)
                                }
                            )

                            if item.id != historyStore.items.last?.id {
                                Divider()
                                    .padding(.leading, 92)
                            }
                        }
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary.opacity(0.12))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.separator.opacity(0.35), lineWidth: 1)
                    }
                }
            }
            .frame(maxWidth: 610, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            historyStore.reload()
        }
    }
}

private struct SettingsHistoryItemRow: View {
    let item: ScreenshotHistoryItem
    let onPreview: () -> Void
    let onCopy: () -> Void
    let onAnnotate: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                }
            }
            .frame(width: 64, height: 48)
            .clipShape(.rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.separator.opacity(0.45), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(item.createdAt.formatted(date: .abbreviated, time: .shortened)) - \(item.pixelWidth)x\(item.pixelHeight)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                Button(action: onPreview) {
                    Image(systemName: "eye")
                }
                .help("Preview")

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy")

                Button(action: onAnnotate) {
                    Image(systemName: "pencil")
                }
                .help("Annotate")

                Button(action: onReveal) {
                    Image(systemName: "finder")
                }
                .help("Reveal in Finder")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("Delete")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .task(id: item.fileName) {
            thumbnail = ScreenshotImageLoader.downsampledImage(at: item.url, maxPixelSize: 160)
        }
    }
}

// MARK: - About

private struct SettingsAboutPane: View {
    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

        switch (version, build) {
        case let (version?, build?):
            return "Version \(version) (\(build))"
        case let (version?, nil):
            return "Version \(version)"
        default:
            return "Version 1.0"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)

            Text("OpenShot")
                .font(.title2.weight(.semibold))

            Text(versionText)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
