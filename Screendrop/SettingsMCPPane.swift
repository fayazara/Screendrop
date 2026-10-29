//
//  SettingsMCPPane.swift
//  Screendrop
//
//  Settings → MCP: the switch for the local MCP server that lets AI agents
//  edit recordings, and the one-line setup for the agents people use most.
//

import AppKit
import SwiftUI

struct MCPSettingsPane: View {
    @AppStorage(ScreendropPreferences.agentServerEnabledKey) private var agentServerEnabled = true
    @State private var copiedSetup: Setup?

    private enum Setup: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case codex = "Codex"
        case json = "Other MCP clients"

        var id: Self { self }
    }

    /// The relay is this very binary run with `--mcp`, so the command is
    /// right for whichever copy of the app (release or Dev) is showing it.
    private var executablePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/Screendrop.app/Contents/MacOS/Screendrop"
    }

    private func command(for setup: Setup) -> String {
        let quoted = "'\(executablePath.replacingOccurrences(of: "'", with: "'\\''"))'"
        switch setup {
        case .claudeCode:
            return "claude mcp add screendrop -- \(quoted) \(AgentSocket.relayArgument)"
        case .codex:
            return "codex mcp add screendrop -- \(quoted) \(AgentSocket.relayArgument)"
        case .json:
            let config: JSONValue = [
                "mcpServers": [
                    "screendrop": [
                        "command": .string(executablePath),
                        "args": [.string(AgentSocket.relayArgument)],
                    ],
                ],
            ]
            return config.compactString
        }
    }

    var body: some View {
        SettingsPage {
            Section("AI Agents") {
                Toggle(isOn: $agentServerEnabled) {
                    SettingsControlLabel(
                        "Allow AI agents",
                        detail: "Let Claude Code, Codex, and other MCP clients read, edit, and export your recordings. Everything stays on this Mac."
                    )
                }
                .onChange(of: agentServerEnabled) { _, _ in
                    AgentServer.shared.updateForPreference()
                }
            }

            if agentServerEnabled {
                Section {
                    ForEach(Setup.allCases) { setup in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(setup.rawValue)
                                Text(command(for: setup))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            SettingsButton(
                                copiedSetup == setup ? "Copied" : "Copy",
                                systemImage: copiedSetup == setup ? "checkmark" : "doc.on.doc"
                            ) {
                                copy(setup)
                            }
                        }
                    }
                } header: {
                    Text("Connect an Agent")
                } footer: {
                    Text("Run the command in a terminal once. The agent starts Screendrop in the background when it needs it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.blurPop)
            }
        }
        .motion(value: agentServerEnabled)
    }

    private func copy(_ setup: Setup) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command(for: setup), forType: .string)
        copiedSetup = setup
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedSetup == setup { copiedSetup = nil }
        }
    }
}
