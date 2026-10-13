//
//  CaptureShelfView.swift
//  Screendrop
//
//  The shelf's layout inside its edge panel: a column of cards anchored to
//  the bottom of the screen, newest on top so older cards never move when one
//  arrives; a small header above them while the pointer is on the shelf; and,
//  while tucked, a handle in the middle of the edge.
//
//  Everything moves along one axis, through the docked edge: cards arrive
//  and leave that way, tucking slides the column out that way, and the
//  handle slides in from it.
//

import SwiftUI

struct CaptureShelfView: View {
    @State private var shelf = CaptureShelf.shared
    @State private var isShelfHovered = false
    @State private var hoverEndTask: Task<Void, Never>?
    /// False until the panel's first frame. The first card is already on
    /// the shelf when the panel is built, so it never gets an insertion
    /// transition; the column slides in instead, the way later cards do.
    @State private var hasEntered = false
    @AppStorage(ScreendropPreferences.previewPositionKey) private var positionRaw = PreviewOverlayPosition.right.rawValue
    @AppStorage(ScreendropPreferences.shelfHandlePositionKey) private var handlePosition = 0.5
    /// Read here so cards already on the shelf resize as soon as the
    /// setting changes.
    @AppStorage(ScreendropPreferences.previewSizeKey) private var sizeRaw = PreviewOverlaySize.defaultSize.rawValue

    private var size: PreviewOverlaySize { PreviewOverlaySize(rawValue: sizeRaw) ?? .defaultSize }

    private var isLeft: Bool { positionRaw == PreviewOverlayPosition.left.rawValue }
    /// +1 when docked right, -1 when docked left: the direction of "out".
    private var outward: CGFloat { isLeft ? -1 : 1 }
    private var edge: HorizontalAlignment { isLeft ? .leading : .trailing }
    private var cardTransition: AnyTransition {
        .offset(x: CaptureShelfMetrics.panelWidth * outward).combined(with: .opacity)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: Alignment(horizontal: edge, vertical: .bottom)) {
                column
                    .padding(isLeft ? .leading : .trailing, CaptureShelfMetrics.edgeInset)
                    .padding(.bottom, CaptureShelfMetrics.bottomInset)
                    .offset(x: shelf.isTucked || !hasEntered ? CaptureShelfMetrics.panelWidth * outward : 0)

                if shelf.isTucked, !shelf.items.isEmpty {
                    CaptureShelfHandle(
                        count: shelf.items.count,
                        isLeft: isLeft,
                        trackHeight: proxy.size.height,
                        position: $handlePosition
                    ) {
                        shelf.open()
                    }
                    .transition(.offset(x: 60 * outward))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: Alignment(horizontal: edge, vertical: .bottom))
            .onAppear { shelf.capacity = CaptureShelfMetrics.capacity(forHeight: proxy.size.height) }
            .task {
                // Wait a turn so the panel is on screen before the slide starts.
                await Task.yield()
                shelf.noteMotion()
                withAnimation(CaptureShelf.slideIfAllowed) { hasEntered = true }
            }
            .onChange(of: proxy.size.height) { _, height in
                shelf.capacity = CaptureShelfMetrics.capacity(forHeight: height)
            }
            .onChange(of: sizeRaw) { _, _ in
                CaptureShelfPresenter.shared.applyPlacement()
                shelf.capacity = CaptureShelfMetrics.capacity(forHeight: proxy.size.height)
            }
        }
        .onChange(of: positionRaw) { _, _ in
            CaptureShelfPresenter.shared.applyPlacement()
        }
    }

    private var column: some View {
        VStack(alignment: edge, spacing: CaptureShelfMetrics.cardSpacing) {
            if showsHeader {
                CaptureShelfHeader(
                    count: shelf.items.count,
                    hasRecordings: shelf.items.contains { $0.kind == .video },
                    isLeft: isLeft,
                    controlScale: size.controlScale,
                    onTuck: { shelf.tuck(.user) },
                    onClearAll: { shelf.dismissAll() }
                )
                .padding(.bottom, CaptureShelfMetrics.headerSpacing - CaptureShelfMetrics.cardSpacing)
                .transition(.rise)
            }

            ForEach(shelf.items) { item in
                CaptureShelfCard(item: item, shelf: shelf, size: size)
                    .transition(cardTransition)
            }
        }
        .frame(width: size.cardSize.width)
        // The gaps between cards are clear, so the pointer briefly leaves the
        // shelf crossing one. Hold the hover a moment so the header doesn't
        // blink.
        .onHover(perform: setShelfHovered)
        .motion(.morphQuick, value: showsHeader)
    }

    private var showsHeader: Bool {
        isShelfHovered && !shelf.isTucked && !shelf.isMoving && !shelf.items.isEmpty && shelf.draggingID == nil
    }

    private func setShelfHovered(_ isHovered: Bool) {
        hoverEndTask?.cancel()
        if isHovered {
            isShelfHovered = true
        } else {
            hoverEndTask = Task {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                isShelfHovered = false
            }
        }
    }
}

/// Shown above the cards while the pointer is on the shelf: the count, a
/// button that tucks the shelf into the edge, and Clear All.
private struct CaptureShelfHeader: View {
    let count: Int
    let hasRecordings: Bool
    let isLeft: Bool
    /// Grows the buttons along with the cards' own controls.
    let controlScale: CGFloat
    let onTuck: () -> Void
    let onClearAll: () -> Void

    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
            HStack(spacing: GlassMetrics.gap) {
                if isLeft { tuckButton }

                GlassCapsuleButton(
                    title: "Clear All",
                    height: CaptureShelfMetrics.headerHeight,
                    scale: controlScale,
                    action: onClearAll
                )
                .catchesClicks(in: Capsule())
                .help("Dismiss \(title.lowercased())")
                .glassEffectID("clear", in: glass)

                if !isLeft { tuckButton }
            }
        }
        .frame(height: CaptureShelfMetrics.headerHeight * controlScale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var tuckButton: some View {
        GlassIconButton(
            systemImage: isLeft ? "chevron.left" : "chevron.right",
            help: "Tuck into the edge",
            size: CaptureShelfMetrics.headerHeight * controlScale,
            symbolSize: 10 * controlScale,
            action: onTuck
        )
        .catchesClicks(in: Circle())
        .glassEffectID("tuck", in: glass)
    }

    private var title: String {
        let noun = hasRecordings ? "Capture" : "Screenshot"
        return count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}

/// The tucked shelf: a slim glass tab against the docked edge, showing how
/// many captures wait inside. Clicking it, or swiping away from the edge on
/// it, brings the cards back. It drags up and down the edge, never off it,
/// and stays where it is left.
private struct CaptureShelfHandle: View {
    let count: Int
    let isLeft: Bool
    /// Height of the edge it slides along.
    let trackHeight: CGFloat
    /// 0 at the top of the track, 1 at the bottom.
    @Binding var position: Double
    let action: () -> Void

    @State private var isHovered = false
    @State private var dragStartTop: CGFloat?
    @State private var dragTop: CGFloat?

    private static let height: CGFloat = 64
    /// Keeps the handle off the menu bar side and the Dock side.
    private static let margin: CGFloat = 24

    private var travel: CGFloat {
        max(0, trackHeight - Self.height - Self.margin * 2)
    }

    private var restingTop: CGFloat {
        Self.margin + travel * CGFloat(min(max(position, 0), 1))
    }

    var body: some View {
        tab
            .frame(maxHeight: .infinity, alignment: .top)
            .offset(y: dragTop ?? restingTop)
    }

    private var tab: some View {
        VStack(spacing: 6) {
            Image(systemName: isLeft ? "chevron.right" : "chevron.left")
                .font(.system(size: 9, weight: .bold))
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
        .foregroundStyle(Palette.label)
        .frame(width: isHovered || dragTop != nil ? 30 : 24, height: Self.height)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: handleShape)
        .catchesClicks(in: handleShape)
        // One gesture handles both, so a click whose pointer wobbles a
        // little on a trackpad still opens the shelf instead of being lost
        // between a tap and a drag.
        .gesture(pressAndDrag)
        .pointerStyle(dragTop == nil ? .grabIdle : .grabActive)
        .padding(isLeft ? .leading : .trailing, 3)
        .onHover { isHovered = $0 }
        .motion(.morphQuick, value: isHovered)
        .motion(.morphQuick, value: count)
        .help(count == 1 ? "Show 1 capture · drag to move" : "Show \(count) captures · drag to move")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Show captures")
        .accessibilityValue("\(count)")
        .accessibilityAction { action() }
    }

    /// Movement under which a press is still a click.
    private static let clickSlop: CGFloat = 6

    private var pressAndDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartTop ?? restingTop
                dragStartTop = start
                guard dragTop != nil || value.translation.isBeyond(Self.clickSlop) else { return }
                dragTop = min(max(start + value.translation.height, Self.margin), Self.margin + travel)
            }
            .onEnded { _ in
                if let dragTop {
                    if travel > 0 {
                        position = Double((dragTop - Self.margin) / travel)
                    }
                } else {
                    action()
                }
                dragTop = nil
                dragStartTop = nil
            }
    }

    private var handleShape: UnevenRoundedRectangle {
        let outer: CGFloat = 8
        let inner: CGFloat = 13
        return UnevenRoundedRectangle(
            topLeadingRadius: isLeft ? outer : inner,
            bottomLeadingRadius: isLeft ? outer : inner,
            bottomTrailingRadius: isLeft ? inner : outer,
            topTrailingRadius: isLeft ? inner : outer,
            style: .continuous
        )
    }
}

private extension View {
    /// Gives a glass control pixels the window server can hit. The shelf's
    /// panel is clear, and clicks on its clear pixels fall through to the
    /// window beneath. On macOS 26 glass is composited outside the window's
    /// own pixels, so a glass control is clear to the window server and only
    /// its glyphs caught clicks. A fill too faint to see makes the whole
    /// shape solid to it.
    func catchesClicks(in shape: some Shape) -> some View {
        // Alpha is stored in 8 bits; anything under 1/255 rounds to clear.
        background(shape.fill(Color.black.opacity(0.01)))
    }
}

private extension CGSize {
    func isBeyond(_ distance: CGFloat) -> Bool {
        width * width + height * height > distance * distance
    }
}
