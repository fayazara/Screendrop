//
//  OverlayCardEditor.swift
//  Screendrop
//
//  Settings → Capture Cards → Card Actions. A capture card at its real size
//  over a sample screenshot, drawn with the card's own chips, above a tray of
//  the actions that aren't on it.
//
//  Drag a button to move it. It lifts off with a spring and keeps the spot
//  you grabbed under the pointer. Over a corner it becomes a circle, and the
//  corner's own button shrinks back, about to be bumped to where the dragged
//  one came from. Over the middle it becomes a pill and the other pills
//  spring apart to open a gap where it will land; when the middle is full,
//  the pill it would trade places with dips instead. Over the tray it comes
//  off the card. Let go and the change commits at once while it springs onto
//  its new spot, where the real button takes over; let go anywhere else and
//  it springs home.
//
//  This editor is the one place in the app with bouncy springs: picking
//  things up and putting them down is meant to feel playful. They respect
//  Reduce Motion.
//
//  `CardGeometry` places every slot and also answers what's under the
//  pointer, using the card's resting layout so the target never flickers as
//  the preview moves. Empty slots open an add menu on click, and every button
//  has a right-click menu, so nothing needs a drag. Edits go straight to
//  `OverlayCardLayoutStore`, which the live cards read.
//

import AppKit
import SwiftUI

struct OverlayCardEditor: View {
    @State private var store = OverlayCardLayoutStore.shared
    @State private var cloud = CloudCredentialStore.shared
    @State private var kind: PreviewMediaKind = .image

    @State private var drag: CardDrag?
    @State private var cardFrame: CGRect = .zero
    @State private var trayFrame: CGRect = .zero
    @State private var trayChipFrames: [OverlayCardAction: CGRect] = [:]

    private static let space = "cardActionsEditor"

    private var layout: OverlayCardLayout { store.layout }
    private var geometry: CardGeometry { CardGeometry(layout: layout) }

    var body: some View {
        VStack(spacing: Space.xl) {
            SettingsSegmented(
                options: [PreviewMediaKind.image, .video],
                selection: $kind,
                title: { $0 == .image ? "Screenshot" : "Recording" }
            )

            card
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { cardFrame = $0 }

            tray
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { trayFrame = $0 }

            HStack(alignment: .center, spacing: Space.l) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                SettingsButton("Restore Defaults") {
                    withAnimation(CardSpring.reflow) { store.reset() }
                }
                .disabled(store.isDefault)
            }
        }
        .padding(.vertical, Space.m)
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .topLeading) { liftedChip }
        .motion(.morphQuick, value: kind)
    }

    private var caption: String {
        var lines = ["Drag buttons to rearrange them, or onto the tray to take them off. Right-click a button for more."]
        if kind == .video {
            lines.append("Pin and Compress only appear on screenshots.")
        }
        if !cloud.isConfigured {
            lines.append("Upload appears once Cloud is set up.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Card

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: CaptureShelfMetrics.cardRadius, style: .continuous)
        let column = centerColumn

        return ZStack(alignment: .topLeading) {
            SampleCapture()

            ForEach(OverlayCardCorner.allCases) { corner in
                cornerSlot(corner)
                    .position(geometry.center(of: .corner(corner)))
            }

            ForEach(column.rows) { row in
                centerRow(row)
                    .position(x: CardGeometry.size.width / 2, y: CardGeometry.rowY(row.position, of: column.count))
                    // A row's button usually arrives from the lifted copy:
                    // appear at once rather than fade in.
                    .transition(.identity)
            }
        }
        .frame(width: CardGeometry.size.width, height: CardGeometry.size.height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Palette.strongHairline, lineWidth: 1) }
    }

    @ViewBuilder
    private func cornerSlot(_ corner: OverlayCardCorner) -> some View {
        if let action = layout.action(at: corner) {
            // About to be bumped by the button hovering over it.
            let isDisplaced = preview?.target == .corner(corner) && preview?.action != action
            chip(action, round: true)
                // Lands from the lifted copy: appear at once, never fade in.
                .transition(.identity)
                .scaleEffect(isDisplaced ? 0.78 : 1)
                .opacity(isDisplaced ? 0.55 : 1)
                .contextMenu { moveMenu(for: action) }
                .accessibilityLabel("\(corner.title) corner: \(action.label(for: kind))")
        } else {
            EmptySlot(isRound: true, isTarget: preview?.target == .corner(corner)) {
                addMenu(for: .corner(corner))
            }
            .accessibilityLabel("\(corner.title) corner: empty")
        }
    }

    @ViewBuilder
    private func centerRow(_ row: ColumnRow) -> some View {
        switch row.content {
        case .action(let action):
            let index = layout.center.firstIndex(of: action) ?? 0
            let isSwapped = preview?.target == .centerSwap(index)
            chip(action, round: false)
                // Lands from the lifted copy: appear at once, never fade in.
                .transition(.identity)
                .scaleEffect(isSwapped ? 0.88 : 1)
                .opacity(isSwapped ? 0.55 : 1)
                .contextMenu { moveMenu(for: action) }
                .accessibilityLabel("Middle: \(action.label(for: kind))")
        case .add:
            EmptySlot(isRound: false, isTarget: false) {
                addMenu(for: .center(layout.center.count))
            }
            .accessibilityLabel("Middle: empty")
        }
    }

    /// The middle column as it should look right now: at rest, the buttons
    /// and the add slot; while dragging, the other buttons with a gap where
    /// the dragged one would land, closed up when it's headed elsewhere.
    private var centerColumn: CenterColumn {
        guard let drag = preview else {
            var rows = layout.center.enumerated().map { ColumnRow(content: .action($1), position: $0) }
            if layout.hasRoomInCenter {
                rows.append(ColumnRow(content: .add, position: rows.count))
            }
            return CenterColumn(rows: rows, count: rows.count)
        }

        let others = layout.center.filter { $0 != drag.action }
        var order: [OverlayCardAction?] = others
        switch drag.target {
        case .centerInsert(let index):
            order.insert(nil, at: min(index, order.count))
        case nil where layout.center.contains(drag.action):
            // Going nowhere yet: keep its home open.
            order.insert(nil, at: layout.center.firstIndex(of: drag.action) ?? order.count)
        case .centerSwap:
            order = layout.center
        default:
            break
        }

        var rows: [ColumnRow] = []
        for (position, action) in order.enumerated() {
            if let action {
                rows.append(ColumnRow(content: .action(action), position: position))
            } else if layout.center.contains(drag.action) {
                // The dragged button's own (invisible) view sits in the gap,
                // so it stays alive under its gesture.
                rows.append(ColumnRow(content: .action(drag.action), position: position))
            }
        }
        // Dragged out of the middle: still keep its view, out of the count.
        if layout.center.contains(drag.action), !rows.contains(where: { $0.content == .action(drag.action) }) {
            let home = layout.center.firstIndex(of: drag.action) ?? 0
            rows.append(ColumnRow(content: .action(drag.action), position: home))
        }

        // The add slot stays while dragging, so picking a button up doesn't
        // re-center the column. A button arriving from outside takes the add
        // slot's place with its gap instead, so the column keeps its size.
        var isArriving = false
        if case .centerInsert = drag.target, !layout.center.contains(drag.action) {
            isArriving = true
        }
        let showsAdd = layout.hasRoomInCenter && !isArriving
        if showsAdd {
            rows.append(ColumnRow(content: .add, position: order.count))
        }
        return CenterColumn(rows: rows, count: order.count + (showsAdd ? 1 : 0))
    }

    // MARK: - Tray

    private var tray: some View {
        let offCard = layout.hidden
        let isTarget = preview?.target == .tray
        let shape = RoundedRectangle(cornerRadius: Radius.thumbnail + Space.xs, style: .continuous)

        return VStack(alignment: .leading, spacing: Space.m) {
            Text("Not on the card")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if offCard.isEmpty {
                Text("Drag a button here to take it off the card.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(height: 26)
            } else {
                LibraryFlowLayout(spacing: Space.m) {
                    ForEach(offCard) { action in
                        chip(action, round: false)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                                trayChipFrames[action] = $0
                            }
                            .contextMenu { moveMenu(for: action) }
                            .accessibilityLabel("Not on the card: \(action.label(for: kind))")
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isTarget ? Palette.accent.opacity(0.08) : Palette.fill, in: shape)
        .overlay {
            shape.strokeBorder(isTarget ? Palette.accent : Palette.hairline, lineWidth: isTarget ? 2 : 0.5)
        }
        .scaleEffect(isTarget ? 1.01 : 1)
    }

    // MARK: - Chips

    /// One action's button, wherever it sits. It stays in place, invisible,
    /// while it's being dragged, so its gesture lives until the drop.
    private func chip(_ action: OverlayCardAction, round: Bool) -> some View {
        ActionChip(action: action, kind: kind, round: round, isAvailable: isAvailable(action))
            // Glass fades itself in and out ("materializes") when it appears
            // or goes; a button handed over from the lifted copy mustn't.
            .glassEffectTransition(.identity)
            .opacity(isHidden(action) ? 0 : 1)
            // Shown and hidden instantly, as the lifted copy leaves and
            // lands, so the two never fade into each other.
            .animation(nil, value: isHidden(action))
            .help(isAvailable(action) ? action.detail : "\(action.label(for: kind)) doesn't appear here")
            .gesture(dragGesture(for: action))
    }

    /// The button under the pointer while dragging, in the shape it would
    /// take where it would land.
    @ViewBuilder
    private var liftedChip: some View {
        if let drag {
            LiftedChip(action: drag.action, kind: kind, isRound: drag.isRound, isAvailable: isAvailable(drag.action))
                .glassEffectTransition(.identity)
                // Landed, it matches the button in the slot exactly: full
                // size, no shadow.
                .scaleEffect(drag.isRaised ? 1.08 : 1)
                .shadow(color: .black.opacity(drag.isRaised ? 0.2 : 0), radius: drag.isRaised ? 8 : 0, y: drag.isRaised ? 4 : 0)
                .position(drag.chipCenter)
                .allowsHitTesting(false)
                // Appears and leaves in a single frame, matching the button
                // in the slot each time: never a crossfade between two.
                .transition(.identity)
        }
    }

    /// Mirrors the live card, which leaves out actions that can't apply.
    private func isAvailable(_ action: OverlayCardAction) -> Bool {
        switch action {
        case .pin, .compress: kind == .image
        case .upload: cloud.isConfigured
        default: true
        }
    }

    // MARK: - Dragging

    private func dragGesture(for action: OverlayCardAction) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard drag?.isSettling != true else { return }
                if drag == nil {
                    let home = homeCenter(of: action) ?? value.startLocation
                    let target = target(at: value.location, for: action)
                    // Appear at the size of the button being held, then
                    // spring up from there, so the hand-off doesn't jump.
                    drag = CardDrag(
                        action: action,
                        grabOffset: CGSize(width: home.x - value.startLocation.x, height: home.y - value.startLocation.y),
                        chipCenter: CGPoint(
                            x: value.location.x + home.x - value.startLocation.x,
                            y: value.location.y + home.y - value.startLocation.y
                        ),
                        home: home,
                        target: target,
                        isRound: layout.slot(of: action)?.isCorner ?? false
                    )
                    DispatchQueue.main.async {
                        withAnimation(CardSpring.lift) { drag?.isLifted = true }
                    }
                    return
                }
                guard let offset = drag?.grabOffset else { return }
                drag?.chipCenter = CGPoint(x: value.location.x + offset.width, y: value.location.y + offset.height)
                let target = target(at: value.location, for: action)
                if drag?.target != target {
                    withAnimation(CardSpring.reflow) { drag?.target = target }
                    // The shape change gets its own curve: a spring on a
                    // width reads as the button wobbling.
                    let round = target.map { if case .corner = $0 { true } else { false } }
                        ?? (layout.slot(of: action)?.isCorner ?? false)
                    if drag?.isRound != round {
                        withAnimation(CardSpring.morph) { drag?.isRound = round }
                    }
                }
            }
            .onEnded { _ in
                guard let current = drag, !current.isSettling else { return }
                settle(current)
            }
    }

    /// The drag as the card should preview it: nil once the button has
    /// been let go, when the card shows the real result.
    private var preview: CardDrag? {
        guard let drag, !drag.isSettling else { return nil }
        return drag
    }

    /// The real button stays hidden under its lifted copy until the copy has
    /// landed on it.
    private func isHidden(_ action: OverlayCardAction) -> Bool {
        guard let drag, drag.action == action else { return false }
        return !drag.isLanded
    }

    /// Lets go of the lifted button.
    ///
    /// The change is committed straight away, so the button's new view is
    /// created now, hidden, and has the whole settle to draw (a glass view
    /// shows nothing for its first frame or two). The rest of the card
    /// springs into its final layout while the lifted copy springs onto
    /// exactly where the new view sits. Then `handOff()` swaps one for the
    /// other.
    private func settle(_ current: CardDrag) {
        guard let target = current.target else {
            flyHome(current)
            return
        }

        var landed = layout
        Self.apply(current.action, on: target, to: &landed)

        // The tray reflows on its own: drop straight in.
        guard target != .tray, let slot = landed.slot(of: current.action) else {
            withAnimation(CardSpring.reflow) {
                store.layout = landed
                drag = nil
            }
            return
        }

        let point = CardGeometry(layout: landed).center(of: slot)
        let landing = CGPoint(x: cardFrame.minX + point.x, y: cardFrame.minY + point.y)

        withAnimation(CardSpring.morph) { drag?.isRound = slot.isCorner }
        withAnimation(CardSpring.reflow) {
            store.layout = landed
            drag?.isSettling = true
        }
        withAnimation(CardSpring.settle) {
            drag?.chipCenter = landing
        } completion: {
            handOff()
        }
    }

    /// Dropped nowhere: back to where it came from, nothing changed.
    private func flyHome(_ current: CardDrag) {
        let round = layout.slot(of: current.action)?.isCorner ?? false
        withAnimation(CardSpring.morph) { drag?.isRound = round }
        withAnimation(CardSpring.reflow) { drag?.isSettling = true }
        withAnimation(CardSpring.settle) {
            drag?.chipCenter = current.home
        } completion: {
            handOff()
        }
    }

    /// Shows the real button under the landed copy, then removes the copy a
    /// few frames later, once the button has drawn. The spot is never empty.
    private func handOff() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { drag?.isLanded = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withTransaction(instant) { drag = nil }
        }
    }

    /// Where a button sits at rest, in the editor's space.
    private func homeCenter(of action: OverlayCardAction) -> CGPoint? {
        if let slot = layout.slot(of: action) {
            let point = geometry.center(of: slot)
            return CGPoint(x: cardFrame.minX + point.x, y: cardFrame.minY + point.y)
        }
        guard let frame = trayChipFrames[action] else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func target(at point: CGPoint, for action: OverlayCardAction) -> DropTarget? {
        if trayFrame.contains(point) {
            return layout.slot(of: action) == nil ? nil : .tray
        }
        guard cardFrame.contains(point) else { return nil }
        let local = CGPoint(x: point.x - cardFrame.minX, y: point.y - cardFrame.minY)
        return geometry.target(at: local, for: action)
    }

    private static func apply(_ action: OverlayCardAction, on target: DropTarget, to layout: inout OverlayCardLayout) {
        switch target {
        case .corner(let corner):
            layout.assign(action, to: .corner(corner))
        case .centerInsert(let index):
            layout.insertIntoCenter(action, at: index)
        case .centerSwap(let index):
            layout.assign(action, to: .center(index))
        case .tray:
            layout.takeOff(action)
        }
    }

    // MARK: - Menus

    /// Right-click on any button: where else it can go.
    @ViewBuilder
    private func moveMenu(for action: OverlayCardAction) -> some View {
        let current = layout.slot(of: action)

        Section("Move to") {
            ForEach(OverlayCardCorner.allCases) { corner in
                Button("\(corner.title) Corner") { edit { $0.assign(action, to: .corner(corner)) } }
                    .disabled(current == .corner(corner))
            }
            if case .center = current {
                // Already in the middle: reordering is below.
            } else {
                Button("Middle") { edit { $0.insertIntoCenter(action, at: $0.center.count) } }
                    .disabled(!layout.hasRoomInCenter)
            }
        }

        if case .center(let index) = current, layout.center.count > 1 {
            Divider()
            Button("Move Up") { edit { $0.moveCenter(at: index, by: -1) } }
                .disabled(index == 0)
            Button("Move Down") { edit { $0.moveCenter(at: index, by: 1) } }
                .disabled(index == layout.center.count - 1)
        }

        if current != nil {
            Divider()
            Button("Remove from Card") { edit { $0.takeOff(action) } }
        }
    }

    /// Click on an empty slot: what can go there.
    @ViewBuilder
    private func addMenu(for slot: OverlayCardSlot) -> some View {
        let offCard = layout.hidden
        let elsewhere = OverlayCardAction.allCases.filter { layout.slot(of: $0) != nil }

        if !offCard.isEmpty {
            Section("Add") {
                ForEach(offCard) { menuItem($0, into: slot) }
            }
        }
        if !elsewhere.isEmpty {
            Section("Move Here") {
                ForEach(elsewhere) { menuItem($0, into: slot) }
            }
        }
    }

    private func menuItem(_ action: OverlayCardAction, into slot: OverlayCardSlot) -> some View {
        Button {
            edit { $0.assign(action, to: slot) }
        } label: {
            Label(action.label(for: kind), systemImage: action.symbol(for: kind))
        }
    }

    private func edit(_ change: (inout OverlayCardLayout) -> Void) {
        withAnimation(CardSpring.reflow) { change(&store.layout) }
    }
}

// MARK: - Motion

/// This editor's springs. Bouncier than the rest of the app on purpose;
/// nil under Reduce Motion.
private enum CardSpring {
    private static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Picking a button up.
    static var lift: Animation? { reducesMotion ? nil : .spring(duration: 0.3, bounce: 0.35) }
    /// Everything making room or changing shape while a button moves.
    static var reflow: Animation? { reducesMotion ? nil : .spring(duration: 0.4, bounce: 0.3) }
    /// The button dropping into its spot.
    static var settle: Animation? { reducesMotion ? nil : .spring(duration: 0.38, bounce: 0.32) }
    /// The lifted button turning between a circle and a pill: a strong
    /// ease-in-out with no overshoot, retargeting cleanly if the pointer
    /// crosses back mid-change.
    static var morph: Animation? { reducesMotion ? nil : .timingCurve(0.77, 0, 0.175, 1, duration: 0.26) }
}

// MARK: - Drag state

private struct CardDrag: Equatable {
    let action: OverlayCardAction
    /// From the pointer to the button's center, so the spot you grabbed
    /// stays under the pointer.
    let grabOffset: CGSize
    var chipCenter: CGPoint
    /// Where the button sat when picked up, to spring back to.
    let home: CGPoint
    var target: DropTarget?
    /// A circle (corner) or a pill.
    var isRound: Bool
    /// Let go: springing into place, with the change already committed.
    /// Ignores the pointer.
    var isSettling = false
    /// Sitting exactly on its real button, which is now showing.
    var isLanded = false
    /// Sprung up off the card, just after being picked up.
    var isLifted = false

    /// Drawn raised: picked up and not yet landing.
    var isRaised: Bool { isLifted && !isSettling }
}

private enum DropTarget: Equatable {
    case corner(OverlayCardCorner)
    /// Slot in at this index among the other middle buttons.
    case centerInsert(Int)
    /// Trade places with the middle button at this index.
    case centerSwap(Int)
    case tray
}

/// One row of the middle column as drawn.
private struct ColumnRow: Identifiable {
    enum Content: Hashable {
        case action(OverlayCardAction)
        case add
    }

    let content: Content
    let position: Int

    var id: Content { content }
}

private struct CenterColumn {
    let rows: [ColumnRow]
    /// Rows the column is laid out for, counting a gap.
    let count: Int
}

// MARK: - Geometry

/// Where everything sits on the card, in the card's own coordinates, from
/// the live card's metrics. Places the slots, and finds the one under the
/// pointer using the resting layout, so the target doesn't change as the
/// preview moves.
private struct CardGeometry {
    let layout: OverlayCardLayout

    static let size = CaptureShelfMetrics.cardSize
    private static let cornerReach: CGFloat = 24
    private static let rowStride: CGFloat = 26 + CaptureShelfMetrics.centerButtonSpacing

    /// The center y of row `index` in a column of `count` rows.
    static func rowY(_ index: Int, of count: Int) -> CGFloat {
        let height = CGFloat(count) * 26 + CGFloat(max(count - 1, 0)) * CaptureShelfMetrics.centerButtonSpacing
        return (size.height - height) / 2 + 13 + CGFloat(index) * rowStride
    }

    /// Rows at rest: the buttons, plus the add slot while there's room.
    private var restingRows: Int {
        layout.center.count + (layout.hasRoomInCenter ? 1 : 0)
    }

    func center(of slot: OverlayCardSlot) -> CGPoint {
        switch slot {
        case .corner(let corner):
            let offset = CaptureShelfMetrics.controlInset + CaptureShelfMetrics.cornerButtonSize / 2
            let left = corner == .topLeading || corner == .bottomLeading
            let top = corner == .topLeading || corner == .topTrailing
            return CGPoint(
                x: left ? offset : Self.size.width - offset,
                y: top ? offset : Self.size.height - offset
            )
        case .center(let index):
            return CGPoint(x: Self.size.width / 2, y: Self.rowY(index, of: restingRows))
        }
    }

    /// What a drop at `point` would do with `action`.
    func target(at point: CGPoint, for action: OverlayCardAction) -> DropTarget? {
        for corner in OverlayCardCorner.allCases {
            let slot = center(of: .corner(corner))
            if hypot(point.x - slot.x, point.y - slot.y) <= Self.cornerReach {
                return layout.slot(of: action) == .corner(corner) ? nil : .corner(corner)
            }
        }

        // Anywhere else on the card means the middle.
        let isInCenter = layout.center.contains(action)
        if isInCenter || layout.hasRoomInCenter {
            let others = layout.center.indices.filter { layout.center[$0] != action }
            let index = others.filter { center(of: .center($0)).y < point.y }.count
            if isInCenter, let current = layout.center.firstIndex(of: action), index == current {
                return nil
            }
            return .centerInsert(index)
        }

        // A full middle: swap with the nearest button.
        let nearest = layout.center.indices.min {
            abs(center(of: .center($0)).y - point.y) < abs(center(of: .center($1)).y - point.y)
        }
        return nearest.map { .centerSwap($0) }
    }
}

// MARK: - Pieces

/// An action as the card shows it: an icon in a circle in a corner, its name
/// in a pill in the middle or the tray. Crossfades between the two, so a
/// lifted button can change shape as it moves.
private struct ActionChip: View {
    let action: OverlayCardAction
    let kind: PreviewMediaKind
    let round: Bool
    let isAvailable: Bool

    var body: some View {
        ShelfChip(
            width: round ? CaptureShelfMetrics.cornerButtonSize : CaptureShelfMetrics.centerButtonWidth,
            isEnabled: isAvailable
        ) {
            ZStack {
                Image(systemName: action.symbol(for: kind))
                    .font(.system(size: 10.5, weight: .bold))
                    .opacity(round ? 1 : 0)
                Text(action.label(for: kind))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .opacity(round ? 0 : 1)
            }
        }
        .contentShape(Capsule())
    }
}

/// The button under the pointer while dragging, turning between the
/// corner's circle and the middle's pill.
///
/// The outer frame is always the pill's size, so `.position` has a stable
/// center; only the capsule inside it resizes, symmetrically from that
/// center. The icon and the label sit at the same center at their natural
/// sizes and trade places with a fade and a scale, so neither is ever
/// squeezed by the changing width. The same glass as the buttons on the card,
/// so landing is a seamless hand-off.
private struct LiftedChip: View {
    let action: OverlayCardAction
    let kind: PreviewMediaKind
    let isRound: Bool
    /// Dimmed like the card's own button for an action that won't appear.
    let isAvailable: Bool

    private let height: CGFloat = 26

    var body: some View {
        let pillWidth = CaptureShelfMetrics.centerButtonWidth
        let width = isRound ? CaptureShelfMetrics.cornerButtonSize : pillWidth

        Color.clear
            .frame(width: width, height: height)
            .glassEffect(.regular.interactive(isAvailable), in: Capsule())
            .overlay {
                ZStack {
                    Image(systemName: action.symbol(for: kind))
                        .font(.system(size: 10.5, weight: .bold))
                        .opacity(isRound ? 1 : 0)
                        .scaleEffect(isRound ? 1 : 0.4)
                        .blur(radius: isRound ? 0 : 2)

                    Text(action.label(for: kind))
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize()
                        .opacity(isRound ? 0 : 1)
                        .scaleEffect(isRound ? 0.4 : 1)
                        .blur(radius: isRound ? 2 : 0)
                }
                .foregroundStyle(.black.opacity(isAvailable ? 0.85 : 0.3))
            }
            .clipShape(Capsule())
            .opacity(isAvailable ? 1 : 0.6)
            .frame(width: pillWidth, height: height)
            // Light, live glass, as on the card.
            .environment(\.colorScheme, .light)
            .environment(\.appearsActive, true)
    }
}

/// An empty place on the card: a dashed outline with a "+" that opens a menu
/// of what can go there. It swells and fills in when a dragged button is
/// over it.
private struct EmptySlot<Items: View>: View {
    let isRound: Bool
    let isTarget: Bool
    @ViewBuilder let items: () -> Items

    var body: some View {
        let width = isRound ? CaptureShelfMetrics.cornerButtonSize : CaptureShelfMetrics.centerButtonWidth
        Menu {
            items()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(isTarget ? 0 : 0.9))
                .frame(width: width, height: 26)
                .background(Capsule().fill(.white.opacity(isTarget ? 0.35 : 0)))
                .overlay {
                    Capsule()
                        .strokeBorder(
                            .white.opacity(isTarget ? 1 : 0.75),
                            style: StrokeStyle(lineWidth: isTarget ? 2 : 1.5, dash: isTarget ? [] : [4, 3])
                        )
                }
                .scaleEffect(isTarget ? 1.15 : 1)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add an action")
    }
}

/// A made-up screenshot of an app window, frosted and dimmed the way the live
/// card treats the real one under its buttons.
private struct SampleCapture: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.97, green: 0.97, blue: 0.98)
            HStack(spacing: 0) {
                Color(red: 0.86, green: 0.89, blue: 0.95)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 8) {
                    bar(width: 70, opacity: 0.5)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.55, green: 0.7, blue: 1.0))
                        .frame(height: 40)
                    bar(width: 90, opacity: 0.35)
                    bar(width: 60, opacity: 0.35)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: CardGeometry.size.width, height: CardGeometry.size.height)
        // One opaque layer first, so the opaque blur samples a filled image
        // edge to edge rather than the gaps between shapes.
        .drawingGroup()
        .blur(radius: 6, opaque: true)
        .overlay(Color.black.opacity(0.16))
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat, opacity: Double) -> some View {
        Capsule()
            .fill(Color.black.opacity(opacity))
            .frame(width: width, height: 5)
    }
}

private extension OverlayCardSlot {
    var isCorner: Bool {
        if case .corner = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .corner(let corner): "\(corner.title) corner"
        case .center: "Middle"
        }
    }
}
