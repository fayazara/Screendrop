//
//  SettingsMorePanes.swift
//  Screendrop
//
//  Settings → Annotate and Library.
//

import AppKit
import SwiftUI

// MARK: - Annotate

struct AnnotateSettingsPane: View {
    @AppStorage(ScreendropPreferences.lowResolutionEditorPreviewKey) private var lowResolutionEditorPreview = true
    @AppStorage(ScreendropPreferences.annotationStartingToolKey) private var startingTool = AnnotationTool.select.rawValue

    var body: some View {
        SettingsPage {
            Section("Editor") {
                Picker(selection: $startingTool) {
                    Text("Last Used").tag(ScreendropPreferences.startingToolLastUsed)
                    Divider()
                    ForEach(AnnotationTool.allCases) { tool in
                        Text(tool.title).tag(tool.rawValue)
                    }
                } label: {
                    SettingsControlLabel(
                        "Starting tool",
                        detail: "The tool picked when the editor opens."
                    )
                }
            }

            Section("Performance") {
                Toggle(isOn: $lowResolutionEditorPreview) {
                    SettingsControlLabel(
                        "Use low-resolution preview to save memory",
                        detail: "Shows a downscaled image while editing to reduce memory use. Saved and exported screenshots are always full resolution."
                    )
                }
                .toggleStyle(.ink)
            }
        }
    }
}

// MARK: - Library

struct LibrarySettingsPane: View {
    @AppStorage(ScreendropPreferences.libraryAnalyzeCapturesKey) private var analyzeCaptures = true
    @AppStorage(ScreendropPreferences.librarySortExistingKey) private var sortExistingCaptures = false

    var body: some View {
        SettingsPage {
            Section("Smart Library") {
                Toggle(isOn: $analyzeCaptures) {
                    SettingsControlLabel(
                        "Analyze captures",
                        detail: "Read the text in screenshots and recordings so search can find it, and sort new captures into categories. Everything runs on this Mac."
                    )
                }
                .toggleStyle(.ink)

                if analyzeCaptures, CaptureLibraryAnalyzer.isModelAvailable {
                    Toggle(isOn: $sortExistingCaptures) {
                        SettingsControlLabel(
                            "Sort existing captures",
                            detail: "Use Apple Intelligence on captures taken before sorting was turned on. It works in the background and can take an hour or more for a large Library."
                        )
                    }
                    .toggleStyle(.ink)
                    .transition(.blurPop)
                }
            }
            .motion(value: analyzeCaptures)
            .onChange(of: analyzeCaptures) { _, _ in CaptureLibraryIndex.shared.settingsDidChange() }
            .onChange(of: sortExistingCaptures) { _, _ in CaptureLibraryIndex.shared.settingsDidChange() }

            Section {
                SettingsRow {
                    SettingsButton("Open Library", systemImage: "square.grid.2x2") {
                        CaptureLibraryModel.shared.show(filter: .all)
                    }
                } label: {
                    SettingsControlLabel(
                        "Your captures",
                        detail: "Every screenshot and recording, searchable by the text inside it."
                    )
                }
            }
        }
    }
}
