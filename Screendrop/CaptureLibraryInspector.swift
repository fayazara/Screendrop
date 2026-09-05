import AppKit
import SwiftUI

struct CaptureLibraryInspector: View {
    let model: CaptureLibraryModel
    @State private var byteCount: Int64?
    @State private var pendingCloudDelete: CaptureLibraryItem?
    @State private var pendingCloudUpload: CaptureLibraryItem?
    @State private var tooltip = BarTooltipModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var items: [CaptureLibraryItem] { model.selectedItems }

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Capture details")
                        .font(.headline)
                    Text("Select a screenshot or recording\nto take a closer look.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if items.count == 1, let item = items.first {
                            header(item)
                            Divider()
                            information(item)
                        } else {
                            multipleSelection
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !items.isEmpty { actionBar }
        }
        .environment(tooltip)
        .onChange(of: items.map(\.id)) { _, _ in
            tooltip.dismiss()
            pendingCloudUpload = nil
        }
        .onChange(of: model.isBusy) { _, isBusy in
            if isBusy { tooltip.dismiss() }
        }
        .onDisappear { tooltip.dismiss() }
        .task(id: items.map(\.thumbnailKey)) {
            byteCount = nil
            let urls = items.map(\.ownedURL)
            let scan = Task.detached(priority: .utility) {
                urls.reduce(Int64(0)) { total, url in
                    Task.isCancelled ? total : total + CaptureLibraryScanner.sizeOnDisk(of: url)
                }
            }
            let size = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard !Task.isCancelled else { return }
            byteCount = size
        }
        .alert("Delete from cloud?", isPresented: Binding(
            get: { pendingCloudDelete != nil }, set: { if !$0 { pendingCloudDelete = nil } }
        ), presenting: pendingCloudDelete) { item in
            Button("Delete", role: .destructive) {
                model.deleteCloudCopy(item)
                pendingCloudDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingCloudDelete = nil }
        } message: { _ in
            Text("This permanently removes the cloud copy and breaks its share link. Your local capture stays in the Library.")
        }
    }

    private func header(_ item: CaptureLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { model.perform(.preview) } label: {
                CaptureLibraryThumbnail(item: item)
                    .aspectRatio(1.45, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: item.isVideo ? "play.fill" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(10)
                    }
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .accessibilityLabel("Quick Look \(item.name)")
            .help("Open a large preview")

            VStack(alignment: .leading, spacing: 7) {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(item.kindTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if item.hasDraft {
                        statusBadge("Draft", symbol: "circle.lefthalf.filled")
                    } else if item.hasEdits {
                        statusBadge("Edited", symbol: "slider.horizontal.3")
                    }
                }
            }
        }
    }

    /// A fixed Finder-style action strip. All controls use the same icon size,
    /// hit area and hover surface, including the native menu trigger.
    private var actionBar: some View {
        HStack(spacing: 0) {
            actionButton(
                .edit, id: .libraryEdit,
                title: items.first?.isVideo == true ? "Edit Recording" : "Annotate Screenshot",
                symbol: items.first?.isVideo == true ? "film" : "pencil.tip.crop.circle"
            )
            .disabled(items.count != 1)
            actionButton(.copy, id: .libraryCopy, title: "Copy", symbol: "doc.on.doc")
            actionButton(.export, id: .libraryExport, title: "Export", symbol: "square.and.arrow.up")
            if CloudUploader.shared.isConfigured || items.contains(where: { $0.cloudURL != nil }) {
                cloudAction
            }
            moreActions(allowsRename: items.count == 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .disabled(model.isBusy)
        .coordinateSpace(name: LibraryInspectorActionChrome.coordinateSpace)
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if let target = tooltip.visible {
                    let width = geometry.size.width
                    let verticalOffset = -(BarTooltip.gap + BarTooltip.pillHeight)
                    BarTooltipPill(text: target.text)
                        .visualEffect { content, pill in
                            // Keep the end controls' tooltips inside the narrow inspector.
                            content.offset(
                                x: max(8, min(target.frame.midX - pill.size.width / 2,
                                              width - pill.size.width - 8)),
                                y: verticalOffset
                            )
                        }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: tooltip.visible?.id)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: tooltip.visible?.text)
        }
    }

    private func actionButton(_ action: CaptureLibraryAction, id: BarTooltipID, title: String, symbol: String) -> some View {
        Button {
            tooltip.dismiss()
            model.perform(action)
        } label: {
            actionIcon(symbol)
                .modifier(LibraryInspectorActionChrome(id: id, title: title))
        }
        .buttonStyle(BarButtonStyle())
        .accessibilityLabel(title)
    }

    private var cloudAction: some View {
        let item = items.count == 1 ? items.first : nil
        let isShared = item?.cloudURL != nil
        let title = isShared ? "Copy Cloud Link" : "Share to Cloud"
        return Button {
            tooltip.dismiss()
            guard let item else { return }
            if isShared {
                model.copyLink(item)
            } else {
                pendingCloudUpload = item
            }
        } label: {
            actionIcon(isShared ? "link" : "icloud.and.arrow.up")
                .modifier(LibraryInspectorActionChrome(id: .libraryCloud, title: title))
        }
        .buttonStyle(BarButtonStyle())
        .accessibilityLabel(title)
        .disabled(item == nil)
        .popover(item: $pendingCloudUpload, arrowEdge: .top) { item in
            CloudUploadOptionsPopover(suggestedTitle: item.name) { options in
                model.upload(item, options: options)
            }
        }
    }

    private func actionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
    }

    private func information(_ item: CaptureLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Information")
            VStack(spacing: 11) {
                detailRow("Dimensions", value: item.dimensions)
                if item.isVideo { detailRow("Duration", value: item.durationText) }
                detailRow("Size on disk", value: sizeText)
                detailRow("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                detailRow("Modified", value: item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var multipleSelection: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(Array(items.prefix(3))) { item in
                        CaptureLibraryThumbnail(item: item)
                            .frame(maxWidth: .infinity)
                            .frame(height: 68)
                            .clipShape(.rect(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                            }
                    }
                }
                Text("\(items.count) captures selected")
                    .font(.system(size: 16, weight: .semibold))
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Selection")
                VStack(spacing: 11) {
                    detailRow("Screenshots", value: "\(items.filter { !$0.isVideo }.count)")
                    detailRow("Recordings", value: "\(items.filter(\.isVideo).count)")
                    detailRow("Size on disk", value: sizeText)
                }
            }
        }
    }

    private func moreActions(allowsRename: Bool) -> some View {
        Menu {
            if allowsRename {
                Button("Rename…", systemImage: "pencil") { model.perform(.rename) }
            }
            Button("Reveal in Finder", systemImage: "folder") { model.perform(.reveal) }
            if items.count == 1, let item = items.first, let link = item.cloudURL {
                Divider()
                Button("Copy Cloud Link", systemImage: "link") { model.copyLink(item) }
                if let url = URL(string: link) {
                    Link(destination: url) { Label("Open Shared Capture", systemImage: "arrow.up.right") }
                }
                Button("Delete from Cloud…", systemImage: "icloud.slash", role: .destructive) {
                    pendingCloudDelete = item
                }
            }
            Divider()
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.perform(.trash) }
        } label: {
            actionIcon("ellipsis")
                .modifier(LibraryInspectorActionChrome(id: .libraryMore, title: "More Actions"))
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .simultaneousGesture(TapGesture().onEnded { tooltip.dismiss() })
        .accessibilityLabel("More capture actions")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private func statusBadge(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.055), in: Capsule())
    }

    private var sizeText: String {
        byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…"
    }
}

private struct LibraryInspectorActionChrome: ViewModifier {
    static let coordinateSpace = "libraryInspectorActions"
    let id: BarTooltipID
    let title: String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(BarTooltipModel.self) private var tooltip
    @State private var isHovering = false
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            // Size the actual control label, so its whole slot shares the
            // same click, hover and tooltip area, including the empty space.
            .frame(minWidth: 40, maxWidth: .infinity)
            .frame(height: 36)
            .background(
                Color.primary.opacity(isHovering && isEnabled ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named(Self.coordinateSpace))
            } action: { frame in
                self.frame = frame
            }
            .onHover { hovering in
                isHovering = hovering
                updateTooltip()
            }
            .onChange(of: title) { _, _ in updateTooltip() }
            .onChange(of: isEnabled) { _, _ in updateTooltip() }
            .onDisappear { tooltip.endHover(id: id) }
    }

    private func updateTooltip() {
        if isHovering && isEnabled {
            tooltip.hover(id: id, text: title, frame: frame)
        } else {
            tooltip.endHover(id: id)
        }
    }
}
