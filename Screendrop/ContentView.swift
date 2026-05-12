//
//  ContentView.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("Screendrop")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Screenshot and recording tool running in the menu bar.")
                .foregroundStyle(.secondary)
            
            Divider()
                .frame(width: 200)
            
            VStack(alignment: .leading, spacing: 8) {
                ShortcutRow(label: "Fullscreen", shortcut: "Option+1")
                ShortcutRow(label: "Window", shortcut: "Option+2")
                ShortcutRow(label: "Area", shortcut: "Option+3")
                ShortcutRow(label: "Record", shortcut: "Option+4")
            }
        }
        .padding(40)
        .frame(width: 320, height: 300)
    }
}

struct ShortcutRow: View {
    let label: String
    let shortcut: String
    
    var body: some View {
        HStack {
            Text(label)
                .frame(width: 100, alignment: .leading)
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
