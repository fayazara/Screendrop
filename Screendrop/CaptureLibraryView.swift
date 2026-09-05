import AppKit
import SwiftUI

struct CaptureLibraryView: View {
    @State private var model = CaptureLibraryModel.shared
    @State private var history = ScreenshotHistoryStore.shared
    @State private var projects = RecordingProjectStore.shared
    @State private var libraryWindow: NSWindow?
    @AppStorage("captureLibrary.layout") private var layout: CaptureLibraryLayout = .grid
    @AppStorage("captureLibrary.inspectorVisible") private var inspectorVisible = true
    @AppStorage("captureLibrary.sort") private var savedSort: CaptureLibrarySort = .newest

    var body: some View {
        NavigationSplitView {
            List(selection: $model.filter) {
                Section("Library") {
                    ForEach(CaptureLibraryFilter.allCases) { filter in
                        Label {
                            HStack {
                                Text(filter.title)
                                Spacer()
                                Text(model.count(for: filter), format: .number)
                                    .foregroundStyle(.secondary)
                                    .font(.caption.monospacedDigit())
                            }
                        } icon: { Image(systemName: filter.symbol) }
                        .tag(filter)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            .safeAreaInset(edge: .bottom) {
                Button {
                    SettingsWindowController.show(tab: .general)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        } detail: {
            VStack(spacing: 0) {
                browser
                Divider()
                statusBar
            }
            .navigationTitle((model.filter ?? .all).title)
            .navigationSubtitle("Screendrop")
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search captures")
        .inspector(isPresented: $inspectorVisible) {
            CaptureLibraryInspector(model: model)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .toolbar { toolbar }
        .frame(minWidth: 860, minHeight: 540)
        .onAppear {
            AppActivationPolicy.enter()
            model.sortOrder = savedSort
            model.refresh()
        }
        .onDisappear { AppActivationPolicy.leave() }
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
            ProgressView("Loading Library…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleItems.isEmpty {
            if !model.searchText.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                ContentUnavailableView {
                    Label("No \((model.filter ?? .all) == .all ? "Captures" : (model.filter ?? .all).title)", systemImage: (model.filter ?? .all).symbol)
                } description: {
                    Text("Screenshots and recordings you capture will appear here.")
                } actions: {
                    Button("Capture Area") { CaptureCoordinator.shared.captureArea() }
                    Button("Record Screen") { RecordingPickerPresenter.shared.show() }
                        .disabled(ScreenRecordingManager.shared.isActive)
                }
            }
        } else {
            CaptureLibraryCollection(items: model.visibleItems, revision: model.contentRevision, layout: layout,
                selection: $model.selection, isBusy: model.isBusy, onAction: model.perform)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let title = model.operationTitle {
                ProgressView().controlSize(.mini)
                Text(title)
            } else {
                Text("\(model.visibleItems.count) \(model.visibleItems.count == 1 ? "capture" : "captures")")
                if !model.selection.isEmpty { Text("· \(model.selection.count) selected") }
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.mini).help("Refreshing Library") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Capture Fullscreen", systemImage: "macwindow") { CaptureCoordinator.shared.captureFullscreen() }
                Button("Capture Window", systemImage: "macwindow.on.rectangle") { CaptureCoordinator.shared.captureWindow() }
                Button("Capture Area", systemImage: "rectangle.dashed") { CaptureCoordinator.shared.captureArea() }
                Divider()
                Button("Record Screen", systemImage: "record.circle") { RecordingPickerPresenter.shared.show() }
                    .disabled(ScreenRecordingManager.shared.isActive)
            } label: { Label("New Capture", systemImage: "plus") }
            .help("New capture")
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $layout) {
                Image(systemName: "square.grid.2x2").tag(CaptureLibraryLayout.grid).help("Grid view")
                Image(systemName: "list.bullet").tag(CaptureLibraryLayout.list).help("List view")
            }
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
            .help("Sort captures")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.perform(.preview) } label: { Label("Quick Look", systemImage: "eye") }
                .disabled(model.selection.count != 1 || model.isBusy)
                .help("Quick Look (Space)")
            Button { model.perform(.edit) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                .disabled(model.selection.count != 1 || model.isBusy)
                .help("Open in the screenshot or recording editor")
            Menu {
                Button("Copy", systemImage: "doc.on.doc") { model.perform(.copy) }
                Button("Export…", systemImage: "square.and.arrow.up") { model.perform(.export) }
                Button("Rename…", systemImage: "pencil") { model.perform(.rename) }
                    .disabled(model.selection.count != 1)
                Button("Reveal in Finder", systemImage: "folder") { model.perform(.reveal) }
                Divider()
                Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.perform(.trash) }
            } label: { Label("Actions", systemImage: "ellipsis.circle") }
            .disabled(model.selection.isEmpty || model.isBusy)
            .help("Capture actions")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { inspectorVisible.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide details")
        }
    }
}
