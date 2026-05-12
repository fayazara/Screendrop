//
//  SettingsCloudPane.swift
//  Screendrop
//
//  Cloud settings: R2/S3 credentials + Worker URL configuration.
//

import AppKit
import SwiftUI

struct CloudSettingsPane: View {
    @State private var store = CloudCredentialStore.shared

    // Local form state (committed on save)
    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var bucket = ""
    @State private var region = ""
    @State private var endpoint = ""
    @State private var publicURLBase = ""
    @State private var workerURL = ""
    @State private var uploadToken = ""

    @State private var r2Status: ConnectionStatus = .unchecked
    @State private var workerStatus: ConnectionStatus = .unchecked
    @State private var hasUnsavedChanges = false
    @State private var isLoading = true

    private var isR2Configured: Bool {
        !accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isWorkerConfigured: Bool {
        !workerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !uploadToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SettingsPane {
            // MARK: - Status

            SettingsSection {
                SettingsRow("Status:") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(overallStatusColor)
                            .frame(width: 8, height: 8)

                        Text(overallStatusText)
                            .font(.system(size: 13))
                            .foregroundStyle(isR2Configured && isWorkerConfigured ? .primary : .secondary)
                    }
                }
            }

            SettingsSectionDivider()

            // MARK: - R2 / S3 Credentials

            SettingsSection {
                SettingsRow("R2 Endpoint:") {
                    TextField("https://<account_id>.r2.cloudflarestorage.com", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: endpoint) { markChanged() }
                }

                SettingsRow("Bucket:") {
                    TextField("my-screenshots", text: $bucket)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: bucket) { markChanged() }
                }

                SettingsRow("Region:") {
                    TextField("auto", text: $region)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: region) { markChanged() }
                }

                SettingsRow("Access Key ID:") {
                    SecureField("R2 access key ID", text: $accessKeyId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: accessKeyId) { markChanged() }
                }

                SettingsRow("Secret Key:") {
                    SecureField("R2 secret access key", text: $secretAccessKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: secretAccessKey) { markChanged() }
                }

                SettingsRow("Public URL:") {
                    TextField("https://cdn.example.com (optional)", text: $publicURLBase)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: publicURLBase) { markChanged() }
                }

                SettingsRow("") {
                    HStack(spacing: 8) {
                        Button("Test R2 Connection") {
                            Task { await testR2Connection() }
                        }
                        .disabled(!isR2Configured)
                        .controlSize(.small)

                        connectionStatusIndicator(r2Status)
                    }
                }
            }

            SettingsSectionDivider()

            // MARK: - Worker Configuration

            SettingsSection {
                SettingsRow("Worker URL:") {
                    TextField("https://screendrop.your-name.workers.dev", text: $workerURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: workerURL) { markChanged() }
                }

                SettingsRow("Upload Token:") {
                    SecureField("Paste your shared token", text: $uploadToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onChange(of: uploadToken) { markChanged() }
                }

                SettingsRow("") {
                    HStack(spacing: 8) {
                        Button("Test Worker") {
                            Task { await testWorkerConnection() }
                        }
                        .disabled(!isWorkerConfigured)
                        .controlSize(.small)

                        connectionStatusIndicator(workerStatus)
                    }
                }
            }

            SettingsSectionDivider()

            // MARK: - Save

            SettingsSection {
                SettingsRow("") {
                    HStack(spacing: 12) {
                        Button("Save") {
                            saveSettings()
                        }
                        .controlSize(.small)
                        .disabled(!hasUnsavedChanges)

                        if hasUnsavedChanges {
                            Text("Unsaved changes")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            // MARK: - Setup Guide

            if !isR2Configured || !isWorkerConfigured {
                SettingsSectionDivider()

                SettingsSection {
                    SettingsRow("Setup:") {
                        VStack(alignment: .leading, spacing: 10) {
                            SetupStepView(number: 1, text: "Create an R2 bucket in Cloudflare dashboard")
                            SetupStepView(number: 2, text: "Generate an R2 API token (S3 Auth) with read/write permissions")
                            SetupStepView(number: 3, text: "Deploy the Screendrop worker to Cloudflare Workers")
                            SetupStepView(number: 4, text: "Set UPLOAD_TOKEN secret: wrangler secret put UPLOAD_TOKEN")
                            SetupStepView(number: 5, text: "Paste all credentials above and save")
                        }
                    }

                    SettingsRow("") {
                        Button("View on GitHub") {
                            if let url = URL(string: "https://github.com/fayazara/screendrop-worker") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .onAppear {
            loadFromStore()
        }
        .task {
            if isR2Configured {
                await testR2Connection()
            }
            if isWorkerConfigured {
                await testWorkerConnection()
            }
        }
    }

    // MARK: - Helpers

    private func loadFromStore() {
        isLoading = true
        accessKeyId = store.accessKeyId
        secretAccessKey = store.secretAccessKey
        bucket = store.bucket
        region = store.region
        endpoint = store.endpoint
        publicURLBase = store.publicURLBase
        workerURL = store.workerURL
        uploadToken = store.uploadToken
        hasUnsavedChanges = false
        // Delay clearing the flag so onChange handlers triggered by
        // the assignments above are suppressed.
        DispatchQueue.main.async {
            isLoading = false
        }
    }

    private func markChanged() {
        guard !isLoading else { return }
        r2Status = .unchecked
        workerStatus = .unchecked
        hasUnsavedChanges = true
    }

    private func saveSettings() {
        store.accessKeyId = accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        store.secretAccessKey = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        store.bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        store.region = region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "auto" : region.trimmingCharacters(in: .whitespacesAndNewlines)
        store.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        store.publicURLBase = publicURLBase.trimmingCharacters(in: .whitespacesAndNewlines)
        store.workerURL = workerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        store.uploadToken = uploadToken.trimmingCharacters(in: .whitespacesAndNewlines)
        hasUnsavedChanges = false
    }

    // MARK: - Connection Tests

    private func testR2Connection() async {
        // Temporarily save so S3CloudService can use the credentials
        saveSettings()
        r2Status = .checking

        do {
            try await S3CloudService.shared.testConnection()
            r2Status = .connected
        } catch {
            r2Status = .failed(error.localizedDescription)
        }
    }

    private func testWorkerConnection() async {
        saveSettings()
        workerStatus = .checking

        let raw = workerURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = raw.lowercased().hasPrefix("http") ? raw : "https://\(raw)"
        let token = uploadToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: "\(base)/api/ping") else {
            workerStatus = .failed("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                workerStatus = .failed("No response")
                return
            }

            switch http.statusCode {
            case 200:
                workerStatus = .connected
            case 401, 403:
                workerStatus = .failed("Invalid token")
            default:
                workerStatus = .failed("HTTP \(http.statusCode)")
            }
        } catch {
            workerStatus = .failed(error.localizedDescription)
        }
    }

    // MARK: - Status Display

    private var overallStatusColor: Color {
        if isR2Configured && isWorkerConfigured {
            if r2Status == .connected && workerStatus == .connected {
                return .green
            }
            return .orange
        }
        return .gray
    }

    private var overallStatusText: String {
        if !isR2Configured && !isWorkerConfigured {
            return "Not configured"
        }
        if !isR2Configured {
            return "R2 credentials missing"
        }
        if !isWorkerConfigured {
            return "Worker not configured"
        }
        if r2Status == .connected && workerStatus == .connected {
            return "Connected"
        }
        return "Not verified"
    }

    @ViewBuilder
    private func connectionStatusIndicator(_ status: ConnectionStatus) -> some View {
        switch status {
        case .unchecked:
            EmptyView()
        case .checking:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 13))
        case .failed(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 13))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }
}

private enum ConnectionStatus: Equatable {
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
