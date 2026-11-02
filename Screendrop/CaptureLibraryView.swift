import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Library's scene keeps its window, and the view tree inside it, after
/// the window closes. Swapping the content out on close frees the grid's
/// cells, layers and decoded thumbnails until the window opens again.
struct CaptureLibraryWindow: View {
    @State private var isOpen = true
    @State private var window: NSWindow?

    var body: some View {
        Group {
            if isOpen { CaptureLibraryView() } else { Color.clear }
        }
        .onAppear { isOpen = true }
        .onWindowChange { window = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard let closing = notification.object as? NSWindow, closing === window else { return }
            isOpen = false
            Task { await CaptureLibraryThumbnails.shared.removeAll() }
        }
    }
}

struct CaptureLibraryView: View {
    @State private var model = CaptureLibraryModel.shared
    @State private var history = ScreenshotHistoryStore.shared
    @State private var projects = RecordingProjectStore.shared
    @State private var index = CaptureLibraryIndex.shared
    @State private var libraryWindow: NSWindow?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @AppStorage("captureLibrary.layout") private var layout: CaptureLibraryLayout = .grid
    @AppStorage("captureLibrary.inspectorVisible") private var inspectorVisible = true
    @AppStorage("captureLibrary.sort") private var savedSort: CaptureLibrarySort = .newest
    @AppStorage("captureLibrary.categoriesExpanded") private var categoriesExpanded = true
    @AppStorage("captureLibrary.appsExpanded") private var appsExpanded = true
    @AppStorage(ScreendropPreferences.libraryAnalyzeCapturesKey) private var analyzeCaptures = true
    @AppStorage(ScreendropPreferences.librarySortExistingKey) private var sortExisting = false
    @AppStorage(ScreendropPreferences.librarySortOfferDismissedKey) private var sortOfferDismissed = false

    private static let sidebarFade: CGFloat = 28

    private var scope: CaptureLibraryScope { model.scope ?? .kind(.all) }

    /// The one-time offer to sort older captures with the model.
    private var showsSortOffer: Bool {
        analyzeCaptures && !sortExisting && !sortOfferDismissed && index.unsortedExistingCount > 0
    }
    private var activeFilter: CaptureLibraryFilter {
        if case .kind(let filter) = scope { filter } else { .all }
    }
    private var scopeTitle: String {
        switch scope {
        case .kind(let filter): filter.title
        case .category(let category): category.title
        case .app(let key): model.appFacets.first { $0.id == key }?.name ?? "App"
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                List(selection: $model.scope) {
                    Section("Library") {
                        ForEach(CaptureLibraryFilter.allCases) { filter in
                            LibrarySidebarRow(title: filter.title, count: model.count(for: filter)) {
                                Image(systemName: filter.symbol)
                            }
                            .tag(CaptureLibraryScope.kind(filter))
                        }
                    }
                    if analyzeCaptures, !model.categoryFacets.isEmpty {
                        Section("Categories", isExpanded: $categoriesExpanded) {
                            ForEach(model.categoryFacets, id: \.category) { facet in
                                LibrarySidebarRow(title: facet.category.title, count: facet.count) {
                                    Image(systemName: facet.category.symbol)
                                }
                                .tag(CaptureLibraryScope.category(facet.category))
                            }
                        }
                    }
                    if !model.appFacets.isEmpty {
                        Section("Apps", isExpanded: $appsExpanded) {
                            ForEach(model.appFacets) { app in
                                LibrarySidebarRow(title: app.name, count: app.count) {
                                    Image(nsImage: LibraryAppIcons.icon(for: app.bundleIdentifier))
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                }
                                .tag(CaptureLibraryScope.app(app.id))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                // A long list fades out above Settings rather than ending at a
                // hard edge; the margin lets the last row scroll clear of it.
                .contentMargins(.bottom, Self.sidebarFade, for: .scrollContent)
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.sidebarFade)
                    }
                }
                LibrarySidebarFooter()
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if showsSortOffer {
                    LibrarySortOffer(count: index.unsortedExistingCount) {
                        index.sortExistingCaptures()
                    } onDismiss: {
                        sortOfferDismissed = true
                    }
                    .transition(.opacity)
                    Divider()
                }
                browser
                Divider()
                statusBar
            }
            .navigationTitle(scopeTitle)
            .navigationSubtitle("Screendrop")
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $inspectorVisible) {
            // Keep the inspector's ideal size out of the split view's
            // constraint pass; its width belongs to the split view.
            GeometryReader { _ in
                CaptureLibraryInspector(model: model)
            }
            .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .toolbar { toolbar }
        .frame(minWidth: 860, minHeight: 540)
        .onAppear {
            AppActivationPolicy.enter()
            CaptureLibraryIndex.shared.start()
            model.windowDidOpen()
            UpdaterManager.shared.checkForUpdateInformation()
            model.sortOrder = savedSort
            model.refresh()
        }
        .onDisappear {
            AppActivationPolicy.leave()
            model.windowDidClose()
        }
        .onWindowChange { window in
            libraryWindow = window
            PreviewWindowCaptureExclusion.shared.register(window: window)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window === libraryWindow { model.refresh() }
        }
        .onChange(of: history.items) { _, _ in model.refresh() }
        .onChange(of: projects.projects) { _, _ in model.refresh() }
        .onChange(of: model.sortOrder) { _, value in savedSort = value }
        .onChange(of: analyzeCaptures) { _, enabled in
            if !enabled, case .category = scope { model.scope = .kind(.all) }
        }
        .animation(.morphIfAllowed, value: showsSortOffer)
        .alert("Rename Capture", isPresented: Binding(
            get: { model.renamingItem != nil },
            set: { if !$0 { model.renamingItem = nil } }
        )) {
            TextField("Name", text: $model.renameText)
            Button("Rename") { model.rename() }
                .disabled(model.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { model.renamingItem = nil }
        }
        .alert("Move \(model.pendingTrash.count == 1 ? "capture" : "\(model.pendingTrash.count) captures") to Trash?", isPresented: Binding(
            get: { !model.pendingTrash.isEmpty },
            set: { if !$0 { model.pendingTrash = [] } }
        )) {
            Button("Move to Trash", role: .destructive) { model.movePendingItemsToTrash() }
            Button("Cancel", role: .cancel) { model.pendingTrash = [] }
        } message: {
            Text("The local files and their edits will move to Trash. Exported copies and cloud links will remain available.")
        }
        .alert("The Library action could not be completed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder private var browser: some View {
        if model.items.isEmpty && model.isLoading {
            ProgressView().controlSize(.regular).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleItems.isEmpty {
            if !model.searchText.isEmpty {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "No Results",
                    message: "Nothing in \(scopeTitle) matches “\(model.searchText)”."
                ) {
                    GlassCapsuleButton(title: "Clear Search", height: GlassMetrics.actionHeight) {
                        model.searchText = ""
                    }
                }
            } else if scope != .kind(activeFilter) {
                EmptyStateView(
                    systemImage: "square.dashed",
                    title: "Nothing Here",
                    message: "No captures are filed under \(scopeTitle) right now."
                )
            } else {
                EmptyStateView(
                    systemImage: activeFilter.symbol,
                    title: "No \(activeFilter == .all ? "Captures" : activeFilter.title) Yet",
                    message: emptyLibraryDescription
                ) {
                    if activeFilter != .recordings {
                        GlassCapsuleButton(
                            title: "Capture Area",
                            systemImage: "rectangle.dashed",
                            height: GlassMetrics.actionHeight,
                            isProminent: activeFilter == .screenshots || activeFilter == .all
                        ) {
                            CaptureCoordinator.shared.captureArea()
                        }
                    }
                    if activeFilter != .screenshots {
                        GlassCapsuleButton(
                            title: "Record Screen",
                            systemImage: "record.circle",
                            height: GlassMetrics.actionHeight,
                            isProminent: activeFilter == .recordings
                        ) {
                            RecordingPickerPresenter.shared.show()
                        }
                        .disabled(ScreenRecordingManager.shared.isActive)
                    }
                }
            }
        } else {
            CaptureLibraryCollection(items: model.visibleItems, revision: model.contentRevision, layout: layout,
                searchTokens: model.searchTokens, selection: $model.selection, isBusy: model.isBusy, onAction: model.perform)
        }
    }

    private var emptyLibraryDescription: String {
        switch activeFilter {
        case .all: "Every screenshot and recording you take lands here, ready to annotate, edit and share."
        case .screenshots: "Screenshots you take land here, ready to annotate and share."
        case .recordings: "Recordings land here as editable projects, ready for Studio."
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let title = model.operationTitle {
                if let id = model.uploadingItemID,
                   let progress = CloudUploader.shared.uploadProgress[id] {
                    ProgressView(value: min(progress, 0.99))
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                        .accessibilityLabel("Upload progress")
                    Text(progress >= 0.99 ? "Finishing upload…" : title)
                    Text(min(progress, 0.99), format: .percent.precision(.fractionLength(0)).rounded(rule: .down))
                        .foregroundStyle(.primary)
                } else {
                    ProgressView().controlSize(.mini)
                    Text(title)
                }
            } else {
                Text("\(model.visibleItems.count) \(model.visibleItems.count == 1 ? "capture" : "captures")")
                if !model.selection.isEmpty { Text("· \(model.selection.count) selected") }
            }
            Spacer()
            if index.pendingCount > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    if index.readingCount > 0 {
                        Text("Reading text in \(index.readingCount) \(index.readingCount == 1 ? "capture" : "captures")")
                    } else {
                        Text("Sorting \(index.sortingCount) \(index.sortingCount == 1 ? "capture" : "captures")")
                    }
                }
                .help("Screendrop reads the text in each capture so search can find it, then sorts it into a category. All on this Mac.")
            } else if model.isLoading {
                ProgressView().controlSize(.mini).help("Refreshing Library")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Not `.searchable`: macOS always puts the system field at the far
        // right, where the inspector toggle belongs.
        ToolbarItem(placement: .primaryAction) {
            LibrarySearchField(text: $model.searchText)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Capture Fullscreen", systemImage: "macwindow") { CaptureCoordinator.shared.captureFullscreen() }
                Button("Capture Window", systemImage: "macwindow.on.rectangle") { CaptureCoordinator.shared.captureWindow() }
                Button("Capture Area", systemImage: "rectangle.dashed") { CaptureCoordinator.shared.captureArea() }
                Divider()
                Button("Record Screen", systemImage: "record.circle") { RecordingPickerPresenter.shared.show() }
                    .disabled(ScreenRecordingManager.shared.isActive)
            } label: { Label("New Capture", systemImage: "plus") }
            .menuIndicator(.hidden)
            .help("New capture")
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $layout) {
                Label("Grid View", systemImage: "square.grid.2x2").tag(CaptureLibraryLayout.grid).help("Grid view")
                Label("List View", systemImage: "list.bullet").tag(CaptureLibraryLayout.list).help("List view")
            }
            .labelStyle(.iconOnly)
            .pickerStyle(.segmented)
            .help("Switch between grid and list")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $model.sortOrder) {
                    ForEach(CaptureLibrarySort.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            .menuIndicator(.hidden)
            .help("Sort captures")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { withAnimation(.morphIfAllowed) { inspectorVisible.toggle() } } label: {
                Label(inspectorVisible ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(inspectorVisible ? "Hide Inspector" : "Show Inspector")
        }
    }
}

private struct LibrarySidebarRow<Icon: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        // Not a Label: the sidebar tints Label icons with the accent. These
        // stay a quiet, filled grey with room between glyph and title.
        HStack(spacing: 12) {
            icon()
                .symbolVariant(.fill)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(count, format: .number)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The toolbar's search field, on the toolbar's own glass. ⌘F focuses it and
/// Escape clears it.
private struct LibrarySearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.secondaryLabel)
            TextField("Search apps and text", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand {
                    text = ""
                    isFocused = false
                }
            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Palette.secondaryLabel)
            }
            .buttonStyle(.plain)
            .opacity(text.isEmpty ? 0 : 1)
            .disabled(text.isEmpty)
            .help("Clear Search")
        }
        .padding(.horizontal, 8)
        .frame(width: 220)
        .background {
            Button("") { isFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }
}

/// App icons for the sidebar, resolved once per app.
@MainActor
enum LibraryAppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleIdentifier: String?) -> NSImage {
        let key = bundleIdentifier ?? ""
        if let icon = cache[key] { return icon }
        let icon = bundleIdentifier
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        cache[key] = icon
        return icon
    }
}

/// Offers, once, to sort captures made before sorting existed. It can take
/// an hour or more, so it waits for a yes; Settings has the same switch.
/// Never let its text size the bar (no `fixedSize`): see `frame(height:)`.
private struct LibrarySortOffer: View {
    let count: Int
    let onAccept: () -> Void
    let onDismiss: () -> Void

    /// The model takes about 1.3s a capture on Apple silicon.
    private var estimate: String {
        let minutes = max(5, (Double(count) * 1.3 / 60 / 5).rounded() * 5)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .full
        return formatter.string(from: minutes * 60) ?? "a while"
    }

    var body: some View {
        HStack(spacing: Space.l) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sort your existing captures?")
                    .font(.dsHeadline)
                    .foregroundStyle(Palette.label)
                Text("Apple Intelligence can sort \(count.formatted()) older \(count == 1 ? "capture" : "captures") into categories, with titles and keywords for search. About \(estimate), on this Mac. New captures are sorted as you take them.")
                    .font(.dsCallout)
                    .foregroundStyle(Palette.secondaryLabel)
                    .lineLimit(2)
            }
            Spacer(minLength: Space.l)
            GlassCapsuleButton(title: "Not Now", action: onDismiss)
            GlassCapsuleButton(title: "Sort Captures", isProminent: true, action: onAccept)
        }
        .padding(.horizontal, Space.xl)
        // A fixed height: a bar whose height follows its wrapped text sends
        // the split view's constraint passes into a loop and AppKit aborts.
        .frame(height: 64)
    }
}

/// Settings, plus a blue download button while a newer release is waiting.
private struct LibrarySidebarFooter: View {
    @ObservedObject private var updater = UpdaterManager.shared
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: GlassMetrics.gap) {
            Button {
                SettingsWindowController.show(tab: .general)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 20)
                    Text("Settings")
                        .font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.label)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    isHovering ? Palette.hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Settings (⌘,)")

            if let version = updater.availableUpdateVersion {
                GlassIconButton(
                    systemImage: "arrow.down",
                    help: "Download Screendrop \(version)",
                    size: 30,
                    tint: .blue
                ) {
                    updater.checkForUpdates()
                }
                .transition(.blurPop)
            }
        }
        .motion(.morphQuick, value: isHovering)
        .motion(.morph, value: updater.availableUpdateVersion)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}
