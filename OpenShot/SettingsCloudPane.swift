//
//  SettingsCloudPane.swift
//  OpenShot
//

import AppKit
import SwiftUI

struct CloudSettingsPane: View {
    @AppStorage(OpenShotPreferences.cloudWorkerURLKey) private var workerURL = ""
    @AppStorage(OpenShotPreferences.cloudUploadTokenKey) private var uploadToken = ""
    @State private var connectionStatus: CloudConnectionStatus = .unchecked

    private var isConfigured: Bool {
        !workerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !uploadToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SettingsPane {
            SettingsSection {
                SettingsRow("Status:") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)

                        Text(statusText)
                            .font(.system(size: 13))
                            .foregroundStyle(isConfigured ? .primary : .secondary)
                    }
                }
            }

            SettingsSectionDivider()

            SettingsSection {
                SettingsRow("Worker URL:") {
                    TextField("https://openshot.your-name.workers.dev", text: $workerURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: workerURL) {
                            connectionStatus = .unchecked
                        }
                }

                SettingsRow("Upload Token:") {
                    SecureField("Paste your shared token", text: $uploadToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: uploadToken) {
                            connectionStatus = .unchecked
                        }
                }

                SettingsRow("") {
                    HStack(spacing: 8) {
                        Button("Test Connection") {
                            Task { await testConnection() }
                        }
                        .disabled(!isConfigured)
                        .controlSize(.small)

                        if connectionStatus == .checking {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        }
                    }
                }
            }

            SettingsSectionDivider()

            if !isConfigured {
                SettingsSection {
                    SettingsRow("Setup:") {
                        VStack(alignment: .leading, spacing: 10) {
                            SetupStepView(number: 1, text: "Deploy the OpenShot worker to Cloudflare")
                            SetupStepView(number: 2, text: "Set the UPLOAD_TOKEN secret via wrangler secret put UPLOAD_TOKEN")
                            SetupStepView(number: 3, text: "Paste the worker URL and token above")
                        }
                    }

                    SettingsRow("") {
                        Button("View on GitHub") {
                            if let url = URL(string: "https://github.com/fayazara/openshot-worker") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .task {
            if isConfigured && connectionStatus == .unchecked {
                await testConnection()
            }
        }
    }

    private var statusColor: Color {
        switch connectionStatus {
        case .unchecked:
            isConfigured ? .orange : .gray
        case .checking:
            .orange
        case .connected:
            .green
        case .failed:
            .red
        }
    }

    private var statusText: String {
        switch connectionStatus {
        case .unchecked:
            isConfigured ? "Not verified" : "Not configured"
        case .checking:
            "Checking..."
        case .connected:
            "Connected"
        case .failed(let message):
            "Failed: \(message)"
        }
    }

    private func testConnection() async {
        connectionStatus = .checking

        let base = workerURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let token = uploadToken
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: "\(base)/api/ping") else {
            connectionStatus = .failed("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                connectionStatus = .failed("No response")
                return
            }

            switch http.statusCode {
            case 200:
                connectionStatus = .connected
            case 401, 403:
                connectionStatus = .failed("Invalid token")
            default:
                connectionStatus = .failed("HTTP \(http.statusCode)")
            }
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }
}

private enum CloudConnectionStatus: Equatable {
    case unchecked
    case checking
    case connected
    case failed(String)
}

private struct SetupStepView: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.tertiary))

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
    }
}
