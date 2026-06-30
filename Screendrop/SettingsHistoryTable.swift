//
//  SettingsHistoryTable.swift
//  Screendrop
//

import AppKit
import QuartzCore
import SwiftUI

struct SettingsHistoryTable: NSViewRepresentable {
    let items: [ScreenshotHistoryItem]
    let isCloudConfigured: Bool
    let uploadingItems: Set<UUID>
    let onPreview: (ScreenshotHistoryItem) -> Void
    let onCopy: (ScreenshotHistoryItem) -> Void
    let onEdit: (ScreenshotHistoryItem) -> Void
    let onUpload: (ScreenshotHistoryItem) -> Void
    let onReveal: (ScreenshotHistoryItem) -> Void
    let onDelete: (ScreenshotHistoryItem) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let tableView = SettingsHistoryNSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = SettingsHistoryTableCellView.rowHeight
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.menuProvider = context.coordinator.menu(for:)

        if #available(macOS 11.0, *) {
            tableView.style = .plain
        }

        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.update(from: self, reloading: tableView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? SettingsHistoryNSTableView else { return }
        tableView.tableColumns.first?.width = scrollView.contentSize.width
        context.coordinator.update(from: self, reloading: tableView)
    }

    private static let columnIdentifier = NSUserInterfaceItemIdentifier("SettingsHistoryColumn")

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        fileprivate weak var tableView: SettingsHistoryNSTableView?

        private var items: [ScreenshotHistoryItem] = []
        private var isCloudConfigured = false
        private var uploadingItems: Set<UUID> = []

        private var onPreview: ((ScreenshotHistoryItem) -> Void)?
        private var onCopy: ((ScreenshotHistoryItem) -> Void)?
        private var onEdit: ((ScreenshotHistoryItem) -> Void)?
        private var onUpload: ((ScreenshotHistoryItem) -> Void)?
        private var onReveal: ((ScreenshotHistoryItem) -> Void)?
        private var onDelete: ((ScreenshotHistoryItem) -> Void)?

        func update(from table: SettingsHistoryTable, reloading tableView: NSTableView) {
            let needsFullReload = !hasSameRowIdentity(as: table.items)
            let needsVisibleReload = !needsFullReload && (
                items != table.items
                || isCloudConfigured != table.isCloudConfigured
                || uploadingItems != table.uploadingItems
            )

            items = table.items
            isCloudConfigured = table.isCloudConfigured
            uploadingItems = table.uploadingItems
            onPreview = table.onPreview
            onCopy = table.onCopy
            onEdit = table.onEdit
            onUpload = table.onUpload
            onReveal = table.onReveal
            onDelete = table.onDelete

            if needsFullReload {
                tableView.reloadData()
            } else if needsVisibleReload {
                reloadVisibleRows(in: tableView)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            SettingsHistoryTableCellView.rowHeight
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row) else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("SettingsHistoryCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SettingsHistoryTableCellView
                ?? SettingsHistoryTableCellView()
            cell.identifier = identifier
            cell.configure(
                item: items[row],
                showsSeparator: row < items.count - 1,
                isCloudConfigured: isCloudConfigured,
                isUploading: uploadingItems.contains(items[row].id),
                onPreview: onPreview,
                onCopy: onCopy,
                onUpload: onUpload
            )
            return cell
        }

        func menu(for row: Int) -> NSMenu? {
            guard items.indices.contains(row) else { return nil }
            let item = items[row]
            let menu = NSMenu()

            menu.addItem(menuItem("Quick Look", symbolName: "eye") { [weak self] in
                self?.onPreview?(item)
            })
            menu.addItem(menuItem("Copy", symbolName: "doc.on.doc") { [weak self] in
                self?.onCopy?(item)
            })
            menu.addItem(menuItem(
                item.isVideo ? "Edit Recording" : "Annotate",
                symbolName: item.isVideo ? "scissors" : "pencil.tip.crop.circle"
            ) { [weak self] in
                self?.onEdit?(item)
            })

            menu.addItem(.separator())

            if let cloudURL = item.cloudURL {
                menu.addItem(menuItem("Copy Cloud Link", symbolName: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cloudURL, forType: .string)
                })
            } else if isCloudConfigured && !uploadingItems.contains(item.id) {
                menu.addItem(menuItem("Upload to Cloud", symbolName: "icloud.and.arrow.up") { [weak self] in
                    self?.onUpload?(item)
                })
            }

            menu.addItem(menuItem("Reveal in Finder", symbolName: "folder") { [weak self] in
                self?.onReveal?(item)
            })

            menu.addItem(.separator())
            menu.addItem(menuItem("Delete", symbolName: "trash") { [weak self] in
                self?.onDelete?(item)
            })

            return menu
        }

        private func hasSameRowIdentity(as newItems: [ScreenshotHistoryItem]) -> Bool {
            guard items.count == newItems.count else { return false }
            return zip(items, newItems).allSatisfy { $0.id == $1.id }
        }

        private func reloadVisibleRows(in tableView: NSTableView) {
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.length > 0 else { return }
            tableView.reloadData(
                forRowIndexes: IndexSet(integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length)),
                columnIndexes: IndexSet(integer: 0)
            )
        }

        private func menuItem(_ title: String, symbolName: String, action: @escaping () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, action: action)
            item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            return item
        }
    }
}

private final class SettingsHistoryNSTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func layout() {
        super.layout()
        tableColumns.first?.width = bounds.width
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let row = row(at: location)
        guard row >= 0 else { return nil }
        return menuProvider?(row)
    }
}

private final class AspectFillImageView: NSImageView {
    override var image: NSImage? {
        didSet {
            layer?.contents = image
        }
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        return layer
    }
}

private final class SettingsHistoryTableCellView: NSTableCellView {
    static let rowHeight: CGFloat = 68

    private let thumbnailContainer = NSView()
    private let thumbnailImageView = AspectFillImageView()
    private let playImageView = NSImageView()
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let actionsStack = NSStackView()
    private let cloudButton = NSButton()
    private let progressIndicator = NSProgressIndicator()
    private let previewButton = NSButton()
    private let copyButton = NSButton()
    private let separatorView = NSView()

    private var item: ScreenshotHistoryItem?
    private var thumbnailTask: Task<Void, Never>?
    private var onPreview: ((ScreenshotHistoryItem) -> Void)?
    private var onCopy: ((ScreenshotHistoryItem) -> Void)?
    private var onUpload: ((ScreenshotHistoryItem) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        thumbnailTask?.cancel()
    }

    func configure(
        item: ScreenshotHistoryItem,
        showsSeparator: Bool,
        isCloudConfigured: Bool,
        isUploading: Bool,
        onPreview: ((ScreenshotHistoryItem) -> Void)?,
        onCopy: ((ScreenshotHistoryItem) -> Void)?,
        onUpload: ((ScreenshotHistoryItem) -> Void)?
    ) {
        thumbnailTask?.cancel()

        self.item = item
        self.onPreview = onPreview
        self.onCopy = onCopy
        self.onUpload = onUpload

        fileNameLabel.stringValue = item.fileName
        subtitleLabel.stringValue = Self.subtitle(for: item)
        thumbnailImageView.image = nil
        playImageView.isHidden = !item.isVideo
        separatorView.isHidden = !showsSeparator

        configureCloudControl(for: item, isCloudConfigured: isCloudConfigured, isUploading: isUploading)
        scheduleThumbnailLoad(for: item)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        item = nil
        thumbnailImageView.image = nil
    }

    private func setup() {
        wantsLayer = true

        thumbnailContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.wantsLayer = true
        thumbnailContainer.layer?.cornerRadius = 6
        thumbnailContainer.layer?.masksToBounds = true
        thumbnailContainer.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2).cgColor

        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.contentsGravity = .resizeAspectFill
        thumbnailImageView.layer?.masksToBounds = true

        playImageView.translatesAutoresizingMaskIntoConstraints = false
        playImageView.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Video")
        playImageView.contentTintColor = .white
        playImageView.isHidden = true

        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        fileNameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.maximumNumberOfLines = 1

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = 2
        actionsStack.detachesHiddenViews = true
        actionsStack.alphaValue = 1

        configureButton(cloudButton, symbolName: "icloud.and.arrow.up", action: #selector(cloudButtonPressed))
        configureButton(previewButton, symbolName: "eye", action: #selector(previewButtonPressed))
        configureButton(copyButton, symbolName: "doc.on.doc", action: #selector(copyButtonPressed))

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true
        updateSeparatorColor()

        thumbnailContainer.addSubview(thumbnailImageView)
        thumbnailContainer.addSubview(playImageView)
        actionsStack.addArrangedSubview(cloudButton)
        actionsStack.addArrangedSubview(progressIndicator)
        actionsStack.addArrangedSubview(previewButton)
        actionsStack.addArrangedSubview(copyButton)

        addSubview(thumbnailContainer)
        addSubview(fileNameLabel)
        addSubview(subtitleLabel)
        addSubview(actionsStack)
        addSubview(separatorView)

        NSLayoutConstraint.activate([
            thumbnailContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            thumbnailContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailContainer.widthAnchor.constraint(equalToConstant: 64),
            thumbnailContainer.heightAnchor.constraint(equalToConstant: 48),

            thumbnailImageView.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor),
            thumbnailImageView.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor),
            thumbnailImageView.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor),
            thumbnailImageView.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor),

            playImageView.centerXAnchor.constraint(equalTo: thumbnailContainer.centerXAnchor),
            playImageView.centerYAnchor.constraint(equalTo: thumbnailContainer.centerYAnchor),
            playImageView.widthAnchor.constraint(equalToConstant: 18),
            playImageView.heightAnchor.constraint(equalToConstant: 18),

            fileNameLabel.leadingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor, constant: 14),
            fileNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -12),
            fileNameLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -2),

            subtitleLabel.leadingAnchor.constraint(equalTo: fileNameLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -12),
            subtitleLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 3),

            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            actionsStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            progressIndicator.widthAnchor.constraint(equalToConstant: 20),
            progressIndicator.heightAnchor.constraint(equalToConstant: 20),

            separatorView.leadingAnchor.constraint(equalTo: fileNameLabel.leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSeparatorColor()
    }

    private func updateSeparatorColor() {
        separatorView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.16).cgColor
    }

    private func configureButton(_ button: NSButton, symbolName: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func configureCloudControl(
        for item: ScreenshotHistoryItem,
        isCloudConfigured: Bool,
        isUploading: Bool
    ) {
        if isUploading {
            cloudButton.isHidden = true
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            return
        }

        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true

        if item.cloudURL != nil {
            cloudButton.isHidden = false
            cloudButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Copy cloud link")
            cloudButton.toolTip = "Copy cloud link"
        } else if isCloudConfigured {
            cloudButton.isHidden = false
            cloudButton.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: "Upload to cloud")
            cloudButton.toolTip = "Upload to cloud"
        } else {
            cloudButton.isHidden = true
        }

        previewButton.toolTip = "Quick Look"
        copyButton.toolTip = "Copy"
    }

    private func scheduleThumbnailLoad(for item: ScreenshotHistoryItem) {
        thumbnailTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            let image = await HistoryThumbnailStore.thumbnail(for: item)
            guard !Task.isCancelled,
                  self?.item?.id == item.id,
                  self?.item?.updatedAt == item.updatedAt else {
                return
            }
            self?.thumbnailImageView.image = image
        }
    }

    @objc private func cloudButtonPressed() {
        guard let item else { return }
        if let cloudURL = item.cloudURL {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cloudURL, forType: .string)
        } else {
            onUpload?(item)
        }
    }

    @objc private func previewButtonPressed() {
        guard let item else { return }
        onPreview?(item)
    }

    @objc private func copyButtonPressed() {
        guard let item else { return }
        onCopy?(item)
    }

    private static func subtitle(for item: ScreenshotHistoryItem) -> String {
        let date = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        if item.isVideo {
            let duration = if let itemDuration = item.duration {
                formatDuration(itemDuration)
            } else {
                "unknown"
            }
            if item.pixelWidth > 0 && item.pixelHeight > 0 {
                return "\(date) · \(item.pixelWidth)×\(item.pixelHeight) · \(duration)"
            }
            return "\(date) · \(duration)"
        }
        return "\(date) · \(item.pixelWidth)×\(item.pixelHeight)"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performAction() {
        handler()
    }
}
