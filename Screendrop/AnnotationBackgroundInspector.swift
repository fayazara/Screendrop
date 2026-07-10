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
        case .color: "Color"
        case .gradient: "Gradient"
        case .wallpaper: "Wallpaper"
        }
    }
}

struct AnnotationBackgroundInspector: View {
    @Binding var settings: AnnotationBackgroundSettings
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    let onEditorAction: () -> Void
    let onPickWallpaper: () -> Void

    private let swatchColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
    private static let maxVisibleRecentWallpapers = 4
    private let recentWallpaperColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
    private let wallpaperColumns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 3)
    @State private var selectedWallpaperSourceID = AnnotationWallpaperSource.recentID
    @State private var selectedFillLibrary = AnnotationBackgroundFillLibrary.color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Fill library")

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
                            .font(.system(size: 10.5, weight: .medium))
                    }
                )
            }

            selectedFillPicker
                .transition(.opacity)

            innerDivider

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Layout")

                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    InspectorSlider(
                        "Padding",
                        value: $settings.padding,
                        range: 0.04...0.45,
                        format: .percent()
                    )

                    InspectorSlider(
                        "Shadow",
                        value: $settings.shadow,
                        range: 0...1,
                        format: .percent()
                    )

                    InspectorSlider(
                        "Corners",
                        value: $settings.cornerRadius,
                        range: 0...0.12,
                        format: .percent()
                    )
                }
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Alignment")

                AlignmentPlacementPad(
                    alignment: $settings.alignment,
                    isEnabled: !settings.camera.hasEffect,
                    onEditorAction: onEditorAction
                )

                if settings.camera.hasEffect {
                    Text("Reset Camera to use alignment.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                )
            }
        }
        .onAppear {
            syncFillLibrary(with: settings.style)
        }
        .onChange(of: settings.style) { _, style in
            syncFillLibrary(with: style)
        }
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
    private var selectedFillPicker: some View {
        switch selectedFillLibrary {
        case .color:
            LazyVGrid(columns: swatchColumns, spacing: 6) {
                ForEach(AnnotationBackgroundColor.plainPresets) { color in
                    InspectorTile(isSelected: settings.style == .solid(color)) {
                        onEditorAction()
                        settings.style = .solid(color)
                    } content: {
                        Rectangle().fill(color.color)
                    }
                    .help(color.title)
                }
            }

        case .gradient:
            LazyVGrid(columns: swatchColumns, spacing: 6) {
                ForEach(AnnotationBackgroundGradient.presets) { gradient in
                    InspectorTile(isSelected: settings.style == .gradient(gradient)) {
                        onEditorAction()
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
                        .font(.system(size: 11, weight: .medium))
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
                aspectRatio: 1.35,
                isSelected: isSelectedWallpaper(wallpaper)
            ) {
                selectWallpaper(wallpaper)
            } content: {
                AnnotationCustomWallpaperPreview(wallpaper: wallpaper)
            }
            .help(wallpaper.title)
        }
    }

    private func selectWallpaper(_ wallpaper: AnnotationCustomWallpaper) {
        onEditorAction()
        wallpaperStore.addRecentWallpaper(wallpaper.url)
        settings.customWallpaper = wallpaper
        settings.style = .customWallpaper(wallpaper)
    }

    private func isSelectedWallpaper(_ wallpaper: AnnotationCustomWallpaper) -> Bool {
        guard case .customWallpaper(let selectedWallpaper) = settings.style else { return false }
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

    private var watermarkColor: Binding<Color> {
        Binding(
            get: { settings.color.color },
            set: { settings.color = .custom(from: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if isTextEditing {
                watermarkTextField
            } else {
                watermarkActivationButton
            }

            if hasWatermarkText {
                InspectorSlider(
                    "Density",
                    value: $settings.density,
                    range: 2...10,
                    format: .integer
                )

                InspectorSlider(
                    "Size",
                    value: $settings.fontSize,
                    range: 8...160,
                    format: .pixels
                )

                InspectorSlider(
                    "Angle",
                    value: $settings.rotationDegrees,
                    range: -90...90,
                    format: .degrees()
                )

                InspectorSlider(
                    "Opacity",
                    value: $settings.opacity,
                    range: 0...0.75,
                    format: .percent()
                )

                HStack(spacing: 10) {
                    Text("Color")
                        .font(.inspectorLabel)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    ColorPicker("", selection: watermarkColor, supportsOpacity: false)
                        .labelsHidden()
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
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

                Text(hasWatermarkText ? settings.text : "Add watermark")
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
            .inspectorField(height: 26)
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
            .inspectorField(height: 26)
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
        title: "Recent"
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

private struct AlignmentPlacementPad: View {
    @Binding var alignment: AnnotationBackgroundAlignment
    let isEnabled: Bool
    let onEditorAction: () -> Void

    private let stageInset: CGFloat = 16
    private let markerSize = CGSize(width: 56, height: 42)

    @State private var hoveredAlignment: AnnotationBackgroundAlignment?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let shape = RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )

            ZStack {
                shape.fill(InspectorControlPalette.trackFill(for: colorScheme))

                ForEach(AnnotationBackgroundAlignment.allCases) { option in
                    landingDot(for: option)
                        .position(markerPosition(for: option, in: size))
                }

                miniatureImage
                    .position(markerPosition(for: displayedAlignment, in: size))
                    .scaleEffect(isDisplayedCardActive ? 1.03 : 1)
                    .animation(movementAnimation, value: displayedAlignment)
                    .animation(hoverAnimation, value: hoveredAlignment)

                ForEach(AnnotationBackgroundAlignment.allCases) { option in
                    Button {
                        onEditorAction()
                        withAnimation(movementAnimation) {
                            alignment = option
                        }
                    } label: {
                        Color.clear
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .frame(
                        width: size.width / 3,
                        height: size.height / 3
                    )
                    .position(hitTargetPosition(for: option, in: size))
                    .disabled(!isEnabled)
                    .help(option.title)
                    .onHover { isHovering in
                        guard isEnabled else {
                            hoveredAlignment = nil
                            return
                        }
                        withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.10)) {
                            if isHovering {
                                hoveredAlignment = option
                            } else if hoveredAlignment == option {
                                hoveredAlignment = nil
                            }
                        }
                    }
                    .accessibilityLabel("\(option.title) alignment")
                    .accessibilityValue(alignment == option ? "Selected" : "")
                    .accessibilityAddTraits(alignment == option ? .isSelected : [])
                }
            }
            .overlay(shape.stroke(InspectorControlPalette.border, lineWidth: 0.5))
            .clipShape(shape)
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.46)
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

    private var isDisplayedCardActive: Bool {
        hoveredAlignment == displayedAlignment
    }

    private var movementAnimation: Animation? {
        accessibilityReduceMotion
            ? nil
            : .spring(response: 0.30, dampingFraction: 0.70)
    }

    private var hoverAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeOut(duration: 0.12)
    }

    private var miniatureImage: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.56 : 0.48))
            .frame(width: markerSize.width, height: markerSize.height)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 0.5)
            }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.24 : 0.12),
                radius: 2,
                y: 1
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func landingDot(for option: AnnotationBackgroundAlignment) -> some View {
        let isHovered = hoveredAlignment == option

        return Circle()
            .fill(
                isHovered
                    ? Color.primary.opacity(0.50)
                    : Color.primary.opacity(0.24)
            )
            .frame(width: isHovered ? 7 : 5, height: isHovered ? 7 : 5)
            .frame(width: 16, height: 16)
            .animation(hoverAnimation, value: isHovered)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func markerPosition(
        for option: AnnotationBackgroundAlignment,
        in size: CGSize
    ) -> CGPoint {
        let minX = stageInset + markerSize.width / 2
        let maxX = size.width - stageInset - markerSize.width / 2
        let minY = stageInset + markerSize.height / 2
        let maxY = size.height - stageInset - markerSize.height / 2
        return CGPoint(
            x: minX + option.xFactor * max(0, maxX - minX),
            y: minY + option.yFactor * max(0, maxY - minY)
        )
    }

    private func hitTargetPosition(
        for option: AnnotationBackgroundAlignment,
        in size: CGSize
    ) -> CGPoint {
        CGPoint(
            x: size.width / 6 + option.xFactor * size.width * 2 / 3,
            y: size.height / 6 + option.yFactor * size.height * 2 / 3
        )
    }

}
