import AppKit
import SwiftUI

struct CaptureLibraryInspector: View {
    let model: CaptureLibraryModel
    @State private var byteCount: Int64?
    @State private var pendingCloudDelete: CaptureLibraryItem?
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
                            if item.cloudURL != nil || CloudUploader.shared.isConfigured {
                                Divider()
                                sharing(item)
                            }
                            Divider()
                            fileLocation(item)
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
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                actionButton(
                    .edit,
                    title: items.first?.isVideo == true ? "Edit Recording" : "Annotate Screenshot",
                    symbol: items.first?.isVideo == true ? "film" : "pencil.tip.crop.circle"
                )
                .disabled(items.count != 1)
                .frame(maxWidth: .infinity)
                actionButton(.copy, title: "Copy", symbol: "doc.on.doc")
                    .frame(maxWidth: .infinity)
                actionButton(.export, title: "Export", symbol: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                moreActions(allowsRename: items.count == 1)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .disabled(model.isBusy)
        }
        .background(.bar)
    }

    private func actionButton(_ action: CaptureLibraryAction, title: String, symbol: String) -> some View {
        Button { model.perform(action) } label: {
            actionIcon(symbol)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(LibraryInspectorActionChrome())
        .help(title)
        .accessibilityLabel(title)
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

    private func fileLocation(_ item: CaptureLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Location")
                Spacer()
                Button { model.perform(.reveal) } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(model.isBusy)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.session != nil ? "shippingbox" : "doc")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.ownedURL.lastPathComponent)
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(item.ownedURL.deletingLastPathComponent().abbreviatedPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
                .textSelection(.enabled)
            }
            .help(item.ownedURL.path)
        }
    }

    @ViewBuilder private func sharing(_ item: CaptureLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Sharing")
                Spacer()
                if item.cloudURL != nil {
                    Menu {
                        Button("Delete from Cloud…", systemImage: "icloud.slash", role: .destructive) {
                            pendingCloudDelete = item
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Cloud sharing options")
                }
            }
            if let link = item.cloudURL, let url = URL(string: link) {
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    Text(link)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Button { model.copyLink(item) } label: {
                        Label("Copy Link", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    Link(destination: url) { Image(systemName: "arrow.up.right") }
                        .help("Open shared capture")
                        .accessibilityLabel("Open shared capture")
                }
                .buttonStyle(.bordered)
            } else {
                Text("Create a link to share this capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CloudUploadButton(suggestedTitle: item.name, onUpload: { model.upload(item, options: $0) }) {
                    Label("Share to Cloud", systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .disabled(model.isBusy)
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
            Divider()
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.perform(.trash) }
        } label: {
            actionIcon("ellipsis")
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .modifier(LibraryInspectorActionChrome())
        .help("More actions")
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
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .frame(width: 40, height: 36)
            .background(
                Color.primary.opacity(isHovering && isEnabled ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .onHover { isHovering = $0 }
    }
}
