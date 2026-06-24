//
//  AnnotationInspectorStyleMenus.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct AnnotationColorMenu: View {
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
                    .font(.inspectorValue)
                    .foregroundStyle(.primary.opacity(0.85))

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .inspectorField()
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

struct AnnotationStrokeMenu: View {
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
                    .font(.inspectorValue)
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(minWidth: 28, alignment: .leading)

                Spacer(minLength: 10)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 8)
            .inspectorField()
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

struct AnnotationColorWellMenu: View {
    let selectedSwatch: AnnotationSwatch
    let onSelect: (AnnotationSwatch) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            RoundedRectangle(cornerRadius: InspectorMetrics.fieldRadius, style: .continuous)
                .fill(selectedSwatch.color)
                .frame(width: 32, height: InspectorMetrics.controlHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: InspectorMetrics.fieldRadius, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 0.5)
                )
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
