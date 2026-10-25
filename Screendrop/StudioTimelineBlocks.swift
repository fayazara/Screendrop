//
//  StudioTimelineBlocks.swift
//  Screendrop
//
//  The blocks on the Studio timeline's tracks - zooms, camera layouts, text,
//  images and effects, audio - and the one interaction engine they share.
//  Blocks only draw. Each track hit-tests the pointer against the same
//  frames it draws with and runs a single drag gesture, so a block is never
//  swallowed by its own trim handles, and every track selects, moves, trims
//  and creates the same way.
//

import AppKit
import SwiftUI

// MARK: - Metrics

enum StudioBlockMetrics {
    static let cornerRadius: CGFloat = 8
    /// Room above and below a block inside its track; the selection rim
    /// sits in it.
    static let inset: CGFloat = 3
    /// Narrowest a block draws, however short, so it stays visible and
    /// grabbable on a fitted timeline.
    static let minimumWidth: CGFloat = 24
    /// The selection's handles, outside the block's ends.
    static let handleWidth: CGFloat = 8
    static let rimWidth: CGFloat = 2
    /// How far past an unselected block's end a trim can still be grabbed.
    static let edgeOutset: CGFloat = 4
    /// How far into an unselected block its trim reaches, at most. Never
    /// more than a fifth of the block, so its middle always moves it.
    static let edgeInset: CGFloat = 6
    /// How far into a selected block its outside handles still answer.
    static let handleOverlap: CGFloat = 2
    static let labelInset: CGFloat = 9
    /// Pointer travel before a press on a block becomes a move, or a press
    /// on empty track becomes a new block.
    static let dragThreshold: CGFloat = 3

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

// MARK: - Model

/// One block on a track: what it stands for and where it sits on the
/// edited timeline.
struct StudioLaneBlock<Item: Identifiable>: Identifiable where Item.ID == UUID {
    let item: Item
    let editorStart: TimeInterval
    let editorEnd: TimeInterval

    var id: UUID { item.id }
    var editorLength: TimeInterval { max(0, editorEnd - editorStart) }
}

enum StudioBlockEditKind: Equatable {
    case move
    case trimLeading
    case trimTrailing
}

/// A drag in progress, measured from the block as the press found it -
/// the live block re-derives on every update, so measuring against it would
/// compound the translation.
struct StudioBlockEdit<Item: Identifiable> where Item.ID == UUID {
    let base: StudioLaneBlock<Item>
    let kind: StudioBlockEditKind
    /// Editor seconds the pointer has travelled since the press.
    let delta: TimeInterval
}

/// What a drag across empty track does.
enum StudioLaneEmptyBehavior {
    /// Scrubs the playhead.
    case scrub
    /// A click scrubs; a drag draws out a new block, committed on release.
    /// `stopsAtBlocks` keeps the new block in the gap it started in, for
    /// tracks whose blocks can't overlap.
    case create(
        tint: Color,
        minimumLength: TimeInterval,
        stopsAtBlocks: Bool,
        commit: (ClosedRange<TimeInterval>) -> Void
    )
}

/// How a track turns block edits into model changes.
struct StudioBlockLaneActions<Item: Identifiable> where Item.ID == UUID {
    let select: (Item) -> Void
    /// An edit is starting: open one undo step.
    let begin: (StudioBlockEditKind) -> Void
    let edit: (StudioBlockEdit<Item>) -> Void
    /// The edit is done: close the undo step.
    let end: (StudioBlockEditKind) -> Void
}

/// What a block's content needs to know to draw itself.
struct StudioBlockState {
    let width: CGFloat
    let height: CGFloat
    let isSelected: Bool
    let isHovered: Bool
}

// MARK: - Geometry and hit-testing

/// Where a block draws on its track. Rendering and hit-testing both use it,
/// so what you see is what you grab.
struct StudioBlockFrame: Equatable {
    let minX: CGFloat
    let width: CGFloat

    var maxX: CGFloat { minX + width }

    init(editorStart: TimeInterval, editorEnd: TimeInterval, scale: StudioTimelineScale) {
        let startX = scale.x(for: editorStart)
        let natural = CGFloat(max(0, editorEnd - editorStart)) * scale.pointsPerSecond
        // A block running past the edited video's end is cut there; one
        // drawn wider than it lasts slides inward to stay whole.
        let visible = min(natural, scale.contentWidth - startX)
        let width = min(max(StudioBlockMetrics.minimumWidth, visible), scale.contentWidth)
        self.width = width
        self.minX = min(startX, max(0, scale.contentWidth - width))
    }

    /// How far into this block, when unselected, its ends trim.
    var edgeInset: CGFloat {
        min(StudioBlockMetrics.edgeInset, width * 0.2)
    }
}

enum StudioBlockEdge: Equatable {
    case leading
    case trailing
}

/// What the pointer is over on a track.
enum StudioBlockTarget: Equatable {
    case empty
    case body(UUID)
    case edge(UUID, StudioBlockEdge)

    var blockID: UUID? {
        switch self {
        case .empty: nil
        case .body(let id), .edge(let id, _): id
        }
    }
}

struct StudioBlockHitTester {
    struct Entry {
        let id: UUID
        let frame: StudioBlockFrame
    }

    /// Bottom to top, as drawn.
    let entries: [Entry]
    let selectedID: UUID?

    func target(atX x: CGFloat) -> StudioBlockTarget {
        // The selected block draws on top with its handles outside its
        // ends, so it answers first: the handles trim, the block moves.
        if let selected = entries.last(where: { $0.id == selectedID }) {
            let frame = selected.frame
            let reach = StudioBlockMetrics.handleWidth
            let overlap = StudioBlockMetrics.handleOverlap
            if x >= frame.minX - reach, x < frame.minX + overlap {
                return .edge(selected.id, .leading)
            }
            if x > frame.maxX - overlap, x <= frame.maxX + reach {
                return .edge(selected.id, .trailing)
            }
            if x >= frame.minX, x <= frame.maxX {
                return .body(selected.id)
            }
        }

        // Otherwise the topmost block whose middle is under the pointer.
        for entry in entries.reversed() where entry.id != selectedID {
            let frame = entry.frame
            if x >= frame.minX + frame.edgeInset, x <= frame.maxX - frame.edgeInset {
                return .body(entry.id)
            }
        }

        // Then the nearest end within reach. Where two blocks meet, the end
        // of the block the pointer is inside wins over a neighbour's reach.
        var nearest: (target: StudioBlockTarget, isInside: Bool, distance: CGFloat)?
        for entry in entries where entry.id != selectedID {
            let frame = entry.frame
            let isInside = x >= frame.minX && x <= frame.maxX
            let candidates: [(StudioBlockEdge, CGFloat, ClosedRange<CGFloat>)] = [
                (.leading, frame.minX, (frame.minX - StudioBlockMetrics.edgeOutset)...(frame.minX + frame.edgeInset)),
                (.trailing, frame.maxX, (frame.maxX - frame.edgeInset)...(frame.maxX + StudioBlockMetrics.edgeOutset)),
            ]
            for (edge, edgeX, reach) in candidates where reach.contains(x) {
                let distance = abs(x - edgeX)
                let isBetter = nearest.map { best in
                    isInside != best.isInside ? isInside : distance < best.distance
                } ?? true
                if isBetter {
                    nearest = (.edge(entry.id, edge), isInside, distance)
                }
            }
        }
        return nearest?.target ?? .empty
    }
}

// MARK: - Track

/// One track of blocks. Owns every pointer interaction on the track: hover,
/// the cursor, selection, moving, trimming, scrubbing and drawing out new
/// blocks. Each kind of block supplies only its content, its menu, and how
/// an edit lands in the model.
struct StudioBlockLane<Item: Identifiable, Content: View, Menu: View, Decoration: View>: View
where Item.ID == UUID {
    let model: RecordingStudioModel
    /// The blocks to draw, bottom to top. Usually only those on screen.
    let blocks: [StudioLaneBlock<Item>]
    let selectedID: UUID?
    let scale: StudioTimelineScale
    let height: CGFloat
    let empty: StudioLaneEmptyBehavior
    var onScrubbing: ((Bool) -> Void)?
    let actions: StudioBlockLaneActions<Item>
    @ViewBuilder let decoration: () -> Decoration
    @ViewBuilder let content: (StudioLaneBlock<Item>, StudioBlockState) -> Content
    @ViewBuilder let menu: (StudioLaneBlock<Item>) -> Menu
    let help: (StudioLaneBlock<Item>) -> String

    /// A press on the track, from mouse-down to mouse-up.
    private enum Press {
        /// On a block, not yet far enough to edit it.
        case block(StudioLaneBlock<Item>, StudioBlockEditKind)
        case editing(StudioLaneBlock<Item>, StudioBlockEditKind)
        /// On empty track that can grow a new block, not yet dragged.
        case empty(startTime: TimeInterval)
        case creating(startTime: TimeInterval)
        case scrubbing
    }

    @State private var press: Press?
    @State private var pendingRange: ClosedRange<TimeInterval>?
    @State private var hover: StudioBlockTarget = .empty

    private var blockHeight: CGFloat {
        height - StudioBlockMetrics.inset * 2
    }

    var body: some View {
        let frames = Dictionary(uniqueKeysWithValues: blocks.map {
            ($0.id, StudioBlockFrame(editorStart: $0.editorStart, editorEnd: $0.editorEnd, scale: scale))
        })
        let selected = blocks.first { $0.id == selectedID }

        ZStack(alignment: .topLeading) {
            // The track's own surface: presses between blocks land here.
            Color.clear

            decoration()
                .allowsHitTesting(false)

            if let pendingRange, case .create(let tint, _, _, _) = empty {
                StudioPendingBlock(range: pendingRange, scale: scale, height: blockHeight, tint: tint)
            }

            // The selected block draws last, so its handles sit over its
            // neighbours.
            ForEach(blocks.filter { $0.id != selectedID } + (selected.map { [$0] } ?? [])) { block in
                if let frame = frames[block.id] {
                    blockView(block, frame: frame)
                }
            }

            if let selected, let frame = frames[selected.id] {
                StudioSelectionFrame(blockWidth: frame.width, blockHeight: blockHeight)
                    .offset(
                        x: frame.minX - StudioBlockMetrics.handleWidth,
                        y: StudioBlockMetrics.inset - StudioBlockMetrics.rimWidth
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(dragGesture(frames: frames))
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let target = hitTester(frames).target(atX: location.x)
                if target != hover { hover = target }
            case .ended:
                if hover != .empty { hover = .empty }
            }
        }
        .pointerStyle(pointerStyle)
    }

    @ViewBuilder
    private func blockView(_ block: StudioLaneBlock<Item>, frame: StudioBlockFrame) -> some View {
        let isSelected = block.id == selectedID
        let state = StudioBlockState(
            width: frame.width,
            height: blockHeight,
            isSelected: isSelected,
            isHovered: activeTarget.blockID == block.id
        )
        content(block, state)
            .frame(width: frame.width, height: blockHeight, alignment: .leading)
            .overlay {
                // An unselected block shows which end the pointer would trim.
                if !isSelected, case .edge(block.id, let edge) = activeTarget {
                    StudioBlockGrip()
                        .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
                        .padding(.horizontal, 3)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(StudioBlockMetrics.shape)
            .contextMenu { menu(block) }
            .help(help(block))
            .offset(x: frame.minX, y: StudioBlockMetrics.inset)
    }

    // MARK: Pointer

    private func hitTester(_ frames: [UUID: StudioBlockFrame]) -> StudioBlockHitTester {
        StudioBlockHitTester(
            entries: blocks.compactMap { block in
                frames[block.id].map { .init(id: block.id, frame: $0) }
            },
            selectedID: selectedID
        )
    }

    /// The press's target while one is held, the hovered one otherwise.
    private var activeTarget: StudioBlockTarget {
        switch press {
        case .block(let block, let kind), .editing(let block, let kind):
            switch kind {
            case .move: .body(block.id)
            case .trimLeading: .edge(block.id, .leading)
            case .trimTrailing: .edge(block.id, .trailing)
            }
        case .empty, .creating, .scrubbing:
            .empty
        case nil:
            hover
        }
    }

    private var pointerStyle: PointerStyle? {
        guard case .edge(_, let edge) = activeTarget else { return nil }
        return .frameResize(position: edge == .leading ? .leading : .trailing)
    }

    private func dragGesture(frames: [UUID: StudioBlockFrame]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard scale.pointsPerSecond > 0 else { return }
                if press == nil {
                    begin(at: value.startLocation.x, frames: frames)
                }
                update(translation: value.location.x - value.startLocation.x, x: value.location.x)
            }
            .onEnded { _ in finish() }
    }

    private func begin(at x: CGFloat, frames: [UUID: StudioBlockFrame]) {
        model.pause()
        let target = hitTester(frames).target(atX: x)
        if let id = target.blockID, let block = blocks.first(where: { $0.id == id }) {
            // Selecting on mouse-down shows the handles before any drag.
            actions.select(block.item)
            let kind: StudioBlockEditKind = switch target {
            case .edge(_, .leading): .trimLeading
            case .edge(_, .trailing): .trimTrailing
            default: .move
            }
            press = .block(block, kind)
            return
        }

        // Empty track lets go of the selection, like clicking empty canvas,
        // and scrubs.
        model.clearTimelineSelection()
        let time = scale.time(forX: x)
        model.seek(to: time)
        onScrubbing?(true)
        switch empty {
        case .scrub: press = .scrubbing
        case .create: press = .empty(startTime: time)
        }
    }

    private func update(translation: CGFloat, x: CGFloat) {
        let time = scale.time(forX: x)
        switch press {
        case .block(let block, let kind):
            // A trim follows the pointer from the first point; a move waits
            // out a small wobble so a click only selects.
            let threshold = kind == .move ? StudioBlockMetrics.dragThreshold : 0.5
            guard abs(translation) >= threshold else { return }
            actions.begin(kind)
            press = .editing(block, kind)
            edit(block, kind: kind, translation: translation)
        case .editing(let block, let kind):
            edit(block, kind: kind, translation: translation)
        case .empty(let startTime):
            if abs(translation) < StudioBlockMetrics.dragThreshold {
                model.seek(to: time)
                return
            }
            onScrubbing?(false)
            press = .creating(startTime: startTime)
            pendingRange = creationRange(from: startTime, to: time)
        case .creating(let startTime):
            pendingRange = creationRange(from: startTime, to: time)
        case .scrubbing:
            model.seek(to: time)
        case nil:
            break
        }
    }

    private func edit(_ block: StudioLaneBlock<Item>, kind: StudioBlockEditKind, translation: CGFloat) {
        actions.edit(StudioBlockEdit(
            base: block,
            kind: kind,
            delta: Double(translation) * scale.secondsPerPoint
        ))
    }

    private func finish() {
        switch press {
        case .editing(_, let kind):
            actions.end(kind)
        case .creating:
            if let pendingRange, case .create(_, let minimum, _, let commit) = empty,
               pendingRange.upperBound - pendingRange.lowerBound > minimum {
                commit(pendingRange)
            }
        case .empty, .scrubbing:
            onScrubbing?(false)
        case .block, nil:
            break
        }
        press = nil
        pendingRange = nil
    }

    /// The range a drag on empty track would create, stopped at the blocks
    /// on either side of where it began when blocks can't overlap, so the
    /// preview matches what the model will allow.
    private func creationRange(from start: TimeInterval, to current: TimeInterval) -> ClosedRange<TimeInterval> {
        var lower = min(start, current)
        var upper = max(start, current)
        if case .create(_, _, true, _) = empty {
            let floor = blocks.map(\.editorEnd).filter { $0 <= start }.max() ?? 0
            let ceiling = blocks.map(\.editorStart).filter { $0 >= start }.min() ?? model.duration
            lower = max(lower, floor)
            upper = min(upper, ceiling)
        }
        return lower...max(lower, upper)
    }
}

extension StudioBlockLane where Decoration == EmptyView {
    init(
        model: RecordingStudioModel,
        blocks: [StudioLaneBlock<Item>],
        selectedID: UUID?,
        scale: StudioTimelineScale,
        height: CGFloat,
        empty: StudioLaneEmptyBehavior,
        onScrubbing: ((Bool) -> Void)? = nil,
        actions: StudioBlockLaneActions<Item>,
        @ViewBuilder content: @escaping (StudioLaneBlock<Item>, StudioBlockState) -> Content,
        @ViewBuilder menu: @escaping (StudioLaneBlock<Item>) -> Menu,
        help: @escaping (StudioLaneBlock<Item>) -> String
    ) {
        self.init(
            model: model,
            blocks: blocks,
            selectedID: selectedID,
            scale: scale,
            height: height,
            empty: empty,
            onScrubbing: onScrubbing,
            actions: actions,
            decoration: { EmptyView() },
            content: content,
            menu: menu,
            help: help
        )
    }
}

/// Where a dragged block lands in the recording. It keeps its length on the
/// timeline, not in the recording, so sliding it from a sped-up clip onto a
/// normal one doesn't stretch it (or squeeze it the other way).
func studioMovedSourceRange(
    model: RecordingStudioModel,
    editorStart: TimeInterval,
    editorLength: TimeInterval
) -> (start: TimeInterval, end: TimeInterval) {
    let start = min(max(0, editorStart), max(0, model.duration - editorLength))
    return (
        model.sourceTime(atEditorTime: start),
        model.sourceTime(atEditorTime: start + editorLength)
    )
}

// MARK: - Drawing

/// How a block is painted: the bright tint with white marks on it, as in
/// Edits and CapCut. Selection doesn't change the body; a rim goes around it.
struct StudioBlockStyle {
    let tint: NSColor
    /// Marks on the body.
    var onTint: Color = .white

    static let zoom = StudioBlockStyle(tint: .controlAccentColor)
    static let layout = StudioBlockStyle(tint: .systemGreen)
    static let text = StudioBlockStyle(tint: .systemPurple)
    static let image = StudioBlockStyle(tint: .systemTeal)
    static let effect = StudioBlockStyle(tint: .systemGray)
    static let audio = StudioBlockStyle(tint: .systemIndigo)

    /// The tint, lifted a touch toward white in light mode; the pointer
    /// lifts it a little more.
    func fill(isHovering: Bool) -> Color {
        let tint = tint
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = tint
            appearance.performAsCurrentDrawingAppearance {
                resolved = tint.usingColorSpace(.sRGB) ?? tint
            }
            let lift = (appearance.isDarkAppearance ? 0 : 0.08) + (isHovering ? 0.1 : 0)
            return lift > 0 ? resolved.blended(withFraction: lift, of: .white) ?? resolved : resolved
        })
    }
}

/// A block's body: its fill, a faint light along the top and a hairline
/// rim, so neighbouring blocks and the track behind them stay apart.
struct StudioBlockSurface<Fill: ShapeStyle>: View {
    let fill: Fill

    var body: some View {
        let shape = StudioBlockMetrics.shape
        shape.fill(fill)
            .overlay {
                shape.fill(LinearGradient(
                    colors: [.white.opacity(0.14), .white.opacity(0)],
                    startPoint: .top,
                    endPoint: .center
                ))
            }
            .overlay {
                shape.strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5)
            }
    }
}

/// Diagonal stripes across a block, clipped to it.
struct StudioBlockHatch: View {
    let color: Color
    var spacing: CGFloat = 6
    var lineWidth: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(color), lineWidth: lineWidth)
        }
        .clipShape(StudioBlockMetrics.shape)
    }
}

/// The one label every block uses: a glyph, its name, then a quieter
/// detail - usually how long the block runs, "Audio 00:56" style. As the
/// block narrows the detail goes first, then the name (a long one is
/// truncated while a few letters still show), then the glyph sits alone,
/// centred, so nothing is ever cut to a stub like "C…".
struct StudioBlockLabel: View {
    let systemImage: String
    let title: String
    var detail: String?
    let width: CGFloat
    let color: Color

    var body: some View {
        if width >= StudioBlockMetrics.labelInset * 2 + 14 {
            HStack(spacing: 5) {
                glyph
                ViewThatFits(in: .horizontal) {
                    if let detail {
                        HStack(spacing: 6) {
                            titleText
                            Text(detail)
                                .font(.system(size: 10.5).monospacedDigit())
                                .opacity(0.8)
                        }
                        .fixedSize()
                    }
                    titleText
                        .fixedSize()
                    if width >= 88 {
                        titleText
                            .truncationMode(.tail)
                    } else {
                        Color.clear.frame(width: 0)
                    }
                }
            }
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, StudioBlockMetrics.labelInset)
            .frame(width: width, alignment: .leading)
            .allowsHitTesting(false)
        } else {
            glyph
                .foregroundStyle(color)
                .frame(width: width)
                .allowsHitTesting(false)
        }
    }

    private var glyph: some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .medium))
    }

    /// Digits keep their width, so "1.5×" doesn't shuffle as it changes.
    private var titleText: Text {
        Text(title)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
    }
}

/// Selection: a yellow rim around the block, widening past each end into a
/// handle marked with a line. The block itself is left exactly as it was.
struct StudioSelectionFrame: View {
    let blockWidth: CGFloat
    let blockHeight: CGFloat

    var body: some View {
        StudioSelectionFrameShape()
            .fill(Color(nsColor: .systemYellow), style: FillStyle(eoFill: true))
            .overlay(alignment: .leading) { grip }
            .overlay(alignment: .trailing) { grip }
            .frame(
                width: blockWidth + StudioBlockMetrics.handleWidth * 2,
                height: blockHeight + StudioBlockMetrics.rimWidth * 2
            )
    }

    private var grip: some View {
        Capsule()
            .fill(Color.black.opacity(0.55))
            .frame(width: 1.5, height: 10)
            .frame(width: StudioBlockMetrics.handleWidth)
    }
}

/// The rim's outline: the frame's rounded rect with the block cut out. The
/// outer radius is the block's plus the rim, so the two curves run parallel.
private struct StudioSelectionFrameShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = StudioBlockMetrics.cornerRadius
        let rim = StudioBlockMetrics.rimWidth
        var path = Path(roundedRect: rect, cornerRadius: radius + rim, style: .continuous)
        let block = rect.insetBy(dx: StudioBlockMetrics.handleWidth, dy: rim)
        if block.width > 0, block.height > 0 {
            path.addPath(Path(roundedRect: block, cornerRadius: radius, style: .continuous))
        }
        return path
    }
}

/// The mark inside an unselected block's end while the pointer would trim it.
struct StudioBlockGrip: View {
    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.9))
            .frame(width: 2, height: 10)
            .shadow(color: .black.opacity(0.25), radius: 0.5)
    }
}

/// The dashed block a drag across empty track would create.
private struct StudioPendingBlock: View {
    let range: ClosedRange<TimeInterval>
    let scale: StudioTimelineScale
    let height: CGFloat
    let tint: Color

    var body: some View {
        let lowX = scale.x(for: range.lowerBound)
        let highX = scale.x(for: range.upperBound)
        let shape = StudioBlockMetrics.shape
        shape
            .fill(tint.opacity(0.22))
            .overlay {
                shape.strokeBorder(tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            .frame(width: max(2, highX - lowX), height: height)
            .offset(x: lowX, y: StudioBlockMetrics.inset)
            .allowsHitTesting(false)
    }
}
