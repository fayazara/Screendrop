//
//  AgentProjects.swift
//  Screendrop
//
//  Finds recordings for the agent server and hands out the model to edit
//  each one through. A project open in Studio is edited through that
//  window's model, so the user watches the change land and can undo it.
//  Otherwise a windowless model is loaded and kept warm while the agent is
//  working, then put away after it goes quiet. Opening the project in
//  Studio takes over from it.
//

import Foundation

enum AgentToolError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

@MainActor
final class AgentProjects {
    static let shared = AgentProjects()

    private static let idleLifetime: Duration = .seconds(600)

    private struct AgentModel {
        let model: RecordingStudioModel
        var lastUsed: ContinuousClock.Instant
    }

    private var agentModels: [String: AgentModel] = [:]
    private var loading: [String: Task<RecordingStudioModel, Error>] = [:]
    private var sweepTask: Task<Void, Never>?

    private init() {}

    /// The id agents use for a recording: its package folder's name.
    nonisolated static func id(for session: RecordingSession) -> String {
        session.directoryURL.deletingPathExtension().lastPathComponent
    }

    /// Accepts the id from `list_recordings`, the package folder name with
    /// its extension, or an absolute path to the package.
    func session(for recording: String) throws -> RecordingSession {
        let trimmed = recording.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentToolError.message("Pass a recording id from list_recordings.")
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            guard RecordingSession.isSessionDirectory(url) else {
                throw AgentToolError.message("\(trimmed) is not a Screendrop recording package.")
            }
            return RecordingSession(directoryURL: url)
        }
        let name = trimmed.hasSuffix(".\(RecordingSession.directoryExtension)")
            ? String(trimmed.dropLast(RecordingSession.directoryExtension.count + 1))
            : trimmed
        let url = RecordingSessionStore.recordingsDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(RecordingSession.directoryExtension)
        guard RecordingSession.isSessionDirectory(url) else {
            throw AgentToolError.message("No recording with id \"\(trimmed)\". Call list_recordings for valid ids.")
        }
        return RecordingSession(directoryURL: url)
    }

    /// The loaded model to read and edit `recording` through.
    func model(for recording: String) async throws -> RecordingStudioModel {
        let session = try session(for: recording)
        let key = session.directoryURL.standardizedFileURL.path

        if let editor = StudioProjectRegistry.shared.editorModel(for: session.directoryURL) {
            return editor
        }
        if var entry = agentModels[key] {
            entry.lastUsed = .now
            agentModels[key] = entry
            return entry.model
        }
        if let pending = loading[key] {
            return try await pending.value
        }

        let task = Task<RecordingStudioModel, Error> {
            let model = RecordingStudioModel(url: session.directoryURL)
            model.isAgentSession = true
            await model.load()
            guard model.isLoaded else {
                let reason = model.loadError ?? "The recording could not be opened."
                model.teardown()
                throw AgentToolError.message(reason)
            }
            return model
        }
        loading[key] = task
        defer { loading.removeValue(forKey: key) }
        let model = try await task.value
        agentModels[key] = AgentModel(model: model, lastUsed: .now)
        scheduleSweep()
        return model
    }

    /// Persists and closes the windowless model for a project, if there is
    /// one. Called when a Studio window opens the project.
    func releaseAgentModel(for url: URL) {
        let key = url.standardizedFileURL.path
        guard let entry = agentModels.removeValue(forKey: key) else { return }
        entry.model.flushDraft()
        entry.model.teardown()
    }

    private func scheduleSweep() {
        guard sweepTask == nil else { return }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.sweep()
                if self.agentModels.isEmpty {
                    self.sweepTask = nil
                    return
                }
            }
        }
    }

    private func sweep() {
        let now = ContinuousClock.now
        for (key, entry) in agentModels {
            let model = entry.model
            let busy = model.exportState.isExporting || model.audioExportState.isExporting
                || model.transcriptionState.isTranscribing
            guard !busy, now - entry.lastUsed > Self.idleLifetime else { continue }
            agentModels.removeValue(forKey: key)
            model.flushDraft()
            model.teardown()
        }
    }
}
