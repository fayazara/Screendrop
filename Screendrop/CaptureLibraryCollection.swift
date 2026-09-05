import AppKit
import SwiftUI

enum CaptureLibraryAction: String {
    case preview = "Quick Look"
    case edit = "Edit"
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
            (collection.collectionViewLayout as? LibraryCollectionLayout)?.displayLayout = layout
            collection.reloadData()
            collection.collectionViewLayout?.invalidateLayout()
        }
        let paths = Set(selection.compactMap { id in
            coordinator.indices[id].map { IndexPath(item: $0, section: 0) }
        })
        if collection.selectionIndexPaths != paths { collection.selectionIndexPaths = paths }
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
                cell.configure(parent.items[indexPath.item], layout: parent.layout)
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
                cell.configure(parent.items[indexPath.item], layout: parent.layout)
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
            let menu = NSMenu()
            menu.autoenablesItems = false
            for action in [CaptureLibraryAction.preview, .edit, .rename, .copy, .export, .reveal, .trash] {
                if action == .copy || action == .trash { menu.addItem(.separator()) }
                let item = NSMenuItem(title: action.rawValue, action: #selector(performMenuAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action.rawValue
                item.isEnabled = !parent.isBusy && (!(action == .rename || action == .edit || action == .preview) || count == 1)
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
        if event.clickCount == 2, !selectionIndexPaths.isEmpty { command?(.preview) }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers == "c" { command?(.copy); return }
        if flags.contains(.command), event.keyCode == 51 { command?(.trash); return }
        if !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            if event.keyCode == 49 { command?(.preview); return }
            if event.keyCode == 36 { command?(.rename); return }
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { command?(.copy) }
}

final class LibraryCollectionLayout: NSCollectionViewFlowLayout {
    var displayLayout: CaptureLibraryLayout = .grid

    override func prepare() {
        let width = max(200, collectionView?.enclosingScrollView?.contentSize.width ?? 800)
        sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        minimumInteritemSpacing = 16
        minimumLineSpacing = displayLayout == .grid ? 16 : 6
        if displayLayout == .grid {
            let columns = min(3, max(1, floor((width - 16) / 236)))
            let cellWidth = floor((width - 32 - (columns - 1) * 16) / columns)
            itemSize = CGSize(width: cellWidth, height: floor(cellWidth * 0.625) + 62)
        } else {
            itemSize = CGSize(width: width - 32, height: 76)
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

final class LibraryCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("CaptureLibraryCell")
    private var entry: CaptureLibraryItem?
    private var displayLayout: CaptureLibraryLayout = .grid
    private var host: NSHostingView<LibraryCellContent>?

    override func loadView() {
        let host = NSHostingView(rootView: LibraryCellContent(item: nil, layout: .grid, selected: false))
        host.sizingOptions = []
        self.host = host
        view = host
    }

    override var isSelected: Bool { didSet { updateContent() } }

    func configure(_ entry: CaptureLibraryItem, layout: CaptureLibraryLayout) {
        self.entry = entry
        displayLayout = layout
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
        host?.rootView = LibraryCellContent(item: entry, layout: displayLayout, selected: isSelected)
    }
}

struct LibraryCellContent: View {
    let item: CaptureLibraryItem?
    let layout: CaptureLibraryLayout
    let selected: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Group {
            if let item {
                Group {
                    if layout == .grid {
                        VStack(alignment: .leading, spacing: 8) {
                            thumbnail(item)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            labels(item)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 4)
                        }
                    } else {
                        HStack(spacing: 14) {
                            thumbnail(item).frame(width: 88, height: 58)
                            labels(item)
                            Spacer(minLength: 8)
                            Text(item.kindTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.trailing, 8)
                        }
                    }
                }
                .padding(6)
                .background(
                    Color.primary.opacity(selected ? 0.075 : isHovering ? 0.035 : 0.012),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            Color.primary.opacity(selected ? (contrast == .increased ? 0.65 : 0.28) : 0.08),
                            lineWidth: selected ? 1 : 0.5
                        )
                }
                .onHover { isHovering = $0 }
                .onChange(of: item.id) { _, _ in isHovering = false }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.name), \(item.kindTitle), \(item.subtitle)")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            } else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func labels(_ item: CaptureLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if item.cloudURL != nil { Image(systemName: "link").foregroundStyle(.secondary) }
                if item.hasDraft { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange) }
            }
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func thumbnail(_ item: CaptureLibraryItem) -> some View {
        CaptureLibraryThumbnail(item: item)
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    Label(item.durationText, systemImage: "play.fill")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(7)
                }
            }
    }
}
