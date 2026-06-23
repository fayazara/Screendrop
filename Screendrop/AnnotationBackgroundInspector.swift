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
    private let alignmentColumns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 3)
    @State private var selectedWallpaperSourceID = AnnotationWallpaperSource.recentID

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            swatchGroup("Color") {
                AnnotationSwatchTile(isSelected: settings.style == .none) {
                    settings.style = .none
                } content: {
                    AnnotationNoneSwatch()
                }
                .help("No background")

                ForEach(AnnotationBackgroundColor.plainPresets) { color in
                    AnnotationSwatchTile(isSelected: settings.style == .solid(color)) {
                        settings.style = .solid(color)
                    } content: {
                        Rectangle().fill(color.color)
                    }
                    .help(color.title)
                }
            }

            swatchGroup("Gradient") {
                ForEach(AnnotationBackgroundGradient.presets) { gradient in
                    AnnotationSwatchTile(isSelected: settings.style == .gradient(gradient)) {
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

            AnnotationInspectorHairline()
                .padding(.vertical, 2)

            AnnotationBackgroundSlider(
                title: "Padding",
                value: $settings.padding,
                range: 0.04...0.45
            )

            HStack(spacing: 12) {
                AnnotationBackgroundSlider(
                    title: "Shadow",
                    value: $settings.shadow,
                    range: 0...1
                )

                AnnotationBackgroundSlider(
                    title: "Corners",
                    value: $settings.cornerRadius,
                    range: 0...0.12
                )
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Alignment")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: alignmentColumns, spacing: 4) {
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

                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Ratio")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $settings.aspectRatio) {
                        ForEach(AnnotationBackgroundAspectRatio.allCases) { ratio in
                            Text(ratio.title).tag(ratio)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        }
    }

    private var customWallpaper: AnnotationCustomWallpaper? {
        settings.customWallpaper
    }

    @ViewBuilder
    private var wallpaperGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wallpaper")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            AnnotationWallpaperSourceSelector(
                sources: wallpaperSources,
                selection: $selectedWallpaperSourceID
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
            }
        }
    }

    private var wallpaperSources: [AnnotationWallpaperSourceOption] {
        [AnnotationWallpaperSourceOption.local]
        + AnnotationWallpaperPack.builtIn.map { pack in
            AnnotationWallpaperSourceOption(
                id: pack.id,
                title: pack.title,
                systemImage: "square.grid.2x2"
            )
        }
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
                AnnotationWallpaperTile(
                    wallpaper: wallpaper,
                    isSelected: isSelectedWallpaper(wallpaper)
                ) {
                    selectWallpaper(wallpaper)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

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
    let systemImage: String

    static let local = AnnotationWallpaperSourceOption(
        id: AnnotationWallpaperSource.recentID,
        title: "Local",
        systemImage: "photo"
    )
}

private struct AnnotationWallpaperSourceSelector: View {
    let sources: [AnnotationWallpaperSourceOption]
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(sources) { source in
                        sourceButton(source)
                    }
                }
                .padding(4)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            .padding(.horizontal, 1)
        }
        .scrollClipDisabled()
        .frame(height: 42)
    }

    private func sourceButton(_ source: AnnotationWallpaperSourceOption) -> some View {
        let isSelected = selection == source.id

        return Button {
            withAnimation(.snappy(duration: 0.16)) {
                selection = source.id
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: source.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(source.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .frame(minWidth: 86)
            .frame(height: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background {
            if isSelected {
                Capsule()
                    .fill(Color.accentColor)
            }
        }
        .accessibilityLabel(source.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A uniform background swatch: a rounded-square preview with a consistent
/// accent focus ring when selected. Used for every background option (none,
/// solid colors, gradients, wallpapers) so the picker reads as one control.
private struct AnnotationSwatchTile<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    private let cornerRadius: CGFloat = 7

    var body: some View {
        Button(action: action) {
            content()
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .padding(2.5)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: cornerRadius + 2.5, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Tile shown for the "None" option – a neutral square with a diagonal slash.
private struct AnnotationNoneSwatch: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .controlBackgroundColor))

            GeometryReader { proxy in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: proxy.size.height))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
                }
                .stroke(Color.secondary.opacity(0.55), lineWidth: 1.5)
            }
        }
    }
}

private struct AnnotationWallpaperTile: View {
    let wallpaper: AnnotationCustomWallpaper
    let isSelected: Bool
    let action: () -> Void

    private let cornerRadius: CGFloat = 7

    var body: some View {
        Button(action: action) {
            AnnotationCustomWallpaperPreview(wallpaper: wallpaper)
                .aspectRatio(1.35, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .padding(2.5)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: cornerRadius + 2.5, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct AnnotationAddWallpaperTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                .foregroundStyle(.quaternary)
                .aspectRatio(1.35, contentMode: .fit)
                .overlay {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(2.5)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct AnnotationWallpaperPackInstallView: View {
    let pack: AnnotationWallpaperPack
    let isInstalling: Bool
    let errorMessage: String?
    let action: () -> Void

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
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Download \(pack.title)")
                            .font(.system(size: 12, weight: .medium))
                        Text(pack.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isInstalling)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AnnotationInspectorHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.5))
            .frame(height: 0.5)
    }
}

struct AnnotationBackgroundSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(.accentColor)
        }
    }
}

private struct AlignmentGlyph: View {
    let alignment: AnnotationBackgroundAlignment
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
                )

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 7)
                .position(markerPosition)
        }
        .frame(width: 28, height: 22)
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var markerPosition: CGPoint {
        CGPoint(
            x: 6 + alignment.xFactor * 16,
            y: 5 + alignment.yFactor * 12
        )
    }
}
