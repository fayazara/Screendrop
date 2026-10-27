import AppKit
import SwiftUI

enum CaptureLibraryAction: String {
    /// Double-click or Space: Edit for a video, Quick Look for anything else.
    case open = "Open"
    case preview = "Quick Look"
    case edit = "Edit"
    case pin = "Pin to Screen"
    case rename = "Rename…"
    case copy = "Copy"
    case export = "Export…"
    case reveal = "Reveal in Finder"
    case trash = "Move to Trash"
}

/// Both layouts use NSCollectionView's reuse queue. Changing selection doesn't
/// reload the collection; data changes reconcile selection by stable media IDs.
struct CaptureLibraryCollection: NSViewRepresentable {
    let items: [CaptureLibraryItem]
    let revision: Int
    let layout: CaptureLibraryLayout
    let searchTokens: [String]
    @Binding var selection: Set<String>
    let isBusy: Bool
    let onAction: (CaptureLibraryAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let collection = LibraryCollectionView()
        collection.autoresizingMask = [.width]
        collection.setAccessibilityLabel("Captures")
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.configureLayout(layout)
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.command = { [weak coordinator = context.coordinator] action in
            guard let coordinator, !coordinator.parent.isBusy else { return }
            coordinator.parent.onAction(action)
        }
        collection.contextMenuProvider = { [weak coordinator = context.coordinator] event in
            coordinator?.menu(for: event)
        }
        scrollView.documentView = collection
        context.coordinator.collection = collection
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let old = coordinator.parent
        coordinator.parent = self
        guard let collection = coordinator.collection else { return }
        coordinator.updating = true
        defer { coordinator.updating = false }
        if old.revision != revision || old.layout != layout || coordinator.initialLoad {
            coordinator.initialLoad = false
            coordinator.indices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
            if let flow = collection.collectionViewLayout as? LibraryCollectionLayout {
                flow.displayLayout = layout
                flow.aspects = items.map { item in
                    item.pixelHeight > 0 ? CGFloat(item.pixelWidth) / CGFloat(item.pixelHeight) : 1.6
                }
            }
            collection.reloadData()
            collection.collectionViewLayout?.invalidateLayout()
        }
        let paths = Set(selection.compactMap { id in
            coordinator.indices[id].map { IndexPath(item: $0, section: 0) }
        })
        if collection.selectionIndexPaths != paths {
            // A selection made elsewhere (the inspector's Similar captures)
            // scrolls into view; clicks in the grid are already visible.
            collection.selectionIndexPaths = paths
            if paths.count == 1, let path = paths.first, !collection.indexPathsForVisibleItems().contains(path) {
                collection.animator().scrollToItems(at: paths, scrollPosition: .centeredVertically)
            }
        }
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: CaptureLibraryCollection
        weak var collection: LibraryCollectionView?
        var updating = false
        var initialLoad = true
        var indices: [String: Int] = [:]

        init(_ parent: CaptureLibraryCollection) { self.parent = parent }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.items.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: LibraryCollectionItem.identifier, for: indexPath)
            if let cell = cell as? LibraryCollectionItem, parent.items.indices.contains(indexPath.item) {
                cell.configure(parent.items[indexPath.item], layout: parent.layout, searchTokens: parent.searchTokens)
            }
            return cell
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            (item as? LibraryCollectionItem)?.clearContent()
        }

        func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            if let cell = item as? LibraryCollectionItem, parent.items.indices.contains(indexPath.item) {
                cell.configure(parent.items[indexPath.item], layout: parent.layout, searchTokens: parent.searchTokens)
            }
        }

        private func selectionChanged() {
            guard !updating, let collection else { return }
            parent.selection = Set(collection.selectionIndexPaths.compactMap {
                parent.items.indices.contains($0.item) ? parent.items[$0.item].id : nil
            })
        }

        func menu(for event: NSEvent) -> NSMenu? {
            guard let collection,
                  let path = collection.indexPathForItem(at: collection.convert(event.locationInWindow, from: nil)) else { return nil }
            if !collection.selectionIndexPaths.contains(path) {
                collection.selectionIndexPaths = [path]
                selectionChanged()
            }
            let count = collection.selectionIndexPaths.count
            let singleIndex = count == 1 ? collection.selectionIndexPaths.first?.item : nil
            let singleItem = singleIndex.flatMap { parent.items.indices.contains($0) ? parent.items[$0] : nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for action in [CaptureLibraryAction.preview, .edit, .pin, .rename, .copy, .export, .reveal, .trash] {
                if action == .copy || action == .trash { menu.addItem(.separator()) }
                let title: String
                if action == .edit {
                    // Images open in the annotator, so name the action after
                    // what it actually does.
                    title = singleItem == nil ? "Edit" : (singleItem!.isVideo ? "Edit Recording" : "Annotate")
                } else {
                    title = action.rawValue
                }
                let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action.rawValue
                item.isEnabled = !parent.isBusy
                    && (!(action == .rename || action == .edit || action == .preview) || count == 1)
                    && (action != .pin || singleItem?.isVideo == false)
                menu.addItem(item)
            }
            return menu
        }

        @objc private func performMenuAction(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let action = CaptureLibraryAction(rawValue: raw), !parent.isBusy else { return }
            parent.onAction(action)
        }
    }
}

final class LibraryCollectionView: NSCollectionView {
    var command: ((CaptureLibraryAction) -> Void)?
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?

    func configureLayout(_ displayLayout: CaptureLibraryLayout) {
        let flow = LibraryCollectionLayout()
        flow.displayLayout = displayLayout
        // Installing a layout initializes AppKit's data-source/reuse machinery.
        // Registering first loses the class registration and makes the first
        // dequeue fall back to a nonexistent CaptureLibraryCell nib.
        collectionViewLayout = flow
        register(LibraryCollectionItem.self, forItemWithIdentifier: LibraryCollectionItem.identifier)
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?(event) }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, !selectionIndexPaths.isEmpty { command?(.open) }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers == "c" { command?(.copy); return }
        if flags.contains(.command), event.keyCode == 51 { command?(.trash); return }
        if !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            if event.keyCode == 49 { command?(.open); return }
            if event.keyCode == 36 { command?(.rename); return }
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { command?(.copy) }
}

/// The grid is justified like a photo library: each tile keeps its capture's
/// shape and every full row spans the width, so wide and tall captures sit
/// together without letterboxing. The list is one full-width row per item.
/// Frames are computed once per data or width change; lookups by rect binary
/// search them, so scrolling cost doesn't grow with the Library.
final class LibraryCollectionLayout: NSCollectionViewLayout {
    var displayLayout: CaptureLibraryLayout = .grid
    /// Width over height for each item, in data-source order.
    var aspects: [CGFloat] = []

    private static let rowHeight: CGFloat = 170
    /// Tiles carry their own 6pt selection inset, so the visible gap between
    /// thumbnails is this plus 12.
    private static let gutter: CGFloat = 2
    private static let margins = NSEdgeInsets(top: 14, left: 16, bottom: 24, right: 16)
    private static let listMargins = NSEdgeInsets(top: 12, left: 14, bottom: 20, right: 14)
    /// Panoramas and very tall captures are cropped to these bounds rather
    /// than becoming slivers or swallowing a row.
    private static let aspectRange: ClosedRange<CGFloat> = 0.6...2.4

    private var frames: [CGRect] = []
    private var contentSize: NSSize = .zero
    private var preparedWidth: CGFloat = -1

    override func prepare() {
        super.prepare()
        let width = max(200, collectionView?.enclosingScrollView?.contentSize.width ?? 800)
        preparedWidth = width
        frames = displayLayout == .grid ? justifiedFrames(width: width) : listFrames(width: width)
        let margins = displayLayout == .grid ? Self.margins : Self.listMargins
        contentSize = NSSize(width: width, height: (frames.last?.maxY ?? 0) + margins.bottom)
    }

    private func listFrames(width: CGFloat) -> [CGRect] {
        let margins = Self.listMargins
        return aspects.indices.map { index in
            CGRect(x: margins.left, y: margins.top + CGFloat(index) * 66,
                   width: width - margins.left - margins.right, height: 64)
        }
    }

    private func justifiedFrames(width: CGFloat) -> [CGRect] {
        let margins = Self.margins
        let gutter = Self.gutter
        let chrome = LibraryCellContent.inset * 2
        let usable = width - margins.left - margins.right
        var frames: [CGRect] = []
        frames.reserveCapacity(aspects.count)
        var y = margins.top
        var row: [CGFloat] = []

        func place(_ row: [CGFloat], thumbnailHeight: CGFloat, fill: Bool) {
            var x = margins.left
            let height = (thumbnailHeight + chrome).rounded()
            for (index, aspect) in row.enumerated() {
                var tileWidth = (aspect * thumbnailHeight + chrome).rounded(.down)
                // The last tile of a full row absorbs rounding so the row
                // ends flush with the margin.
                if fill, index == row.count - 1 { tileWidth = margins.left + usable - x }
                frames.append(CGRect(x: x, y: y, width: tileWidth, height: height))
                x += tileWidth + gutter
            }
            y += height + gutter
        }

        for raw in aspects {
            let aspect = min(max(raw.isFinite && raw > 0 ? raw : 1.6, Self.aspectRange.lowerBound), Self.aspectRange.upperBound)
            row.append(aspect)
            let fixed = CGFloat(row.count) * chrome + CGFloat(row.count - 1) * gutter
            let aspectSum = row.reduce(0, +)
            if aspectSum * Self.rowHeight + fixed >= usable {
                // Shrink the row's height until it spans the width exactly.
                place(row, thumbnailHeight: max(40, (usable - fixed) / aspectSum), fill: true)
                row.removeAll(keepingCapacity: true)
            }
        }
        // The last, partial row keeps the natural height and sits left.
        if !row.isEmpty { place(row, thumbnailHeight: Self.rowHeight, fill: false) }
        return frames
    }

    override var collectionViewContentSize: NSSize { contentSize }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        // Rows run top to bottom, so maxY never decreases along `frames`.
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY < rect.minY { low = mid + 1 } else { high = mid }
        }
        var result: [NSCollectionViewLayoutAttributes] = []
        var index = low
        while index < frames.count, frames[index].minY <= rect.maxY {
            if frames[index].intersects(rect) { result.append(attributes(at: index)) }
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        frames.indices.contains(indexPath.item) ? attributes(at: indexPath.item) : nil
    }

    private func attributes(at index: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = frames[index]
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != preparedWidth
    }
}

final class LibraryCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("CaptureLibraryCell")
    private var entry: CaptureLibraryItem?
    private var displayLayout: CaptureLibraryLayout = .grid
    private var searchTokens: [String] = []
    private var host: NSHostingView<LibraryCellContent>?

    override func loadView() {
        let host = NSHostingView(rootView: LibraryCellContent(item: nil, layout: .grid, searchTokens: [], selected: false))
        host.sizingOptions = []
        self.host = host
        view = host
    }

    override var isSelected: Bool { didSet { updateContent() } }

    func configure(_ entry: CaptureLibraryItem, layout: CaptureLibraryLayout, searchTokens: [String]) {
        self.entry = entry
        displayLayout = layout
        self.searchTokens = searchTokens
        updateContent()
    }

    func clearContent() {
        entry = nil
        updateContent()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearContent()
    }

    private func updateContent() {
        _ = view
        host?.rootView = LibraryCellContent(item: entry, layout: displayLayout, searchTokens: searchTokens, selected: isSelected)
    }
}

struct LibraryCellContent: View {
    let item: CaptureLibraryItem?
    let layout: CaptureLibraryLayout
    let searchTokens: [String]
    let selected: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    /// The cell's inset around its thumbnail; the cell's corner is the
    /// thumbnail's plus this, so the two stay concentric.
    static let inset: CGFloat = 6
    private static var cellRadius: CGFloat { Radius.nested(inner: Radius.thumbnail, padding: inset) }

    var body: some View {
        Group {
            if let item {
                Group {
                    if layout == .grid {
                        thumbnail(item)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay { textMatches(item) }
                            .overlay(alignment: .topLeading) { statusBadges(item) }
                    } else {
                        HStack(spacing: 12) {
                            thumbnail(item).frame(width: 76, height: 50)
                            labels(item)
                            Spacer(minLength: 8)
                            Text(item.kindTitle)
                                .font(.dsCaption)
                                .foregroundStyle(Palette.secondaryLabel)
                                .padding(.trailing, 8)
                        }
                    }
                }
                .padding(Self.inset)
                .background(
                    selected ? Palette.selectedFill : isHovering ? Palette.fill : .clear,
                    in: RoundedRectangle(cornerRadius: Self.cellRadius, style: .continuous)
                )
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: Self.cellRadius, style: .continuous)
                            .strokeBorder(
                                Palette.accent.opacity(contrast == .increased ? 0.7 : 0.35),
                                lineWidth: 1
                            )
                    }
                }
                .onHover { isHovering = $0 }
                .onChange(of: item.id) { _, _ in isHovering = false }
                .animation(reduceMotion ? nil : .morphQuick, value: selected)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
                .help(layout == .grid ? item.name : "")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.name), \(item.kindTitle), \(item.subtitle)")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            } else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func labels(_ item: CaptureLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.cloudURL != nil {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.secondaryLabel)
                }
                if item.hasDraft {
                    Circle()
                        .fill(Palette.warning)
                        .frame(width: 5, height: 5)
                        .help("Unsaved edits")
                }
            }
            Text(item.subtitle)
                .font(.dsCaption)
                .foregroundStyle(Palette.secondaryLabel)
                .lineLimit(1)
        }
    }

    /// Marks where the search words appear in the capture. Read only while
    /// searching, so the index's batches don't redraw idle tiles.
    @ViewBuilder
    private func textMatches(_ item: CaptureLibraryItem) -> some View {
        if !searchTokens.isEmpty, let lines = CaptureLibraryIndex.shared.analyses[item.id]?.lines {
            let rects = CaptureLibrarySearch.highlights(in: lines, tokens: searchTokens)
            if !rects.isEmpty {
                GeometryReader { geometry in
                    let image = fittedImageRect(item, in: geometry.size)
                    ForEach(rects.indices, id: \.self) { index in
                        let rect = rects[index]
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Palette.highlight.opacity(0.28))
                            .strokeBorder(Palette.highlight, lineWidth: 1)
                            .frame(width: max(6, rect.width * image.width) + 4, height: max(4, rect.height * image.height) + 4)
                            .position(x: image.minX + rect.midX * image.width, y: image.minY + rect.midY * image.height)
                    }
                }
                .clipShape(.rect(cornerRadius: Radius.thumbnail, style: .continuous))
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }

    /// Where the thumbnail's aspect-fit image sits inside the tile.
    private func fittedImageRect(_ item: CaptureLibraryItem, in size: CGSize) -> CGRect {
        guard item.pixelWidth > 0, item.pixelHeight > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let aspect = CGFloat(item.pixelWidth) / CGFloat(item.pixelHeight)
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// Grid tiles drop the name, so the link and draft marks ride on the
    /// thumbnail in the same dark capsule as the video duration.
    @ViewBuilder
    private func statusBadges(_ item: CaptureLibraryItem) -> some View {
        if item.cloudURL != nil || item.hasDraft {
            HStack(spacing: 4) {
                if item.cloudURL != nil {
                    Image(systemName: "link")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
                if item.hasDraft {
                    Circle()
                        .fill(Palette.warning)
                        .frame(width: 5, height: 5)
                        .help("Unsaved edits")
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
        }
    }

    private func thumbnail(_ item: CaptureLibraryItem) -> some View {
        CaptureLibraryThumbnail(item: item)
            .clipShape(.rect(cornerRadius: Radius.thumbnail, style: .continuous))
            .hairline(radius: Radius.thumbnail, opacity: 0.08)
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 7, weight: .bold))
                        Text(item.durationText)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
                }
            }
    }
}
