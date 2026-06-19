//
//  OverlayCardEditor.swift
//  Screendrop
//
//  A live, drag-and-drop editor for the preview card layout. Users drag action
//  chips between the four corner slots, the center column, and a "tray" of
//  hidden actions. Chips morph between a circular corner badge and a labelled
//  center pill as they move, with springy, Apple-style animations. Edits are
//  written straight to the shared `OverlayCardLayoutStore`, so the floating
//  preview updates immediately.
//

import AppKit
import SwiftUI

struct OverlayCardEditor: View {
    @State private var store = OverlayCardLayoutStore.shared

    // Drag interaction state.
    @State private var dragging: OverlayCardAction?
    @State private var dragLocation: CGPoint = .zero
    @State private var originZone: OverlayCardZone?
    @State private var hoveredZone: OverlayCardZone?

    // Geometry of drop targets, in the "cardEditor" coordinate space.
    @State private var zoneFrames: [ZoneFrame] = []
    @State private var centerItemFrames: [CenterItemFrame] = []

    private let cardSize = CGSize(width: 210, height: 158)
    private let spaceName = "cardEditor"
    private var layout: OverlayCardLayout { store.layout }

    var body: some View {
        VStack(spacing: 18) {
            header

            card

            tray

            footer
        }
        .coordinateSpace(.named(spaceName))
        .onPreferenceChange(ZoneFramesKey.self) { zoneFrames = $0 }
        .onPreferenceChange(CenterItemFramesKey.self) { centerItemFrames = $0 }
        // The floating chip lives at the root of the coordinate space so its
        // `.position` matches the gesture's reported location exactly.
        .overlay(alignment: .topLeading) {
            if let dragging {
                FloatingMorphChip(
                    action: dragging,
                    isCorner: chipStyle(for: hoveredZone ?? originZone).isCorner
                )
                .position(dragLocation)
                .allowsHitTesting(false)
                .transition(.identity)
                .zIndex(100)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(spacing: 4) {
            Text("Customize the preview card")
                .font(.headline)
            Text("Drag actions into the corners or the center. Drop them in the tray to hide.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var footer: some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                store.reset()
            }
        } label: {
            Label("Reset to default", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    // MARK: - Card

    private var card: some View {
        ZStack {
            cardBackground

            ForEach(OverlayCardCorner.allCases) { corner in
                cornerCell(corner)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                    .padding(11)
            }

            centerColumn
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: layout)
        // Slot-placeholder highlights animate on their own gentle curve. The
        // floating chip's morph is driven solely by the curve in the drag
        // handler, so it is not double-animated here.
        .animation(.easeOut(duration: 0.18), value: hoveredZone)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.32), Color(white: 0.17)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 60, weight: .regular))
                    .foregroundStyle(.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)
    }

    private func cornerCell(_ corner: OverlayCardCorner) -> some View {
        let action = layout.action(at: corner)
        let highlighted = hoveredZone == .corner(corner)

        let isFilled = action != nil && action != dragging

        return ZStack {
            // Only show the dashed slot when it's empty (or its chip is lifted
            // away), so the ring never peeks out from behind a filled chip.
            if !isFilled {
                slotPlaceholder(isCircle: true, highlighted: highlighted)
            }

            if let action {
                // Keep the chip (and its drag gesture) mounted while it's being
                // dragged — just hide it — so `.onEnded` still fires. Removing it
                // here would tear down the gesture mid-drag and orphan the chip.
                chip(action, style: .corner)
                    .opacity(action == dragging ? 0 : 1)
            }
        }
        .frame(width: 34, height: 34)
        .background(frameReporter(.corner(corner)))
    }

    private var centerColumn: some View {
        let highlighted = hoveredZone == .center
        let visibleCount = layout.center.filter { $0 != dragging }.count

        return VStack(spacing: 7) {
            if layout.center.isEmpty {
                slotPlaceholder(isCircle: false, highlighted: highlighted)
                    .frame(width: 104, height: 30)
            } else {
                ForEach(layout.center) { action in
                    chip(action, style: .pill)
                        .opacity(action == dragging ? 0 : 1)
                        .background(centerItemReporter(action))
                }
                if visibleCount == 0 {
                    slotPlaceholder(isCircle: false, highlighted: highlighted)
                        .frame(width: 104, height: 30)
                }
            }
        }
        .padding(8)
        .frame(minWidth: 120, minHeight: 44)
        .background(frameReporter(.center))
    }

    // MARK: - Tray

    private var tray: some View {
        let highlighted = hoveredZone == .tray
        let visibleCount = layout.hidden.filter { $0 != dragging }.count

        return VStack(alignment: .leading, spacing: 8) {
            Text("HIDDEN ACTIONS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 8) {
                if layout.hidden.isEmpty || visibleCount == 0 {
                    Text("Drag actions here to hide them")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(layout.hidden) { action in
                    chip(action, style: .tray)
                        .opacity(action == dragging ? 0 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(highlighted ? 0.9 : 0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(highlighted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hoveredZone)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: layout)
        .background(frameReporter(.tray))
    }

    // MARK: - Chip

    private func chip(_ action: OverlayCardAction, style: ChipStyle) -> some View {
        ActionChip(action: action, style: style)
            .contentShape(.capsule)
            .gesture(dragGesture(for: action))
            .help(action.detail)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.5).combined(with: .opacity),
                removal: .opacity
            ))
    }

    private func chipStyle(for zone: OverlayCardZone?) -> ChipStyle {
        switch zone {
        case .corner: .corner
        case .tray: .tray
        default: .pill
        }
    }

    // MARK: - Drag handling

    private func dragGesture(for action: OverlayCardAction) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(spaceName))
            .onChanged { value in
                if dragging == nil {
                    dragging = action
                    originZone = layout.zone(of: action)
                    dragLocation = value.location
                    hoveredZone = originZone
                }
                dragLocation = value.location

                let resolved = resolveDrop(at: value.location) ?? originZone
                if resolved != hoveredZone {
                    // Morphing on screen → strong ease-in-out, not a spring.
                    // cubic-bezier(0.77, 0, 0.175, 1), ~260ms: no bounce, settles
                    // cleanly, and SwiftUI still retargets it from the current
                    // state if the drag crosses back over a boundary mid-morph.
                    withAnimation(.timingCurve(0.77, 0, 0.175, 1, duration: 0.26)) {
                        hoveredZone = resolved
                    }
                }
            }
            .onEnded { value in
                let target = resolveDrop(at: value.location) ?? originZone
                var index: Int?
                if target == .center {
                    index = centerInsertionIndex(at: value.location)
                }

                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                    if let target {
                        var updated = layout
                        updated.place(action, into: target, centerIndex: index)
                        store.layout = updated.normalized()
                    }
                    dragging = nil
                    hoveredZone = nil
                    originZone = nil
                }
            }
    }

    private func resolveDrop(at point: CGPoint) -> OverlayCardZone? {
        // Corners win first (small, precise targets), then center, then tray.
        for frame in zoneFrames {
            if case .corner = frame.zone, frame.rect.insetBy(dx: -16, dy: -16).contains(point) {
                return frame.zone
            }
        }
        if let center = zoneFrames.first(where: { $0.zone == .center }),
           center.rect.insetBy(dx: -14, dy: -14).contains(point),
           canDropInCenter() {
            return .center
        }
        if let tray = zoneFrames.first(where: { $0.zone == .tray }), tray.rect.contains(point) {
            return .tray
        }
        return nil
    }

    /// The center column holds at most `centerCapacity` actions. Reordering an
    /// action that's already in the center is always allowed; adding a new one
    /// is only allowed when there's room.
    private func canDropInCenter() -> Bool {
        guard let dragging else { return false }
        if layout.center.contains(dragging) { return true }
        return layout.center.filter { $0 != dragging }.count < OverlayCardLayout.centerCapacity
    }

    private func centerInsertionIndex(at point: CGPoint) -> Int {
        let sorted = centerItemFrames
            .filter { $0.action != dragging }
            .sorted { $0.rect.midY < $1.rect.midY }

        var index = 0
        for item in sorted {
            if point.y > item.rect.midY { index += 1 } else { break }
        }
        return index
    }

    // MARK: - Placeholders & reporters

    @ViewBuilder
    private func slotPlaceholder(isCircle: Bool, highlighted: Bool) -> some View {
        let stroke = highlighted ? Color.accentColor : Color.white.opacity(0.28)
        let style = StrokeStyle(lineWidth: highlighted ? 2 : 1.5, dash: highlighted ? [] : [4, 4])
        let fill = highlighted ? Color.accentColor.opacity(0.18) : Color.clear

        Group {
            if isCircle {
                Circle()
                    .strokeBorder(stroke, style: style)
                    .background(Circle().fill(fill))
            } else {
                Capsule()
                    .strokeBorder(stroke, style: style)
                    .background(Capsule().fill(fill))
            }
        }
        .scaleEffect(highlighted ? 1.12 : 1)
    }

    private func frameReporter(_ zone: OverlayCardZone) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ZoneFramesKey.self,
                value: [ZoneFrame(zone: zone, rect: geo.frame(in: .named(spaceName)))]
            )
        }
    }

    private func centerItemReporter(_ action: OverlayCardAction) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: CenterItemFramesKey.self,
                value: [CenterItemFrame(action: action, rect: geo.frame(in: .named(spaceName)))]
            )
        }
    }
}

// MARK: - Floating morph chip

/// The chip that follows the cursor while dragging and morphs between a corner
/// circle and a center pill.
///
/// Center-origin is guaranteed structurally: the OUTER frame is a fixed size
/// (always the full pill width), so `.position(_)` has a stable anchor and never
/// drifts. The visible capsule lives INSIDE that fixed frame and is the only
/// thing that resizes — and because it's centered in the fixed frame, it grows
/// and shrinks symmetrically from the middle. The icon and label sit on top and
/// trade places with opacity + a scale that collapses toward (or expands from)
/// that same center point.
private struct FloatingMorphChip: View {
    let action: OverlayCardAction
    let isCorner: Bool

    private static let diameter: CGFloat = 32
    private static let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    private var pillWidth: CGFloat {
        let textWidth = (action.label() as NSString)
            .size(withAttributes: [.font: Self.labelFont]).width
        return max(Self.diameter, ceil(textWidth) + 24)
    }

    var body: some View {
        let capsuleWidth = isCorner ? Self.diameter : pillWidth

        Capsule()
            .fill(.white)
            .frame(width: capsuleWidth, height: Self.diameter)
            .overlay {
                ZStack {
                    Image(systemName: action.symbol())
                        .font(.system(size: 13, weight: .bold))
                        .opacity(isCorner ? 1 : 0)
                        .scaleEffect(isCorner ? 1 : 0.4, anchor: .center)

                    Text(action.label())
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize()
                        .opacity(isCorner ? 0 : 1)
                        .scaleEffect(isCorner ? 0.4 : 1, anchor: .center)
                }
                .foregroundStyle(.black)
            }
            .clipShape(.capsule)
            .overlay(
                Capsule().strokeBorder(.black.opacity(0.06), lineWidth: 0.5)
            )
            // Fixed outer box (max width), centered — stable anchor for
            // `.position`; the capsule above resizes within it from the center.
            .frame(width: pillWidth, height: Self.diameter)
            .shadow(color: .black.opacity(0.32), radius: 12, x: 0, y: 7)
            .scaleEffect(1.08, anchor: .center)
    }
}

// MARK: - Chip view

enum ChipStyle: Equatable {
    case corner
    case pill
    case tray

    var isCorner: Bool { self == .corner }
}

private struct ActionChip: View {
    let action: OverlayCardAction
    let style: ChipStyle
    var lifted: Bool = false

    private static let cornerDiameter: CGFloat = 32
    private static let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    /// Explicit pill width (label + horizontal padding) so the capsule width
    /// interpolates to a known target rather than snapping to an intrinsic
    /// `nil` width at the end of the animation.
    private var pillWidth: CGFloat {
        let textWidth = (action.label() as NSString)
            .size(withAttributes: [.font: Self.labelFont]).width
        return max(Self.cornerDiameter, ceil(textWidth) + 24)
    }

    var body: some View {
        let isCorner = style.isCorner

        // The white capsule is the single, continuous "object": it just resizes
        // between a circle (w == h) and a pill. The icon and label are layered
        // at its center and blend with opacity + a gentle scale + a light 2px
        // blur (Dynamic-Island style) so the swap reads as the same control
        // changing modes rather than two things crossfading. One state (`style`)
        // drives all of it, animated by a single ease-in-out curve in the
        // parent, so a reversed drag retargets cleanly mid-morph.
        ZStack {
            Image(systemName: action.symbol())
                .font(.system(size: 13, weight: .bold))
                .opacity(isCorner ? 1 : 0)
                .scaleEffect(isCorner ? 1 : 0.4, anchor: .center)
                .blur(radius: isCorner ? 0 : 2)

            Text(action.label())
                .font(.system(size: 12, weight: .semibold))
                .fixedSize()
                .opacity(isCorner ? 0 : 1)
                .scaleEffect(isCorner ? 0.4 : 1, anchor: .center)
                .blur(radius: isCorner ? 2 : 0)
        }
        .foregroundStyle(.black)
        .frame(width: isCorner ? Self.cornerDiameter : pillWidth, height: Self.cornerDiameter, alignment: .center)
        .background(.white, in: .capsule)
        .clipShape(.capsule)
        .overlay(
            Capsule().strokeBorder(.black.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(lifted ? 0.32 : 0.16), radius: lifted ? 12 : 4, x: 0, y: lifted ? 7 : 2)
        .scaleEffect(lifted ? 1.08 : 1, anchor: .center)
    }
}

// MARK: - Drop-target geometry

private struct ZoneFrame: Equatable {
    let zone: OverlayCardZone
    let rect: CGRect
}

private struct ZoneFramesKey: PreferenceKey {
    static let defaultValue: [ZoneFrame] = []
    static func reduce(value: inout [ZoneFrame], nextValue: () -> [ZoneFrame]) {
        value.append(contentsOf: nextValue())
    }
}

private struct CenterItemFrame: Equatable {
    let action: OverlayCardAction
    let rect: CGRect
}

private struct CenterItemFramesKey: PreferenceKey {
    static let defaultValue: [CenterItemFrame] = []
    static func reduce(value: inout [CenterItemFrame], nextValue: () -> [CenterItemFrame]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Helpers

private extension OverlayCardCorner {
    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}

/// A minimal wrapping layout for the hidden-actions tray.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalHeight += rowHeight + spacing
                maxRowWidth = max(maxRowWidth, x - spacing)
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, x - spacing)

        let width = maxWidth == .infinity ? maxRowWidth : maxWidth
        return CGSize(width: max(0, width), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
