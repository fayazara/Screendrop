//
//  SettingsHistoryPane.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct SettingsHistoryPane: View {
    @State private var historyStore = ScreenshotHistoryStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if historyStore.items.isEmpty {
                    ContentUnavailableView(
                        "No Captures",
                        systemImage: "photo.stack",
                        description: Text("Captured screenshots and recordings will appear here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    Text("\(historyStore.items.count) capture\(historyStore.items.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    LazyVStack(spacing: 0) {
                        ForEach(historyStore.items) { item in
                            SettingsHistoryItemRow(
                                item: item,
                                onPreview: {
                                    QuickLookPreviewPresenter.show(url: item.url)
                                },
                                onCopy: {
                                    if item.isVideo {
                                        try? VideoFileActions.copyToClipboard(from: item.url)
                                    } else {
                                        try? ScreenshotFileActions.copyPNGToClipboard(from: item.url)
                                    }
                                },
                                onEdit: {
                                    QuickLookPreviewPresenter.dismiss()
                                    if item.isVideo {
                                        openWindow(id: "VIDEO_EDITOR", value: item.url)
                                    } else {
                                        openWindow(id: "ANNOTATION_EDITOR", value: item.url)
                                    }
                                },
                                onUpload: {
                                    uploadHistoryItem(item)
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
                }
            }
        }
        .scrollEdgeEffectSoftIfAvailable()
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    historyStore.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh history")
            }
        }
        .onAppear {
            historyStore.reload()
        }
    }

    private func uploadHistoryItem(_ item: ScreenshotHistoryItem) {
        Task {
            do {
                let result = try await CloudUploader.shared.upload(itemID: item.id, fileURL: item.url)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.url, forType: .string)
                ScreenshotHistoryStore.shared.setCloudURL(for: item.url, cloudURL: result.url)
            } catch {
                print("Cloud upload from history failed: \(error)")
            }
        }
    }
}

private struct SettingsHistoryItemRow: View {
    let item: ScreenshotHistoryItem
    let onPreview: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onUpload: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: NSImage?
    @State private var cloudUploader = CloudUploader.shared
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            // Thumbnail
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
            .overlay {
                if item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.9), .black.opacity(0.35))
                        .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
                }
            }

            // File info
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(itemSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 12)

            // Inline actions (visible on hover)
            HStack(spacing: 2) {
                if item.cloudURL != nil {
                    Button(action: copyCloudURL) {
                        Image(systemName: "link")
                    }
                    .help("Copy cloud link")
                } else if cloudUploader.isConfigured {
                    if cloudUploader.uploadingItems.contains(item.id) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 20, height: 20)
                    } else {
                        Button(action: onUpload) {
                            Image(systemName: "icloud.and.arrow.up")
                        }
                        .help("Upload to cloud")
                    }
                }

                Button(action: onPreview) {
                    Image(systemName: "eye")
                }
                .help("Quick Look")

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy")
            }
            .buttonStyle(.borderless)
            .imageScale(.medium)
            .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button("Quick Look", systemImage: "eye") { onPreview() }
            Button("Copy", systemImage: "doc.on.doc") { onCopy() }
            Button(item.isVideo ? "Edit Recording" : "Annotate", systemImage: item.isVideo ? "scissors" : "pencil.tip.crop.circle") { onEdit() }

            Divider()

            if item.cloudURL != nil {
                Button("Copy Cloud Link", systemImage: "link") { copyCloudURL() }
            } else if cloudUploader.isConfigured && !cloudUploader.uploadingItems.contains(item.id) {
                Button("Upload to Cloud", systemImage: "icloud.and.arrow.up") { onUpload() }
            }

            Button("Reveal in Finder", systemImage: "folder") { onReveal() }

            Divider()

            Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
        }
        .task(id: item.fileName) {
            let url = item.url
            let isVideo = item.isVideo
            let image = await Task.detached(priority: .userInitiated) {
                if isVideo {
                    return await VideoPreviewImageLoader.thumbnail(at: url, maxPixelSize: 160)
                } else {
                    return ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: 160)
                }
            }.value
            thumbnail = image
        }
    }

    private func copyCloudURL() {
        guard let cloudURL = item.cloudURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cloudURL, forType: .string)
    }

    private var itemSubtitle: String {
        let date = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        if item.isVideo {
            let durationStr = item.duration.map { formatDuration($0) } ?? "unknown"
            if item.pixelWidth > 0 && item.pixelHeight > 0 {
                return "\(date) \u{00B7} \(item.pixelWidth)\u{00D7}\(item.pixelHeight) \u{00B7} \(durationStr)"
            }
            return "\(date) \u{00B7} \(durationStr)"
        }
        return "\(date) \u{00B7} \(item.pixelWidth)\u{00D7}\(item.pixelHeight)"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
