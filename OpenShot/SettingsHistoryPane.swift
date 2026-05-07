//
//  SettingsHistoryPane.swift
//  OpenShot
//

import AppKit
import SwiftUI

struct SettingsHistoryPane: View {
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
