//
//  SettingsMCPPane.swift
//  Screendrop
//
//  Settings → MCP: the switch for the local MCP server that lets agents read,
//  edit and export recordings, and the setup for the clients people use most:
//  pick a client, copy one command or config.
//

import AppKit
import SwiftUI

struct MCPSettingsPane: View {
    @AppStorage(ScreendropPreferences.agentServerEnabledKey) private var agentServerEnabled = true
    @State private var client: Client = .claudeCode

    private enum Client: CaseIterable, Hashable {
        case claudeCode
        case codex
        case json

        var title: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .json: "JSON"
            }
        }

        var hint: String {
            switch self {
            case .claudeCode, .codex:
                "Run this once in Terminal. The agent starts Screendrop in the background when it needs it."
            case .json:
                "Add this to your MCP client's config. It starts Screendrop in the background when it needs it."
            }
        }
    }

    /// The relay is this very binary run with `--mcp`, so the setup is right
    /// for whichever copy of the app (release or Dev) is showing it.
    private var executablePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/Screendrop.app/Contents/MacOS/Screendrop"
    }

    private func setup(for client: Client) -> String {
        let quoted = "'\(executablePath.replacingOccurrences(of: "'", with: "'\\''"))'"
        switch client {
        case .claudeCode:
            return "claude mcp add screendrop -- \(quoted) \(AgentSocket.relayArgument)"
        case .codex:
            return "codex mcp add screendrop -- \(quoted) \(AgentSocket.relayArgument)"
        case .json:
            let config: [String: Any] = [
                "mcpServers": [
                    "screendrop": [
                        "command": executablePath,
                        "args": [AgentSocket.relayArgument],
                    ],
                ],
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    var body: some View {
        SettingsPage {
            Section {
                Toggle(isOn: $agentServerEnabled) {
                    SettingsControlLabel(
                        "Enable MCP server",
                        detail: "Let Claude Code, Codex, and other MCP clients read, edit, and export your recordings. Everything stays on this Mac."
                    )
                }
                .onChange(of: agentServerEnabled) { _, _ in
                    AgentServer.shared.updateForPreference()
                }
            }

            if agentServerEnabled {
                Section {
                    VStack(alignment: .leading, spacing: Space.l) {
                        SettingsSegmented(
                            options: Client.allCases,
                            selection: $client,
                            title: \.title
                        )

                        SettingsCodeBlock(text: setup(for: client))

                        Text(client.hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                    .padding(.vertical, Space.xs)
                } header: {
                    Text("Connect a Client")
                }
                .transition(.blurPop)
            }
        }
        .motion(value: agentServerEnabled)
        .motion(.morphQuick, value: client)
    }
}

/// Text to paste somewhere else: monospaced and wrapped in full on a quiet
/// field, selectable, with a copy button in its corner that confirms with a
/// checkmark.
struct SettingsCodeBlock: View {
    let text: String

    @State private var didCopy = false
    @State private var copyTask: Task<Void, Never>?

    private let radius = Radius.field

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Palette.label)
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Space.l)
            .padding(.leading, Space.l)
            // Room for the copy button, so text never runs under it.
            .padding(.trailing, 40)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: copy) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(didCopy ? Palette.success : Palette.secondaryLabel)
                .padding(Space.s)
                .help(didCopy ? "Copied" : "Copy")
                .accessibilityLabel(didCopy ? "Copied" : "Copy")
            }
            .onChange(of: text) { _, _ in
                copyTask?.cancel()
                didCopy = false
            }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        copyTask?.cancel()
        copyTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}
