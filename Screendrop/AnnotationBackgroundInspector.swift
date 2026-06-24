//
//  AnnotationBackgroundInspector.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct AnnotationBackgroundInspector: View {
    @Binding var settings: AnnotationBackgroundSettings
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    let onPickWallpaper: () -> Void

    private let swatchColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
    private let wallpaperColumns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 3)
    private let alignmentColumns = Array(repeating: GridItem(.fixed(30), spacing: 5), count: 3)
    @State private var selectedWallpaperSourceID = AnnotationWallpaperSource.recentID

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Fills
            swatchGroup("Color") {
                ForEach(AnnotationBackgroundColor.plainPresets) { color in
                    InspectorTile(isSelected: settings.style == .solid(color)) {
                        settings.style = .solid(color)
                    } content: {
                        Rectangle().fill(color.color)
                    }
                    .help(color.title)
                }
            }

            swatchGroup("Gradient") {
                ForEach(AnnotationBackgroundGradient.presets) { gradient in
                    InspectorTile(isSelected: settings.style == .gradient(gradient)) {
                        settings.style = .gradient(gradient)
                    } content: {
                        Rectangle().fill(LinearGradient(
                            colors: gradient.colors.map(\.color),
                            startPoint: gradient.startPoint,
                            endPoint: gradient.endPoint
                        ))
                    }
                    .help(gradient.title)
                }
            }

            wallpaperGroup

            innerDivider

            // Layout
            InspectorSlider(
                "Padding",
                value: $settings.padding,
                range: 0.04...0.45,
                formatted: percentText
            )

            HStack(alignment: .top, spacing: 14) {
                InspectorSlider(
                    "Shadow",
                    value: $settings.shadow,
                    range: 0...1,
                    formatted: percentText
                )

                InspectorSlider(
                    "Corners",
                    value: $settings.cornerRadius,
                    range: 0...0.12,
                    formatted: percentText
                )
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Alignment")

                LazyVGrid(columns: alignmentColumns, spacing: 5) {
                    ForEach(AnnotationBackgroundAlignment.allCases) { alignment in
                        Button {
                            settings.alignment = alignment
                        } label: {
                            AlignmentGlyph(alignment: alignment, isSelected: settings.alignment == alignment)
                        }
                        .buttonStyle(.plain)
                        .help(alignment.title)
                    }
                }
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Aspect ratio")

                InspectorSegmented(
                    options: AnnotationBackgroundAspectRatio.allCases,
                    isSelected: { $0 == settings.aspectRatio },
                    onTap: { settings.aspectRatio = $0 },
                    label: { ratio in
                        Text(ratio.title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                )
            }
        }
    }

    private func percentText(_ value: CGFloat) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private var innerDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.4))
            .frame(height: 0.5)
            .padding(.vertical, 2)
    }

    private var customWallpaper: AnnotationCustomWallpaper? {
        settings.customWallpaper
    }

    @ViewBuilder
    private var wallpaperGroup: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
            InspectorGroupLabel("Wallpaper")

            InspectorSegmented(
                options: wallpaperSources.map(\.id),
                isSelected: { $0 == selectedWallpaperSourceID },
                onTap: { id in
                    withAnimation(.snappy(duration: 0.16)) {
                        selectedWallpaperSourceID = id
                    }
                },
                label: { id in
                    Text(title(forSourceID: id))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            )

            if selectedWallpaperSourceID == AnnotationWallpaperSource.recentID {
                wallpaperGrid(visibleRecentWallpapers, showsAddTile: true)
            } else if let pack = selectedPack {
                let wallpapers = wallpaperStore.wallpapers(for: pack)
                if wallpapers.isEmpty {
                    AnnotationWallpaperPackInstallView(
                        pack: pack,
                        isInstalling: wallpaperStore.isInstalling(pack),
                        errorMessage: wallpaperStore.errorMessage(for: pack)
                    ) {
                        Task { await wallpaperStore.installPack(pack) }
                    }
                } else {
                    wallpaperGrid(wallpapers, showsAddTile: false)
                }

                AnnotationWallpaperCreditView(pack: pack)
            }
        }
    }

    private var wallpaperSources: [AnnotationWallpaperSourceOption] {
        [AnnotationWallpaperSourceOption.local]
        + AnnotationWallpaperPack.builtIn.map { pack in
            AnnotationWallpaperSourceOption(id: pack.id, title: pack.title)
        }
    }

    private func title(forSourceID id: String) -> String {
        wallpaperSources.first { $0.id == id }?.title ?? id
    }

    private var selectedPack: AnnotationWallpaperPack? {
        AnnotationWallpaperPack.builtIn.first { $0.id == selectedWallpaperSourceID }
    }

    private var visibleRecentWallpapers: [AnnotationCustomWallpaper] {
        var wallpapers = wallpaperStore.recentWallpapers
        if let customWallpaper,
           wallpaperStore.isAvailable(customWallpaper),
           !wallpaperStore.isDownloadedPackWallpaper(customWallpaper),
           !wallpapers.contains(where: { $0.url.standardizedFileURL == customWallpaper.url.standardizedFileURL }) {
            wallpapers.insert(customWallpaper, at: 0)
        }
        return wallpapers
    }

    @ViewBuilder
    private func wallpaperGrid(_ wallpapers: [AnnotationCustomWallpaper], showsAddTile: Bool) -> some View {
        LazyVGrid(columns: wallpaperColumns, spacing: 7) {
            ForEach(wallpapers) { wallpaper in
                InspectorTile(
                    aspectRatio: 1.35,
                    isSelected: isSelectedWallpaper(wallpaper)
                ) {
                    selectWallpaper(wallpaper)
                } content: {
                    AnnotationCustomWallpaperPreview(wallpaper: wallpaper)
                }
                .help(wallpaper.title)
            }

            if showsAddTile {
                AnnotationAddWallpaperTile(action: onPickWallpaper)
                    .help("Choose wallpaper")
            }
        }
    }

    private func selectWallpaper(_ wallpaper: AnnotationCustomWallpaper) {
        settings.customWallpaper = wallpaper
        settings.style = .customWallpaper(wallpaper)
    }

    private func isSelectedWallpaper(_ wallpaper: AnnotationCustomWallpaper) -> Bool {
        guard case .customWallpaper(let selectedWallpaper) = settings.style else { return false }
        return selectedWallpaper.url.standardizedFileURL == wallpaper.url.standardizedFileURL
    }

    @ViewBuilder
    private func swatchGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
            InspectorGroupLabel(title)

            LazyVGrid(columns: swatchColumns, spacing: 6) {
                content()
            }
        }
    }
}

private enum AnnotationWallpaperSource {
    static let recentID = "recent"
}

private struct AnnotationWallpaperSourceOption: Identifiable, Hashable {
    let id: String
    let title: String

    static let local = AnnotationWallpaperSourceOption(
        id: AnnotationWallpaperSource.recentID,
        title: "Local"
    )
}

private struct AnnotationAddWallpaperTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                .foregroundStyle(.quaternary)
                .aspectRatio(1.35, contentMode: .fit)
                .overlay {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(2.5)
                .contentShape(RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// A tiny, unobtrusive credit linking to the wallpaper pack's author.
private struct AnnotationWallpaperCreditView: View {
    let pack: AnnotationWallpaperPack

    @State private var isHovering = false

    var body: some View {
        Link(destination: pack.authorURL) {
            HStack(spacing: 3) {
                Text("Wallpapers by \(pack.authorName)")
                    .underline(isHovering)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Open \(pack.authorName) on X")
        .onHover { isHovering = $0 }
        .padding(.top, 2)
    }
}

private struct AnnotationWallpaperPackInstallView: View {
    let pack: AnnotationWallpaperPack
    let isInstalling: Bool
    let errorMessage: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack(spacing: 8) {
                    if isInstalling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Download \(pack.title)")
                            .font(.inspectorValue)
                            .foregroundStyle(.primary)
                        Text(pack.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .inspectorField(height: 40)
                .overlay {
                    if isHovering && !isInstalling {
                        RoundedRectangle(cornerRadius: InspectorMetrics.fieldRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isInstalling)
            .onHover { isHovering = $0 }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AlignmentGlyph: View {
    let alignment: AnnotationBackgroundAlignment
    let isSelected: Bool

    private let size = CGSize(width: 30, height: 24)
    private let marker = CGSize(width: 9, height: 7)
    private let inset: CGFloat = 4

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.clear : Color.primary.opacity(0.10),
                            lineWidth: 0.5
                        )
                )

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isSelected ? Color.white : Color.secondary.opacity(0.55))
                .frame(width: marker.width, height: marker.height)
                .position(markerPosition)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous))
    }

    /// Anchors the marker at the alignment point with symmetric insets so it
    /// never crowds an edge, and lands dead-center for `.center`.
    private var markerPosition: CGPoint {
        let minX = inset + marker.width / 2
        let maxX = size.width - inset - marker.width / 2
        let minY = inset + marker.height / 2
        let maxY = size.height - inset - marker.height / 2
        return CGPoint(
            x: minX + alignment.xFactor * (maxX - minX),
            y: minY + alignment.yFactor * (maxY - minY)
        )
    }
}
