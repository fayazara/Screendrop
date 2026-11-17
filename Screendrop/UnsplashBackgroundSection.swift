//
//  UnsplashBackgroundSection.swift
//  Screendrop
//
//  Unsplash in the shared background picker: Unsplash's Wallpapers topic
//  until the user searches, then their results, a page at a time. Choosing a
//  photo downloads it into the Wallpapers folder and applies it like any
//  other wallpaper. Every photo carries its photographer's credit.
//

import AppKit
import Observation
import SwiftUI

/// Results outlive the popover, so reopening it costs no requests: a new
/// key starts at 50 an hour.
@MainActor
@Observable
final class UnsplashBrowser {
    static let shared = UnsplashBrowser()

    var query = ""
    private(set) var photos: [UnsplashPhoto] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var downloadingID: String?
    /// Bumped when the user saves a key, since UserDefaults isn't observed.
    private(set) var keyRevision = 0
    /// The query the results are for; nil before the first load.
    private var loadedQuery: String?
    private var page = 0
    private var loadTask: Task<Void, Never>?

    var hasKey: Bool {
        _ = keyRevision
        return UnsplashClient.accessKey != nil
    }

    static var directory: URL {
        AnnotationWallpaperStore.wallpapersDirectory.appendingPathComponent("Unsplash", isDirectory: true)
    }

    func loadIfNeeded() {
        guard hasKey, loadedQuery == nil, !isLoading else { return }
        submit()
    }

    func submit() {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasKey, query != loadedQuery || errorMessage != nil else { return }
        loadTask?.cancel()
        loadedQuery = query
        photos = []
        page = 0
        load()
    }

    func loadMore() {
        guard hasMore, !isLoading else { return }
        load()
    }

    func saveKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        UserDefaults.standard.set(key, forKey: UnsplashClient.userKeyDefaultsKey)
        keyRevision += 1
        loadedQuery = nil
        errorMessage = nil
        loadIfNeeded()
    }

    /// The photo as a local file, or nil if it couldn't be downloaded.
    func download(_ photo: UnsplashPhoto) async -> URL? {
        guard downloadingID == nil else { return nil }
        downloadingID = photo.id
        defer { downloadingID = nil }
        do {
            errorMessage = nil
            return try await UnsplashClient.download(photo, to: Self.directory)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func load() {
        let query = loadedQuery ?? ""
        let nextPage = page + 1
        isLoading = true
        errorMessage = nil
        loadTask = Task {
            do {
                let result = try await UnsplashClient.photos(query: query, page: nextPage)
                guard !Task.isCancelled else { return }
                let known = Set(photos.map(\.id))
                photos += result.photos.filter { !known.contains($0.id) }
                hasMore = result.hasMore
                page = nextPage
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                if (error as? UnsplashClient.ClientError) == .invalidKey { loadedQuery = nil }
            }
            isLoading = false
        }
    }
}

struct UnsplashBackgroundSection: View {
    /// The wallpaper showing now, to mark its photo.
    let selectedURL: URL?
    let onSelect: (URL) -> Void

    @State private var browser = UnsplashBrowser.shared
    @State private var keyDraft = ""
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7, alignment: .top), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
            HStack(spacing: 8) {
                InspectorGroupLabel("Unsplash")
                Spacer(minLength: 0)
                Link(destination: UnsplashClient.unsplashURL) {
                    HStack(spacing: 3) {
                        Text("Photos from Unsplash")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if browser.hasKey {
                searchField
                results
            } else {
                keyForm
            }

            if let errorMessage = browser.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.record)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { browser.loadIfNeeded() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search photos", text: $browser.query)
                .textFieldStyle(.plain)
                .font(.inspectorValue)
                .onSubmit { browser.submit() }
            if browser.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 8)
        .inspectorField()
    }

    @ViewBuilder
    private var results: some View {
        if !browser.photos.isEmpty {
            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(browser.photos) { photo in
                    UnsplashPhotoTile(
                        photo: photo,
                        isSelected: isSelected(photo),
                        isDownloading: browser.downloadingID == photo.id,
                        isEnabled: browser.downloadingID == nil
                    ) {
                        Task {
                            if let url = await browser.download(photo) { onSelect(url) }
                        }
                    }
                }
            }
            if browser.hasMore {
                Button(browser.isLoading ? "Loading…" : "Show More") { browser.loadMore() }
                    .buttonStyle(.plain)
                    .font(.inspectorLabel.weight(.medium))
                    .foregroundStyle(Palette.label)
                    .disabled(browser.isLoading)
            }
        } else if !browser.isLoading, browser.errorMessage == nil {
            Text("No photos found.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    /// Only for builds without a bundled key, such as one built from source.
    private var keyForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Unsplash Access Key", text: $keyDraft)
                    .textFieldStyle(.plain)
                    .font(.inspectorValue)
                    .onSubmit { browser.saveKey(keyDraft) }
                Button("Save") { browser.saveKey(keyDraft) }
                    .buttonStyle(.plain)
                    .font(.inspectorLabel.weight(.medium))
                    .foregroundStyle(Palette.label)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 8)
            .inspectorField()

            Link(destination: UnsplashClient.developersURL) {
                Text("This build has no Unsplash key. Create a free app on Unsplash and paste its Access Key.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func isSelected(_ photo: UnsplashPhoto) -> Bool {
        guard let selectedURL else { return false }
        return selectedURL.standardizedFileURL.deletingLastPathComponent().path
            == UnsplashBrowser.directory.standardizedFileURL.path
            && selectedURL.lastPathComponent.hasSuffix("(\(photo.id)).jpg")
    }
}

/// A result's thumbnail, with its photographer's name beneath as the link
/// Unsplash asks for.
private struct UnsplashPhotoTile: View {
    let photo: UnsplashPhoto
    let isSelected: Bool
    let isDownloading: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            InspectorTile(
                title: "Photo by \(photo.user.name) on Unsplash",
                aspectRatio: 1.35,
                isSelected: isSelected,
                action: action
            ) {
                // The placeholder sizes the tile; the photo only overlays
                // it, so a loaded image can't widen its grid column.
                Rectangle()
                    .fill(placeholder)
                    .overlay {
                        AsyncImage(url: photo.urls.small) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                    }
                    .overlay {
                        if isDownloading {
                            Rectangle().fill(.black.opacity(0.3))
                            ProgressView().controlSize(.small)
                        }
                    }
                    .clipped()
            }
            .disabled(!isEnabled && !isDownloading)

            Link(destination: photo.photographerURL) {
                Text(photo.user.name)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 3)
            .help("\(photo.user.name) on Unsplash")
        }
    }

    private var placeholder: Color {
        guard let hex = photo.color?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
              hex.count == 6, let value = Int(hex, radix: 16) else { return Color.primary.opacity(0.08) }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
