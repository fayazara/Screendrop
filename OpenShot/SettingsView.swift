//
//  SettingsView.swift
//  OpenShot
//
//  Created by Codex on 26/04/26.
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(OpenShotPreferences.autoSaveKey) private var autoSave = false
    @AppStorage(OpenShotPreferences.autoCopyKey) private var autoCopy = false
    @AppStorage(OpenShotPreferences.autoCompressKey) private var autoCompress = false
    @AppStorage(OpenShotPreferences.compressionQualityKey) private var compressionQuality = 0.8
    @AppStorage(OpenShotPreferences.exportDirectoryPathKey) private var exportDirectoryPath = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            
            Divider()
            
            Form {
                Section {
                    Toggle("Auto save screenshots", isOn: $autoSave)
                    Toggle("Auto copy to clipboard", isOn: $autoCopy)
                }
                
                Section {
                    Toggle("Auto compress screenshots", isOn: $autoCompress)
                    
                    if autoCompress {
                        LabeledContent("Quality") {
                            HStack(spacing: 12) {
                                Slider(value: $compressionQuality, in: 0.1...1, step: 0.05)
                                    .frame(width: 220)
                                
                                Text(compressionQuality, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                } footer: {
                    Text("Compressed exports are saved as JPEG using native ImageIO encoding.")
                }
                
                Section {
                    LabeledContent("Save location") {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(OpenShotPreferences.exportDirectory.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    HStack {
                        Button("Choose Folder...") {
                            chooseExportDirectory()
                        }
                        
                        Button("Use Default") {
                            exportDirectoryPath = ""
                        }
                        .disabled(exportDirectoryPath.isEmpty)
                    }
                } footer: {
                    Text("When auto save is enabled, screenshots are saved here without showing a save dialog.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(20)
        }
        .frame(width: 520)
    }
    
    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Save Location"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = OpenShotPreferences.exportDirectory
        
        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }
        
        exportDirectoryPath = url.path
    }
    
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 26))
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.title3.weight(.semibold))
                Text("Screenshot behavior")
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(20)
    }
}
