//
//  RecordingStudioActions.swift
//  Screendrop
//
//  Studio's two outward actions, Share and Export, as one glass group under
//  the inspector. Each capsule carries its own job: it fills as a progress
//  bar while running (the other action folds into a circle to give it room),
//  flashes a green check when the job lands, and a follow-up button - Show in
//  Finder, Copy Link - melts out beside it. A one-line status above names
//  what the actions will do, or what they just did.
//

import AppKit
import SwiftUI

struct StudioActionFooter: View {
    @Bindable var model: RecordingStudioModel
    /// The one-line status above the actions; dropped where the footer
    /// floats over the stage.
    var showsStatus = true

    @State private var isExportOptionsPresented = false
    @State private var isShareOptionsPresented = false
    @State private var exportFlash: String?
    @State private var shareFlash: String?
    /// Which job the status line reports on once neither is running.
    @State private var lastJob: Job = .export
    /// A failure the status line has shown long enough; it falls back to
    /// the format summary rather than staying until the next job.
    @State private var expiredFailure: String?
    @Namespace private var glass

    private enum Job {
        case export
        case share
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsStatus {
                status
                    .id(statusKey)
                    .transition(AnyTransition(.blurReplace))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
                HStack(spacing: GlassMetrics.gap) {
                    if model.canShareToCloud {
                        shareCapsule
                        if let link = finishedShareLink, !isShareRunning, !isExportRunning {
                            GlassIconButton(
                                systemImage: "link",
                                help: "Copy Link Again",
                                size: GlassMetrics.actionHeight
                            ) {
                                copy(link)
                                flashShare("Copied")
                            }
                            .glassEffectID("copyLink", in: glass)
                        }
                    }

                    exportCapsule

                    if let url = finishedExportURL, !isExportRunning, !isShareRunning {
                        GlassIconButton(
                            systemImage: "folder",
                            help: "Show in Finder",
                            size: GlassMetrics.actionHeight
                        ) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .glassEffectID("reveal", in: glass)
                    }
                }
            }
        }
        .padding(.horizontal, InspectorMetrics.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .motion(.morph, value: layoutKey)
        .motion(.morphQuick, value: statusKey)
        .task(id: statusKey) {
            guard case .failed(let message) = currentStatus else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            expiredFailure = message
        }
        .onChange(of: model.exportState) { _, state in
            lastJob = .export
            expiredFailure = nil
            if case .finished = state { flashExport("Exported") }
        }
        .onChange(of: model.shareState) { _, state in
            lastJob = .share
            expiredFailure = nil
            if case .finished = state { flashShare("Link Copied") }
        }
    }

    // MARK: Capsules

    private var exportCapsule: some View {
        GlassActionCapsule(
            title: "Export",
            systemImage: "arrow.down.circle",
            progress: exportProgress,
            flash: exportFlash,
            isProminent: true,
            isCollapsed: isShareRunning
        ) {
            if isExportRunning {
                model.cancelExport()
            } else {
                isExportOptionsPresented = true
            }
        }
        .disabled(!model.isLoaded || isShareRunning)
        .keyboardShortcut("e", modifiers: .command)
        .glassEffectID("export", in: glass)
        .popover(isPresented: $isExportOptionsPresented, arrowEdge: .top) {
            RecordingExportOptionsPopover(
                initialSettings: model.exportSettings,
                onConfirm: model.export(settings:)
            )
        }
    }

    private var shareCapsule: some View {
        GlassActionCapsule(
            title: "Share",
            systemImage: "link",
            progress: shareProgress?.progress,
            stage: shareProgress?.stage,
            flash: shareFlash,
            isCollapsed: isExportRunning
        ) {
            if isShareRunning {
                model.cancelShare()
            } else {
                isShareOptionsPresented = true
            }
        }
        .disabled(!model.isLoaded || isExportRunning)
        .glassEffectID("share", in: glass)
        .popover(isPresented: $isShareOptionsPresented, arrowEdge: .top) {
            CloudUploadOptionsPopover(
                suggestedTitle: model.projectDisplayName,
                onConfirm: model.shareToCloud
            )
        }
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        switch currentStatus {
        case .summary(let text):
            // The format is a setting, so it opens where it's set.
            Button {
                isExportOptionsPresented = true
            } label: {
                HStack(spacing: 3) {
                    statusLine(text, systemImage: nil, tint: nil)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isExportRunning || isShareRunning)
            .help("Export options")
        case .exported(let url):
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                statusLine("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill", tint: nil)
            }
            .buttonStyle(.plain)
            .help("Show \(url.lastPathComponent) in Finder")
        case .shared(let link):
            if let url = URL(string: link) {
                Link(destination: url) {
                    statusLine(Self.displayLink(link), systemImage: "checkmark.circle.fill", tint: nil)
                }
                .help("Open the share link in your browser")
            } else {
                statusLine("Link copied", systemImage: "checkmark.circle.fill", tint: nil)
            }
        case .failed(let message):
            statusLine(message, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                .help(message)
        }
    }

    private func statusLine(_ text: String, systemImage: String?, tint: Color?) -> some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint ?? .secondary)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private enum Status {
        case summary(String)
        case exported(URL)
        case shared(String)
        case failed(String)
    }

    private var currentStatus: Status {
        if isExportRunning || isShareRunning {
            return .summary(settingsSummary)
        }
        switch lastJob {
        case .export:
            if case .finished(let url) = model.exportState { return .exported(url) }
            if case .failed(let message) = model.exportState, expiredFailure != "Export failed: \(message)" {
                return .failed("Export failed: \(message)")
            }
        case .share:
            if case .finished(let link) = model.shareState { return .shared(link) }
            if case .failed(let message) = model.shareState, expiredFailure != "Share failed: \(message)" {
                return .failed("Share failed: \(message)")
            }
        }
        return .summary(settingsSummary)
    }

    /// Changes when the status line changes meaning, not on progress ticks.
    private var statusKey: String {
        switch currentStatus {
        case .summary(let text): "summary-\(text)"
        case .exported(let url): "exported-\(url.path)"
        case .shared(let link): "shared-\(link)"
        case .failed(let message): "failed-\(message)"
        }
    }

    /// Changes when a capsule changes shape, so the group morphs once per
    /// state instead of springing on every progress tick.
    private var layoutKey: String {
        [
            isExportRunning, isShareRunning,
            exportFlash != nil, shareFlash != nil,
            finishedExportURL != nil, finishedShareLink != nil
        ]
        .map { $0 ? "1" : "0" }
        .joined()
    }

    private var settingsSummary: String {
        let settings = model.exportSettings
        let resolution = settings.resolution == .original ? "Full size" : settings.resolution.rawValue
        return [
            settings.effectiveContainer.rawValue,
            resolution,
            settings.effectiveFrameRate.rawValue
        ].joined(separator: " · ")
    }

    // MARK: State

    private var isExportRunning: Bool {
        if case .exporting = model.exportState { return true }
        return false
    }

    private var isShareRunning: Bool {
        model.shareState.isBusy
    }

    private var exportProgress: Double? {
        if case .exporting(let progress) = model.exportState { return progress }
        return nil
    }

    private var shareProgress: (stage: String, progress: Double)? {
        switch model.shareState {
        case .rendering(let progress):
            return ("Rendering", progress)
        case .uploading:
            let progress = model.shareItemID.flatMap { CloudUploader.shared.uploadProgress[$0] } ?? 0
            return ("Uploading", progress)
        default:
            return nil
        }
    }

    private var finishedExportURL: URL? {
        if case .finished(let url) = model.exportState { return url }
        return nil
    }

    private var finishedShareLink: String? {
        if case .finished(let link) = model.shareState { return link }
        return nil
    }

    private func flashExport(_ text: String) {
        exportFlash = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            guard exportFlash == text else { return }
            exportFlash = nil
        }
    }

    private func flashShare(_ text: String) {
        shareFlash = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            guard shareFlash == text else { return }
            shareFlash = nil
        }
    }

    private func copy(_ link: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    private static func displayLink(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host() else { return link }
        return host + url.path()
    }
}

/// The determinate ring for small inline progress, such as the audio-only
/// export button.
struct StudioProgressRing: View {
    let progress: Double

    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, progress)))
                .stroke(Palette.highlight, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.15), value: progress)
    }
}
