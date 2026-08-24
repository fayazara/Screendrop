//
//  AnnotationBackgroundPresetBar.swift
//  Screendrop
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AnnotationBackgroundPresetBar: View {
    @Bindable var model: AnnotationEditorModel
    @Bindable var presetStore: AnnotationBackgroundPresetStore
    let onEditorAction: () -> Void

    @State private var isNameEditorPresented = false
    @State private var draftName = ""
    @State private var presetPendingDeletion: AnnotationBackgroundPreset?
    @State private var transferAlert: PresetTransferAlert?
    @FocusState private var isNameFieldFocused: Bool

    private var appliedPreset: AnnotationBackgroundPreset? {
        presetStore.preset(id: model.appliedBackgroundPresetID)
    }

    private var duplicateNamePreset: AnnotationBackgroundPreset? {
        presetStore.preset(named: draftName)
    }

    private var displayTitle: String {
        appliedPreset?.name ?? "Presets…"
    }

    private var isAppliedPresetModified: Bool {
        guard let appliedPreset else { return false }
        return !appliedPreset.matches(model.backgroundSettings)
    }

    private var canUseControls: Bool {
        model.sourceURL != nil
    }

    private var canSaveName: Bool {
        !AnnotationBackgroundPresetStore.normalizedName(draftName).isEmpty
            && duplicateNamePreset == nil
            && !model.backgroundSettings.hasMissingCustomWallpaper
    }

    var body: some View {
        HStack(spacing: 7) {
            presetMenu
                .layoutPriority(1)

            if let appliedPreset {
                PresetBarIconButton(
                    systemImage: "trash",
                    accessibilityLabel: "Delete \(appliedPreset.name)",
                    help: "Delete \(appliedPreset.name)"
                ) {
                    onEditorAction()
                    presetPendingDeletion = appliedPreset
                }
                .disabled(!canUseControls)
                .transition(.opacity.combined(with: .scale(scale: 0.82)))
            }

            PresetBarIconButton(
                systemImage: "plus",
                accessibilityLabel: "Add Preset",
                help: "Save current settings as a preset"
            ) {
                onEditorAction()
                draftName = ""
                isNameEditorPresented = true
            }
            .disabled(!canUseControls)
            .popover(isPresented: $isNameEditorPresented, arrowEdge: .top) {
                nameEditor
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, InspectorMetrics.horizontalPadding)
        .padding(.vertical, 9)
        .animation(.snappy(duration: 0.18), value: appliedPreset?.id)
        .alert(
            "Delete Preset?",
            isPresented: Binding(
                get: { presetPendingDeletion != nil },
                set: { if !$0 { presetPendingDeletion = nil } }
            ),
            presenting: presetPendingDeletion
        ) { preset in
            Button("Delete", role: .destructive) {
                onEditorAction()
                presetStore.deletePreset(id: preset.id)
                if model.appliedBackgroundPresetID == preset.id {
                    model.appliedBackgroundPresetID = nil
                }
                presetPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                presetPendingDeletion = nil
            }
        } message: { preset in
            Text("“\(preset.name)” will be removed from your saved presets. The current canvas settings won’t change.")
        }
        .alert(item: $transferAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var presetMenu: some View {
        AnnotationPresetPopUpButton(
            title: displayTitle,
            presets: presetStore.presets,
            appliedPresetID: isAppliedPresetModified ? nil : model.appliedBackgroundPresetID,
            defaultPresetID: presetStore.activePreset?.id,
            isEnabled: canUseControls,
            accessibilityValue: presetAccessibilityValue,
            onSelectPreset: selectPreset,
            onSetDefaultPreset: { presetStore.setActivePreset(id: $0) },
            onDeletePreset: { presetID in
                guard let preset = presetStore.preset(id: presetID) else { return }
                onEditorAction()
                presetPendingDeletion = preset
            },
            onImportPreset: importPresets,
            onExportPreset: exportPreset
        )
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        .help(presetHelp)
    }

    private func selectPreset(_ presetID: AnnotationBackgroundPreset.ID?) {
        guard let preset = presetStore.preset(id: presetID) else {
            model.appliedBackgroundPresetID = nil
            return
        }
        onEditorAction()
        withAnimation(.snappy(duration: 0.2)) {
            model.applyBackgroundPreset(preset)
        }
    }

    private var presetHelp: String {
        if let activePreset = presetStore.activePreset {
            return "Choose a preset. \(activePreset.name) is applied to new screenshots."
        }
        return "Choose a background, layout, camera, blur, border, and watermark preset"
    }

    private var presetAccessibilityValue: String {
        var details = [displayTitle]
        if isAppliedPresetModified {
            details.append("modified")
        }
        if appliedPreset?.hasMissingWallpaper == true {
            details.append("wallpaper missing")
        }
        return details.joined(separator: ", ")
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Preset")
                    .font(.system(size: 14, weight: .semibold))

                Text("Save the current background, layout, camera, blur, border, and watermark settings. It will be used for new screenshots.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Preset name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFieldFocused)
                    .onSubmit(savePreset)
                    .onChange(of: draftName) { _, newValue in
                        let limitedName = String(
                            newValue.prefix(AnnotationBackgroundPresetStore.maximumNameLength)
                        )
                        if limitedName != newValue {
                            draftName = limitedName
                        }
                    }

                if model.backgroundSettings.hasMissingCustomWallpaper {
                    Label(
                        "The selected wallpaper can’t be found. Choose it again before saving.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                } else if duplicateNamePreset != nil {
                    Label(
                        "A preset with this name already exists.",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("Cancel") {
                    isNameEditorPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    savePreset()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSaveName)
            }
        }
        .padding(16)
        .frame(width: 292)
        .onAppear {
            Task { @MainActor in
                isNameFieldFocused = true
            }
        }
    }

    private func savePreset() {
        guard canSaveName else { return }
        onEditorAction()
        guard let preset = presetStore.savePreset(
            named: draftName,
            settings: model.backgroundSettings
        ) else {
            return
        }
        model.appliedBackgroundPresetID = preset.id
        presetStore.setActivePreset(id: preset.id)
        isNameEditorPresented = false
    }

    private func importPresets() {
        onEditorAction()

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.screendropPreset]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Import Screenshot Presets"
        panel.prompt = "Import"

        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls

            Task { @MainActor in
                var importedPresets: [AnnotationBackgroundPreset] = []
                var omittedWallpaperCount = 0
                var failures: [String] = []

                for url in urls {
                    do {
                        let transferFile = try AnnotationBackgroundPresetTransferFile.load(from: url)
                        let result = try presetStore.importTransferFile(transferFile)
                        importedPresets.append(contentsOf: result.importedPresets)
                        omittedWallpaperCount += result.omittedWallpaperCount
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }

                if let firstImportedPreset = importedPresets.first {
                    withAnimation(.snappy(duration: 0.2)) {
                        model.applyBackgroundPreset(firstImportedPreset)
                    }
                }

                transferAlert = Self.importAlert(
                    importedCount: importedPresets.count,
                    omittedWallpaperCount: omittedWallpaperCount,
                    failures: failures
                )
            }
        }
    }

    private func exportPreset(_ presetID: AnnotationBackgroundPreset.ID) {
        onEditorAction()

        do {
            let transferFile = try presetStore.transferFile(for: presetID)
            guard let preset = presetStore.preset(id: presetID) else {
                throw AnnotationBackgroundPresetTransferError.presetNotFound
            }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.screendropPreset]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = "Export Screenshot Preset"
            panel.prompt = "Export"
            panel.nameFieldStringValue = "\(Self.safeFilename(for: preset.name)).\(AnnotationBackgroundPresetTransferFile.filenameExtension)"

            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }

                Task { @MainActor in
                    do {
                        let data = try transferFile.encodedData()
                        try data.write(to: url, options: .atomic)
                        let omittedWallpaper = transferFile.presets.first?.omitted.contains(.wallpaper) == true
                        transferAlert = PresetTransferAlert(
                            title: "Preset Exported",
                            message: omittedWallpaper
                                ? "The local wallpaper was not included. The imported preset will use no background."
                                : "“\(preset.name)” is ready to share."
                        )
                    } catch {
                        transferAlert = PresetTransferAlert(
                            title: "Export Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        } catch {
            transferAlert = PresetTransferAlert(
                title: "Export Failed",
                message: error.localizedDescription
            )
        }
    }

    private static func importAlert(
        importedCount: Int,
        omittedWallpaperCount: Int,
        failures: [String]
    ) -> PresetTransferAlert {
        guard importedCount > 0 else {
            return PresetTransferAlert(
                title: "Import Failed",
                message: failures.joined(separator: "\n")
            )
        }

        let presetNoun = importedCount == 1 ? "preset" : "presets"
        var messages = ["Imported \(importedCount) \(presetNoun)."]
        if omittedWallpaperCount > 0 {
            let wallpaperNoun = omittedWallpaperCount == 1 ? "wallpaper was" : "wallpapers were"
            messages.append(
                "\(omittedWallpaperCount) local \(wallpaperNoun) not included and will use no background."
            )
        }
        if !failures.isEmpty {
            messages.append("Some files could not be imported:\n\(failures.joined(separator: "\n"))")
        }
        return PresetTransferAlert(
            title: importedCount == 1 ? "Preset Imported" : "Presets Imported",
            message: messages.joined(separator: "\n\n")
        )
    }

    private static func safeFilename(for presetName: String) -> String {
        let forbiddenCharacters = CharacterSet(charactersIn: "/:\n\r")
        let components = presetName.components(separatedBy: forbiddenCharacters)
        let sanitized = components.filter { !$0.isEmpty }.joined(separator: "-")
        return sanitized.isEmpty ? "Screenshot Preset" : sanitized
    }
}

private struct PresetTransferAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct AnnotationPresetPopUpButton: NSViewRepresentable {
    let title: String
    let presets: [AnnotationBackgroundPreset]
    let appliedPresetID: AnnotationBackgroundPreset.ID?
    let defaultPresetID: AnnotationBackgroundPreset.ID?
    let isEnabled: Bool
    let accessibilityValue: String
    let onSelectPreset: (AnnotationBackgroundPreset.ID?) -> Void
    let onSetDefaultPreset: (AnnotationBackgroundPreset.ID?) -> Void
    let onDeletePreset: (AnnotationBackgroundPreset.ID) -> Void
    let onImportPreset: () -> Void
    let onExportPreset: (AnnotationBackgroundPreset.ID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.usesItemFromMenu = false
        button.autoenablesItems = false
        button.altersStateOfSelectedItem = false
        button.preferredEdge = .minY
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.alignment = .left
        button.cell?.lineBreakMode = .byTruncatingTail
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(button)
    }

    final class Coordinator: NSObject {
        var parent: AnnotationPresetPopUpButton

        init(parent: AnnotationPresetPopUpButton) {
            self.parent = parent
        }

        func update(_ button: NSPopUpButton) {
            button.isEnabled = parent.isEnabled
            button.menu = makeMenu()
            let displayItem = NSMenuItem(
                title: parent.title,
                action: nil,
                keyEquivalent: ""
            )
            displayItem.isEnabled = parent.isEnabled
            (button.cell as? NSPopUpButtonCell)?.menuItem = displayItem
            button.setAccessibilityLabel("Background preset")
            button.setAccessibilityValue(parent.accessibilityValue)
        }

        private func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            let availablePresets = parent.presets.filter { !$0.hasMissingWallpaper }
            let missingPresets = parent.presets.filter(\.hasMissingWallpaper)

            if availablePresets.isEmpty && missingPresets.isEmpty {
                let emptyItem = NSMenuItem(title: "No Saved Presets", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                menu.addItem(emptyItem)
            }

            if !availablePresets.isEmpty {
                menu.addItem(.sectionHeader(title: "Saved Presets"))

                let currentItem = NSMenuItem(
                    title: "Current Settings",
                    action: #selector(selectCurrentSettings(_:)),
                    keyEquivalent: ""
                )
                currentItem.target = self
                currentItem.state = parent.appliedPresetID == nil ? .on : .off
                menu.addItem(currentItem)

                for preset in availablePresets {
                    let item = presetItem(
                        preset,
                        action: #selector(selectPreset(_:)),
                        isSelected: preset.id == parent.appliedPresetID
                    )
                    menu.addItem(item)
                }
            }

            if !missingPresets.isEmpty {
                if !availablePresets.isEmpty {
                    menu.addItem(.separator())
                }
                menu.addItem(.sectionHeader(title: "Wallpaper Missing"))

                for preset in missingPresets {
                    let item = presetItem(
                        preset,
                        action: #selector(deletePreset(_:)),
                        isSelected: false
                    )
                    item.title = "Delete “\(preset.name)”…"
                    item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
                    menu.addItem(item)
                }
            }

            if !availablePresets.isEmpty {
                menu.addItem(.separator())

                let defaultItem = NSMenuItem(title: "Default Preset", action: nil, keyEquivalent: "")
                defaultItem.submenu = makeDefaultMenu(presets: availablePresets)
                menu.addItem(defaultItem)
            }

            menu.addItem(.separator())

            let importItem = NSMenuItem(
                title: "Import Preset…",
                action: #selector(importPreset(_:)),
                keyEquivalent: ""
            )
            importItem.target = self
            importItem.image = NSImage(
                systemSymbolName: "square.and.arrow.down",
                accessibilityDescription: nil
            )
            menu.addItem(importItem)

            if !parent.presets.isEmpty {
                let exportItem = NSMenuItem(title: "Export Preset", action: nil, keyEquivalent: "")
                exportItem.image = NSImage(
                    systemSymbolName: "square.and.arrow.up",
                    accessibilityDescription: nil
                )
                exportItem.submenu = makeExportMenu(presets: parent.presets)
                menu.addItem(exportItem)
            }

            return menu
        }

        private func makeExportMenu(presets: [AnnotationBackgroundPreset]) -> NSMenu {
            let menu = NSMenu(title: "Export Preset")
            menu.autoenablesItems = false

            for preset in presets {
                menu.addItem(
                    presetItem(
                        preset,
                        action: #selector(exportPreset(_:)),
                        isSelected: false
                    )
                )
            }
            return menu
        }

        private func makeDefaultMenu(presets: [AnnotationBackgroundPreset]) -> NSMenu {
            let menu = NSMenu(title: "Default Preset")
            menu.autoenablesItems = false

            let noneItem = NSMenuItem(
                title: "None",
                action: #selector(clearDefaultPreset(_:)),
                keyEquivalent: ""
            )
            noneItem.target = self
            noneItem.state = parent.defaultPresetID == nil ? .on : .off
            menu.addItem(noneItem)

            for preset in presets {
                let item = presetItem(
                    preset,
                    action: #selector(setDefaultPreset(_:)),
                    isSelected: preset.id == parent.defaultPresetID
                )
                menu.addItem(item)
            }

            return menu
        }

        private func presetItem(
            _ preset: AnnotationBackgroundPreset,
            action: Selector,
            isSelected: Bool
        ) -> NSMenuItem {
            let item = NSMenuItem(title: preset.name, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id.uuidString
            item.state = isSelected ? .on : .off
            return item
        }

        private func presetID(from sender: NSMenuItem) -> AnnotationBackgroundPreset.ID? {
            guard let rawValue = sender.representedObject as? String else { return nil }
            return UUID(uuidString: rawValue)
        }

        @objc private func selectCurrentSettings(_ sender: NSMenuItem) {
            parent.onSelectPreset(nil)
        }

        @objc private func selectPreset(_ sender: NSMenuItem) {
            guard let presetID = presetID(from: sender) else { return }
            parent.onSelectPreset(presetID)
        }

        @objc private func clearDefaultPreset(_ sender: NSMenuItem) {
            parent.onSetDefaultPreset(nil)
        }

        @objc private func setDefaultPreset(_ sender: NSMenuItem) {
            guard let presetID = presetID(from: sender) else { return }
            parent.onSetDefaultPreset(presetID)
        }

        @objc private func deletePreset(_ sender: NSMenuItem) {
            guard let presetID = presetID(from: sender) else { return }
            parent.onDeletePreset(presetID)
        }

        @objc private func importPreset(_ sender: NSMenuItem) {
            parent.onImportPreset()
        }

        @objc private func exportPreset(_ sender: NSMenuItem) {
            guard let presetID = presetID(from: sender) else { return }
            parent.onExportPreset(presetID)
        }
    }
}

private struct PresetBarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(isHovering ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .onHover { isHovering = $0 }
    }
}
