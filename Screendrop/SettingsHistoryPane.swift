//
//  SettingsHistoryPane.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct SettingsHistoryPane: View {
    @State private var historyStore = ScreenshotHistoryStore.shared
    @State private var cloudUploader = CloudUploader.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if historyStore.items.isEmpty {
                ContentUnavailableView(
                    "No Captures",
                    systemImage: "photo.stack",
                    description: Text("Captured screenshots and recordings will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("\(historyStore.items.count) capture\(historyStore.items.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                SettingsHistoryTable(
                    items: historyStore.items,
                    isCloudConfigured: cloudUploader.isConfigured,
                    uploadingItems: cloudUploader.uploadingItems,
                    onPreview: { item in
                        QuickLookPreviewPresenter.show(url: item.url)
                    },
                    onCopy: { item in
                        if item.isVideo {
                            try? VideoFileActions.copyToClipboard(from: item.url)
                        } else {
                            try? ScreenshotFileActions.copyPNGToClipboard(from: item.url)
                        }
                    },
                    onEdit: { item in
                        QuickLookPreviewPresenter.dismiss()
                        if item.isVideo {
                            openWindow(id: "VIDEO_EDITOR", value: item.url)
                        } else {
                            openWindow(id: "ANNOTATION_EDITOR", value: item.url)
                        }
                    },
                    onUpload: { item in
                        uploadHistoryItem(item)
                    },
                    onReveal: { item in
                        historyStore.reveal(item)
                    },
                    onDelete: { item in
                        historyStore.delete(item)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
