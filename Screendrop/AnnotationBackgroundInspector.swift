//
//  AnnotationBackgroundInspector.swift
//  Screendrop
//

import AppKit
import SwiftUI

private enum AnnotationBackgroundFillLibrary: CaseIterable, Hashable {
    case color
    case gradient
    case wallpaper

    var title: String {
        switch self {
        case .color: String(localized: "Color")
        case .gradient: String(localized: "Gradient")
        case .wallpaper: String(localized: "Wallpaper")
        }
    }
}

struct AnnotationBackgroundInspector: View {
    @Binding var settings: AnnotationBackgroundSettings
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    let onEditorAction: () -> Void
    let onPickWallpaper: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupSpacing) {
            InspectorBackgroundFillPicker(
                style: $settings.style,
                rememberedWallpaper: settings.customWallpaper,
                wallpaperStore: wallpaperStore,
                onEditorAction: onEditorAction,
                onPickWallpaper: onPickWallpaper,
                onSelectWallpaper: { settings.customWallpaper = $0 }
            )

            innerDivider

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Layout")

                InspectorFieldPair {
                    InspectorSlider(
                        "Padding",
                        value: $settings.padding,
                        range: 0.04...0.45,
                        format: .percent()
                    )
                } trailing: {
                    InspectorSlider(
                        "Corners",
                        value: $settings.cornerRadius,
                        range: 0...0.12,
                        format: .percent()
                    )
                }
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Shadow")

                InspectorSlider(
                    "Amount",
                    value: $settings.shadow,
                    range: 0...1,
                    format: .percent()
                )

                InspectorSegmented(
                    options: AnnotationShadowStyle.allCases,
                    isSelected: { $0 == settings.shadowStyle },
                    onTap: {
                        onEditorAction()
                        settings.shadowStyle = $0
                    },
                    label: { style in
                        Text(style.title)
                            .font(.inspectorSegment)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                )
                .opacity(settings.shadow > 0 ? 1 : 0.45)
            }

            InspectorRow("Alignment") {
                AlignmentPositionPicker(
                    alignment: $settings.alignment,
                    isEnabled: !settings.camera.hasEffect,
                    onEditorAction: onEditorAction
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Aspect ratio")

                InspectorSegmented(
                    options: AnnotationBackgroundAspectRatio.allCases,
                    isSelected: { $0 == settings.aspectRatio },
                    onTap: {
                        onEditorAction()
                        settings.aspectRatio = $0
                    },
                    label: { ratio in
                        Text(ratio.title)
                            .font(.inspectorSegment)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                )
            }
        }
    }

    private var innerDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.4))
            .frame(height: 0.5)
            .padding(.vertical, 2)
    }
}

/// The background fill browser shared by the annotator and Studio: a
/// Color / Gradient / Wallpaper library switch over tile grids, with recent
/// wallpapers, built-in packs and an add tile.
struct InspectorBackgroundFillPicker: View {
    @Binding var style: AnnotationBackgroundStyle
    /// A wallpaper to keep visible in Recent even when the fill is currently
    /// a color or gradient.
    let rememberedWallpaper: AnnotationCustomWallpaper?
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    let onEditorAction: () -> Void
    let onPickWallpaper: () -> Void
    var onSelectWallpaper: (AnnotationCustomWallpaper) -> Void = { _ in }

    private let swatchColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
    private static let maxVisibleRecentWallpapers = 4
    private let recentWallpaperColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
    private let wallpaperColumns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 3)
    @State private var selectedWallpaperSourceID = AnnotationWallpaperSource.recentID
    @State private var selectedFillLibrary = AnnotationBackgroundFillLibrary.color

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSegmented(
                options: AnnotationBackgroundFillLibrary.allCases,
                isSelected: { $0 == selectedFillLibrary },
                onTap: { library in
                    withAnimation(.snappy(duration: 0.16)) {
                        selectedFillLibrary = library
                    }
                },
                label: { library in
                    Text(library.title)
                        .font(.inspectorSegment)
                }
            )

            selectedFillPicker
                .transition(.opacity)
        }
        .onAppear {
            syncFillLibrary(with: style)
        }
        .onChange(of: style) { _, style in
            syncFillLibrary(with: style)
        }
    }

    private var customWallpaper: AnnotationCustomWallpaper? {
        if case .customWallpaper(let wallpaper) = style {
            return wallpaper
        }
        return rememberedWallpaper
    }

    @ViewBuilder
    private var selectedFillPicker: some View {
        switch selectedFillLibrary {
        case .color:
            LazyVGrid(columns: swatchColumns, spacing: 6) {
                ForEach(AnnotationBackgroundColor.plainPresets) { color in
                    InspectorTile(title: color.title, isSelected: style == .solid(color)) {
                        onEditorAction()
                        style = .solid(color)
                    } content: {
                        Rectangle().fill(color.color)
                    }
                }
                InspectorCustomBackgroundColorTile(style: $style, onSelect: onEditorAction)
            }

        case .gradient:
            LazyVGrid(columns: swatchColumns, spacing: 6) {
                ForEach(AnnotationBackgroundGradient.presets) { gradient in
                    InspectorTile(title: gradient.title, isSelected: style == .gradient(gradient)) {
                        onEditorAction()
                        style = .gradient(gradient)
                    } content: {
                        Rectangle().fill(LinearGradient(
                            colors: gradient.colors.map(\.color),
                            startPoint: gradient.startPoint,
                            endPoint: gradient.endPoint
                        ))
                    }
                }
            }

        case .wallpaper:
            wallpaperGroup
        }
    }

    private func syncFillLibrary(with style: AnnotationBackgroundStyle) {
        switch style {
        case .none:
            break
        case .solid:
            selectedFillLibrary = .color
        case .gradient:
            selectedFillLibrary = .gradient
        case .customWallpaper:
            selectedFillLibrary = .wallpaper
        }
    }

    @ViewBuilder
    private var wallpaperGroup: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
            InspectorSegmented(
                options: wallpaperSources.map(\.id),
                isSelected: { $0 == selectedWallpaperSourceID },
                onTap: { id in
                    onEditorAction()
                    withAnimation(.snappy(duration: 0.16)) {
                        selectedWallpaperSourceID = id
                    }
                },
                label: { id in
                    Text(title(forSourceID: id))
                        .font(.inspectorSegment)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            )

            if selectedWallpaperSourceID == AnnotationWallpaperSource.recentID {
                recentWallpaperGrid
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
                    wallpaperGrid(wallpapers)
                }

                AnnotationWallpaperCreditView(pack: pack)
            }
        }
    }

    private var wallpaperSources: [AnnotationWallpaperSourceOption] {
        [AnnotationWallpaperSourceOption.recent]
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
        if let customWallpaper, wallpaperStore.isAvailable(customWallpaper) {
            let selectedURL = customWallpaper.url.standardizedFileURL
            if let selectedIndex = wallpapers.firstIndex(where: {
                $0.url.standardizedFileURL == selectedURL
            }) {
                if selectedIndex >= Self.maxVisibleRecentWallpapers {
                    wallpapers.remove(at: selectedIndex)
                    wallpapers.insert(customWallpaper, at: 0)
                }
            } else {
                wallpapers.insert(customWallpaper, at: 0)
            }
        }
        return Array(wallpapers.prefix(Self.maxVisibleRecentWallpapers))
    }

    private var recentWallpaperGrid: some View {
        LazyVGrid(columns: recentWallpaperColumns, spacing: 6) {
            wallpaperTiles(visibleRecentWallpapers)

            AnnotationAddWallpaperTile {
                onEditorAction()
                onPickWallpaper()
            }
                .help("Choose wallpaper")
        }
    }

    @ViewBuilder
    private func wallpaperGrid(_ wallpapers: [AnnotationCustomWallpaper]) -> some View {
        LazyVGrid(columns: wallpaperColumns, spacing: 7) {
            wallpaperTiles(wallpapers)
        }
    }

    @ViewBuilder
    private func wallpaperTiles(_ wallpapers: [AnnotationCustomWallpaper]) -> some View {
        ForEach(wallpapers) { wallpaper in
            InspectorTile(
                title: wallpaper.title,
                aspectRatio: 1.35,
                isSelected: isSelectedWallpaper(wallpaper)
            ) {
                selectWallpaper(wallpaper)
            } content: {
                AnnotationCustomWallpaperPreview(wallpaper: wallpaper)
            }
        }
    }

    private func selectWallpaper(_ wallpaper: AnnotationCustomWallpaper) {
        onEditorAction()
        wallpaperStore.addRecentWallpaper(wallpaper.url)
        onSelectWallpaper(wallpaper)
        style = .customWallpaper(wallpaper)
    }

    private func isSelectedWallpaper(_ wallpaper: AnnotationCustomWallpaper) -> Bool {
        guard case .customWallpaper(let selectedWallpaper) = style else { return false }
        return selectedWallpaper.url.standardizedFileURL == wallpaper.url.standardizedFileURL
    }

}

struct AnnotationWatermarkInspector: View {
    @Binding var settings: AnnotationWatermarkSettings
    let focusedField: FocusState<AnnotationEditorFocusedField?>.Binding
    let onFocusCleared: () -> Void

    @State private var isTextEditing = false

    private var watermarkText: Binding<String> {
        Binding(
            get: { settings.text },
            set: { text in
                settings.text = text
                settings.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        )
    }

    /// The watermark stores its own color type; the shared swatch strip
    /// speaks `AnnotationSwatch`, so presets match by value and anything else
    /// shows in the custom well.
    private var watermarkSwatch: AnnotationSwatch {
        let color = settings.color
        return AnnotationSwatch.allCases.first {
            abs($0.red - color.red) < 0.002
                && abs($0.green - color.green) < 0.002
                && abs($0.blue - color.blue) < 0.002
        } ?? .custom(from: color.nsColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if isTextEditing {
                watermarkTextField
            } else {
                watermarkActivationButton
            }

            if hasWatermarkText {
                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    InspectorFieldPair {
                        InspectorSlider(
                            "Density",
                            value: $settings.density,
                            range: 2...10,
                            format: .integer
                        )
                    } trailing: {
                        InspectorSlider(
                            "Size",
                            value: $settings.fontSize,
                            range: 8...160,
                            format: .pixels
                        )
                    }

                    InspectorFieldPair {
                        InspectorSlider(
                            "Angle",
                            value: $settings.rotationDegrees,
                            range: -90...90,
                            format: .degrees()
                        )
                    } trailing: {
                        InspectorSlider(
                            "Opacity",
                            value: $settings.opacity,
                            range: 0...0.75,
                            format: .percent()
                        )
                    }

                    InspectorRow("Color") {
                        AnnotationSwatchStrip(selectedSwatch: watermarkSwatch) { swatch in
                            settings.color = AnnotationWatermarkColor(
                                red: swatch.red,
                                green: swatch.green,
                                blue: swatch.blue
                            )
                        }
                    }
                }
                .disabled(!settings.isEnabled)
                .opacity(settings.isEnabled ? 1 : 0.48)
            }
        }
        .onChange(of: focusedField.wrappedValue) { _, newValue in
            guard newValue != .watermarkText else { return }
            isTextEditing = false
        }
    }

    private var watermarkActivationButton: some View {
        Button(action: beginTextEditing) {
            HStack(spacing: 7) {
                Image(systemName: hasWatermarkText ? "textformat" : "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                Text(hasWatermarkText ? settings.text : String(localized: "Add watermark"))
                    .font(.inspectorValue)
                    .foregroundColor(hasWatermarkText ? Color.primary.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: hasWatermarkText ? "pencil" : "chevron.right")
                    .font(.system(size: hasWatermarkText ? 10 : 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .inspectorField()
        }
        .buttonStyle(.plain)
        .help(hasWatermarkText ? "Edit watermark text" : "Add watermark")
    }

    private var watermarkTextField: some View {
        TextField("Watermark text", text: watermarkText)
            .focused(focusedField, equals: .watermarkText)
            .onSubmit(finishTextEditing)
            .textFieldStyle(.plain)
            .font(.inspectorValue)
            .padding(.horizontal, 8)
            .inspectorField()
            .onAppear {
                focusedField.wrappedValue = .watermarkText
            }
            .onClickOutside(enabled: true, perform: finishTextEditing)
    }

    private var hasWatermarkText: Bool {
        !settings.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func beginTextEditing() {
        isTextEditing = true
    }

    private func finishTextEditing() {
        isTextEditing = false
        focusedField.wrappedValue = nil
        onFocusCleared()
    }

}

private enum AnnotationWallpaperSource {
    static let recentID = "recent"
}

private struct AnnotationWallpaperSourceOption: Identifiable, Hashable {
    let id: String
    let title: String

    static let recent = AnnotationWallpaperSourceOption(
        id: AnnotationWallpaperSource.recentID,
        title: String(localized: "Recent")
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
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
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

private struct AlignmentPositionPicker: View {
    @Binding var alignment: AnnotationBackgroundAlignment
    let isEnabled: Bool
    let onEditorAction: () -> Void

    private let size: CGFloat = 44
    private let markerSize: CGFloat = 6
    private let cellSize: CGFloat = 12
    private let spacing: CGFloat = 2

    @State private var hoveredAlignment: AnnotationBackgroundAlignment?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: InspectorMetrics.sliderRadius,
            style: .continuous
        )
        let columns = Array(
            repeating: GridItem(.fixed(cellSize), spacing: spacing),
            count: 3
        )

        LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(AnnotationBackgroundAlignment.allCases) { option in
                Button {
                    onEditorAction()
                    withAnimation(accessibilityReduceMotion ? nil : .snappy(duration: 0.18)) {
                        alignment = option
                    }
                } label: {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(markerFill(for: option))
                        .frame(width: markerSize, height: markerSize)
                        .frame(width: cellSize, height: cellSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(!isEnabled)
                .help(option.title)
                .onHover { isHovering in
                    guard isEnabled else {
                        hoveredAlignment = nil
                        return
                    }
                    if isHovering {
                        hoveredAlignment = option
                    } else if hoveredAlignment == option {
                        hoveredAlignment = nil
                    }
                }
                .accessibilityLabel("\(option.title) alignment")
                .accessibilityValue(displayedAlignment == option ? "Selected" : "")
                .accessibilityAddTraits(displayedAlignment == option ? .isSelected : [])
            }
        }
        .padding(InspectorMetrics.controlInset)
        .frame(width: size, height: size)
        .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
        .clipShape(shape)
        .opacity(isEnabled ? 1 : 0.46)
        .help(isEnabled ? "Image alignment" : "Reset Camera to use alignment")
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                hoveredAlignment = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image alignment")
    }

    private var displayedAlignment: AnnotationBackgroundAlignment {
        isEnabled ? alignment : .center
    }

    private func markerFill(for option: AnnotationBackgroundAlignment) -> Color {
        if displayedAlignment == option {
            return InspectorControlPalette.selectedForeground
        }
        if hoveredAlignment == option {
            return Color.primary.opacity(0.48)
        }
        return Color.primary.opacity(0.22)
    }
}
