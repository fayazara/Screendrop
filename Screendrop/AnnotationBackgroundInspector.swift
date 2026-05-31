//
//  AnnotationBackgroundInspector.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct AnnotationBackgroundInspector: View {
    @Binding var settings: AnnotationBackgroundSettings
    let onPickWallpaper: () -> Void

    private let swatchColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
    private let alignmentColumns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 3)

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

            swatchGroup("Wallpaper") {
                if let customWallpaper {
                    AnnotationSwatchTile(
                        isSelected: settings.style == .customWallpaper(AnnotationCustomWallpaper(url: customWallpaper.url))
                    ) {
                        settings.customWallpaper = AnnotationCustomWallpaper(url: customWallpaper.url)
                        settings.style = .customWallpaper(AnnotationCustomWallpaper(url: customWallpaper.url))
                    } content: {
                        AnnotationCustomWallpaperPreview(wallpaper: AnnotationCustomWallpaper(url: customWallpaper.url))
                    }
                    .help(customWallpaper.title)
                }

                AnnotationAddSwatchTile(action: onPickWallpaper)
                    .help("Choose wallpaper")
            }

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

/// "Add wallpaper" tile that matches the swatch geometry but uses a dashed
/// outline and never shows a selection ring.
private struct AnnotationAddSwatchTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                .foregroundStyle(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(2.5)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
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
