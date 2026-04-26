//
//  SettingsView.swift
//  OpenShot
//
//  Created by Codex on 26/04/26.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(OpenShotPreferences.autoSaveKey) private var autoSave = false
    @AppStorage(OpenShotPreferences.autoCopyKey) private var autoCopy = false
    
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
