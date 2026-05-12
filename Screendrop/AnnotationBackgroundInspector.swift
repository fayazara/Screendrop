//
//  AnnotationBackgroundInspector.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct AnnotationBackgroundInspector: View {
    @Binding var settings: AnnotationBackgroundSettings
    let onPickWallpaper: () -> Void

    private let gradientColumns = Array(repeating: GridItem(.flexible(minimum: 20), spacing: 5), count: 8)
    private let wallpaperColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    private let colorColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)
    private let alignmentColumns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                settings.style = .none
            } label: {
                Text("None")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(settings.style == .none ? .white : .primary.opacity(0.7))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(settings.style == .none ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .padding(.bottom, 16)

            backgroundSectionTitle("Gradients")
                .padding(.bottom, 8)
            LazyVGrid(columns: gradientColumns, spacing: 5) {
                ForEach(AnnotationBackgroundGradient.presets) { gradient in
                    Button {
                        settings.style = .gradient(gradient)
                    } label: {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(LinearGradient(
                                colors: gradient.colors.map(\.color),
                                startPoint: gradient.startPoint,
                                endPoint: gradient.endPoint
                            ))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(settings.style == .gradient(gradient) ? Color.white.opacity(0.8) : Color.white.opacity(0.08), lineWidth: settings.style == .gradient(gradient) ? 2 : 0.5)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(gradient.title)
                }
            }
            .padding(.bottom, 16)

            backgroundSectionTitle("Wallpapers")
                .padding(.bottom, 8)
            LazyVGrid(columns: wallpaperColumns, spacing: 8) {
                if let customWallpaper {
                    wallpaperButton(
                        style: .customWallpaper(AnnotationCustomWallpaper(url: customWallpaper.url)),
                        title: customWallpaper.title
                    ) {
                        AnnotationCustomWallpaperPreview(wallpaper: AnnotationCustomWallpaper(url: customWallpaper.url))
                    }
                }

                Button(action: onPickWallpaper) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(.quaternary)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Choose wallpaper")
            }
            .padding(.bottom, 16)

            backgroundSectionTitle("Plain color")
                .padding(.bottom, 8)
            LazyVGrid(columns: colorColumns, spacing: 8) {
                ForEach(AnnotationBackgroundColor.plainPresets) { color in
                    Button {
                        settings.style = .solid(color)
                    } label: {
                        Circle()
                            .fill(color.color)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                Circle()
                                    .stroke(settings.style == .solid(color) ? Color.white.opacity(0.9) : Color.white.opacity(0.1), lineWidth: settings.style == .solid(color) ? 2 : 0.5)
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(color.title)
                }
            }
            .padding(.bottom, 18)

            AnnotationBackgroundSlider(
                title: "Padding",
                value: $settings.padding,
                range: 0.04...0.45
            )
            .padding(.bottom, 14)

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
            .padding(.bottom, 14)

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

    private func wallpaperButton<Content: View>(
        style: AnnotationBackgroundStyle,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            if case .customWallpaper(let wallpaper) = style {
                settings.customWallpaper = wallpaper
            }
            settings.style = style
        } label: {
            content()
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(settings.style == style ? Color.white.opacity(0.8) : Color.white.opacity(0.08), lineWidth: settings.style == style ? 2 : 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func backgroundSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
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
