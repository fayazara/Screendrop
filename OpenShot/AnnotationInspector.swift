//
//  AnnotationInspector.swift
//  OpenShot
//

import AppKit
import SwiftUI

private struct AnnotationColorMenu: View {
    let selectedSwatch: AnnotationSwatch
    let onSelect: (AnnotationSwatch) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(selectedSwatch.color)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.5))

                Text(selectedSwatch.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.8))

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            AnnotationColorPopover(
                selectedSwatch: selectedSwatch,
                onSelect: { swatch in
                    onSelect(swatch)
                    isPresented = false
                },
                onCustomSelect: onSelect
            )
        }
        .help("Color")
    }
}

private struct AnnotationStrokeMenu: View {
    let strokeWidth: CGFloat
    let onSelect: (CGFloat) -> Void

    private let widths: [CGFloat] = [2, 4, 6, 8, 12]
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 10) {
                StrokePreview(width: strokeWidth)
                    .frame(width: 30, height: 16)

                Text("\(Int(strokeWidth))px")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(minWidth: 28, alignment: .leading)

                Spacer(minLength: 10)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            AnnotationStrokePopover(
                strokeWidth: strokeWidth,
                widths: widths,
                onSelect: { width in
                    onSelect(width)
                    isPresented = false
                }
            )
        }
        .help("Stroke thickness")
    }
}

private struct AnnotationColorPopover: View {
    let selectedSwatch: AnnotationSwatch
    let onSelect: (AnnotationSwatch) -> Void
    let onCustomSelect: (AnnotationSwatch) -> Void

    private var customColor: Binding<Color> {
        Binding(
            get: { selectedSwatch.color },
            set: { onCustomSelect(.custom(from: $0)) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(AnnotationSwatch.allCases) { swatch in
                Button {
                    onSelect(swatch)
                } label: {
                    AnnotationColorOptionRow(
                        swatch: swatch,
                        isSelected: selectedSwatch == swatch
                    )
                }
                .buttonStyle(.plain)
            }

            Divider()
                .padding(.vertical, 4)

            ColorPicker(selection: customColor, supportsOpacity: false) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(AngularGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            center: .center
                        ))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))

                    Text("Custom")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .padding(8)
        .frame(width: 172)
    }
}

private struct AnnotationColorOptionRow: View {
    let swatch: AnnotationSwatch
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(swatch.color)
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 0.5))
                .overlay {
                    if isSelected {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.38), lineWidth: 6)
                            .frame(width: 32, height: 32)
                    }
                }

            Text(swatch.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(height: 34)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
            }
        }
    }
}

private struct AnnotationColorWellMenu: View {
    let selectedSwatch: AnnotationSwatch
    let onSelect: (AnnotationSwatch) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(selectedSwatch.color)
                .frame(width: 28, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            AnnotationColorPopover(
                selectedSwatch: selectedSwatch,
                onSelect: { swatch in
                    onSelect(swatch)
                    isPresented = false
                },
                onCustomSelect: onSelect
            )
        }
        .help("Text color")
    }
}

private struct AnnotationStrokePopover: View {
    let strokeWidth: CGFloat
    let widths: [CGFloat]
    let onSelect: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 7) {
            ForEach(widths, id: \.self) { width in
                Button {
                    onSelect(width)
                } label: {
                    StrokeOptionRow(width: width, isSelected: strokeWidth == width)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(9)
        .frame(width: 92)
    }
}

private struct StrokeOptionRow: View {
    let width: CGFloat
    let isSelected: Bool

    var body: some View {
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            }

            StrokePreview(width: width, color: isSelected ? Color.accentColor : Color.primary.opacity(0.58))
                .frame(width: 48, height: 32)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Inspector

struct AnnotationEditorInspector: View {
    private static let minimumColumnWidth: CGFloat = 260
    private static let idealColumnWidth: CGFloat = 280
    private static let maximumColumnWidth: CGFloat = 440

    @Bindable var model: AnnotationEditorModel
    let onPickWallpaper: () -> Void
    let onSaveAs: () -> Void
    let onDone: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // MARK: Tools
                    VStack(alignment: .leading, spacing: 10) {
                        AnnotationInspectorSectionHeader("TOOLS")
                        AnnotationInspectorToolGrid(selectedTool: model.selectedTool) { tool in
                            model.selectTool(tool)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 16)

                    if model.inspectedTool != nil {
                        AnnotationInspectorDivider()

                        // MARK: Style
                        VStack(alignment: .leading, spacing: 10) {
                            AnnotationInspectorSectionHeader("STYLE")

                            if model.selectionCount > 1 {
                                Text("\(model.selectionCount) annotations selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            AnnotationInspectorRow(title: "Color") {
                                AnnotationColorMenu(selectedSwatch: model.selectedSwatch) { swatch in
                                    model.setSwatch(swatch)
                                }
                            }

                            if model.isStrokeStyleAvailable {
                                AnnotationInspectorRow(title: "Stroke") {
                                    AnnotationStrokeMenu(strokeWidth: model.strokeWidth) { strokeWidth in
                                        model.setStrokeWidth(strokeWidth)
                                    }
                                }
                            }

                            if model.isRedactionStyleAvailable {
                                AnnotationBackgroundSlider(
                                    title: "Density",
                                    value: Binding(
                                        get: { model.redactionDensity },
                                        set: { model.setRedactionDensity($0) }
                                    ),
                                    range: 0.15...1
                                )
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                    }

                    if model.isTextStyleAvailable {
                        AnnotationInspectorDivider()

                        // MARK: Text
                        VStack(alignment: .leading, spacing: 10) {
                            AnnotationInspectorSectionHeader("TEXT")
                            AnnotationTextStyleControls(model: model)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                    }

                    AnnotationInspectorDivider()

                    // MARK: Background
                    AnnotationBackgroundInspector(
                        settings: Binding(
                            get: { model.backgroundSettings },
                            set: { model.backgroundSettings = $0 }
                        ),
                        onPickWallpaper: onPickWallpaper
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollContentBackground(.hidden)
            .background(sidebarBackground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 10) {
                Button(action: onSaveAs) {
                    Text("Save as...")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .controlSize(.large)

                Button(action: onDone) {
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(sidebarBackground)
        }
        .background(sidebarBackground)
        .inspectorColumnWidth(
            min: Self.minimumColumnWidth,
            ideal: Self.idealColumnWidth,
            max: Self.maximumColumnWidth
        )
        .frame(
            minWidth: Self.minimumColumnWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var sidebarBackground: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white
    }
}

private struct AnnotationInspectorSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
    }
}

private struct AnnotationInspectorDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 14)
    }
}

private struct AnnotationInspectorRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AnnotationInspectorToolGrid: View {
    let selectedTool: AnnotationTool
    let onSelect: (AnnotationTool) -> Void

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 2), count: 6
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                Button {
                    onSelect(tool)
                } label: {
                    Image(systemName: tool.systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTool == tool ? Color.accentColor : .primary.opacity(0.7))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selectedTool == tool ? Color.accentColor.opacity(0.15) : .clear)
                )
                .help(tool.title)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }
}

private struct AnnotationBackgroundInspector: View {
    @Binding var settings: AnnotationBackgroundSettings
    let onPickWallpaper: () -> Void

    private let gradientColumns = Array(repeating: GridItem(.flexible(minimum: 20), spacing: 5), count: 8)
    private let wallpaperColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    private let colorColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)
    private let alignmentColumns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // None button
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

            // Gradients
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

            // Wallpapers
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

            // Plain color
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

            // Padding - full width
            AnnotationBackgroundSlider(
                title: "Padding",
                value: $settings.padding,
                range: 0.04...0.45
            )
            .padding(.bottom, 14)

            // Shadow + Corners side by side
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

            // Alignment + Ratio side by side
            HStack(alignment: .top, spacing: 12) {
                // Alignment
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

                // Ratio
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

private struct AnnotationBackgroundSlider: View {
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

// MARK: - Text Style Controls

private struct AnnotationTextStyleControls: View {
    @Bindable var model: AnnotationEditorModel
    @State private var fontSizeText = ""
    @FocusState private var isFontSizeFieldFocused: Bool

    private let fontFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies.sorted()
    }()

    var body: some View {
        VStack(spacing: 10) {
            // Font family + color swatch
            HStack(spacing: 6) {
                fontFamilyMenu
                    .frame(minWidth: 0, maxWidth: .infinity)

                AnnotationColorWellMenu(selectedSwatch: model.selectedSwatch) { swatch in
                    model.setSwatch(swatch)
                }
            }

            // Font size + style toggles
            HStack(spacing: 6) {
                HStack(spacing: 0) {
                    Button {
                        adjustFontSize(by: -1)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 22, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Divider().frame(height: 14)

                    TextField("", text: $fontSizeText)
                        .focused($isFontSizeFieldFocused)
                        .onSubmit(commitFontSizeText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 32)

                    Divider().frame(height: 14)

                    Button {
                        adjustFontSize(by: 1)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 22, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )

                Spacer()

                AnnotationInspectorSegmentedToggles(
                    options: TextStyleSegment.allCases,
                    isSelected: { segment in
                        switch segment {
                        case .bold: model.selectedTextIsBold
                        case .italic: model.selectedTextIsItalic
                        case .underline: model.selectedTextIsUnderline
                        }
                    },
                    onToggle: { segment in
                        switch segment {
                        case .bold: model.selectedTextIsBold.toggle()
                        case .italic: model.selectedTextIsItalic.toggle()
                        case .underline: model.selectedTextIsUnderline.toggle()
                        }
                    },
                    label: { segment in
                        Text(segment.title)
                            .font(segment.font)
                            .underline(segment == .underline)
                    }
                )
                .frame(width: 96)
            }

            // Text alignment
            AnnotationInspectorSegmentedControl(
                options: TextAlignmentSegment.allCases,
                selection: Binding(
                    get: { TextAlignmentSegment(model.selectedTextAlignment) },
                    set: { model.selectedTextAlignment = $0.nsTextAlignment }
                ),
                label: { segment in
                    Image(systemName: segment.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
            )
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: syncFontSizeText)
        .onDisappear(perform: commitFontSizeText)
        .onChange(of: model.selectedTextFontSize) { _, _ in
            guard !isFontSizeFieldFocused else { return }
            syncFontSizeText()
        }
        .onChange(of: model.selectedItemID) { _, _ in
            guard !isFontSizeFieldFocused else { return }
            syncFontSizeText()
        }
        .onChange(of: isFontSizeFieldFocused) { _, isFocused in
            if isFocused {
                syncFontSizeText()
            } else {
                commitFontSizeText()
            }
        }
    }

    private var fontFamilyMenu: some View {
        Menu {
            ForEach(fontFamilies, id: \.self) { family in
                Button {
                    model.selectedTextFontName = family
                } label: {
                    if model.selectedTextFontName == family {
                        Label(family, systemImage: "checkmark")
                    } else {
                        Text(family)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.selectedTextFontName)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Font family")
    }

    private func syncFontSizeText() {
        fontSizeText = String(Int(model.selectedTextFontSize.rounded()))
    }

    private func commitFontSizeText() {
        let trimmedText = fontSizeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Double(trimmedText) else {
            syncFontSizeText()
            return
        }

        let clampedSize = max(size.rounded(), Double(AnnotationTextMetrics.minimumFontSize))
        model.selectedTextFontSize = CGFloat(clampedSize)
        fontSizeText = String(Int(clampedSize))
    }

    private func adjustFontSize(by delta: CGFloat) {
        commitFontSizeText()
        let size = max(model.selectedTextFontSize + delta, AnnotationTextMetrics.minimumFontSize)
        model.selectedTextFontSize = size
        syncFontSizeText()
    }

}

private enum TextStyleSegment: CaseIterable, Hashable {
    case bold
    case italic
    case underline

    var title: String {
        switch self {
        case .bold: "B"
        case .italic: "I"
        case .underline: "U"
        }
    }

    var font: Font {
        switch self {
        case .bold:
            .system(size: 12, weight: .bold)
        case .italic:
            .system(size: 12, weight: .regular, design: .serif).italic()
        case .underline:
            .system(size: 12, weight: .regular)
        }
    }
}

private enum TextAlignmentSegment: CaseIterable, Hashable {
    case left
    case center
    case right
    case justified

    init(_ alignment: NSTextAlignment) {
        switch alignment {
        case .center:
            self = .center
        case .right:
            self = .right
        case .justified:
            self = .justified
        default:
            self = .left
        }
    }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }

    var systemImage: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify.leading"
        }
    }
}

private struct AnnotationInspectorSegmentedControl<Option: Hashable, Label: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let options: [Option]
    @Binding var selection: Option
    @ViewBuilder let label: (Option) -> Label

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segment(for: option)
            }
        }
        .padding(3)
        .frame(height: 34)
        .background(Capsule().fill(controlBackground))
        .overlay(Capsule().stroke(controlBorder, lineWidth: 0.5))
    }

    private func segment(for option: Option) -> some View {
        let isSelected = selection == option

        return Button {
            selection = option
        } label: {
            label(option)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var controlBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.07)
            : Color(nsColor: .controlBackgroundColor).opacity(0.65)
    }

    private var controlBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color(nsColor: .separatorColor).opacity(0.45)
    }
}

private struct AnnotationInspectorSegmentedToggles<Option: Hashable, Label: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let options: [Option]
    let isSelected: (Option) -> Bool
    let onToggle: (Option) -> Void
    @ViewBuilder let label: (Option) -> Label

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segment(for: option)
            }
        }
        .padding(3)
        .frame(height: 34)
        .background(Capsule().fill(controlBackground))
        .overlay(Capsule().stroke(controlBorder, lineWidth: 0.5))
    }

    private func segment(for option: Option) -> some View {
        let selected = isSelected(option)

        return Button {
            onToggle(option)
        } label: {
            label(option)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background {
            if selected {
                Capsule()
                    .fill(Color.accentColor)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var controlBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.07)
            : Color(nsColor: .controlBackgroundColor).opacity(0.65)
    }

    private var controlBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color(nsColor: .separatorColor).opacity(0.45)
    }
}

private struct StrokePreview: View {
    let width: CGFloat
    var color: Color = .primary

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: proxy.size.width * 0.24, y: proxy.size.height * 0.68))
                path.addLine(to: CGPoint(x: proxy.size.width * 0.76, y: proxy.size.height * 0.32))
            }
            .stroke(color, style: StrokeStyle(lineWidth: min(width, 7), lineCap: .round))
        }
    }
}
