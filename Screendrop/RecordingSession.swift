//
//  RecordingSession.swift
//  Screendrop
//
//  A recording is a folder ("session") rather than a bare .mov so the studio
//  editor can keep the screen video, the separately captured camera video,
//  and the timestamped input-event sidecar together. Sessions live in
//  Application Support (not the temp dir) so a crash mid-recording never
//  hands the footage to the OS temp purger.
//

import CoreGraphics
import Foundation

nonisolated struct RecordingSession: Sendable, Equatable {
    static let directoryExtension = "screendroprec"
    static let screenFileName = "screen.mov"
    static let cameraFileName = "camera.mov"
    static let eventsFileName = "events.json"
    static let manifestFileName = "meta.json"
    static let projectFileName = "project.json"

    let directoryURL: URL

    var screenURL: URL { directoryURL.appendingPathComponent(Self.screenFileName) }
    var cameraURL: URL { directoryURL.appendingPathComponent(Self.cameraFileName) }
    /// The default flattened deliverable. The source screen/camera movies stay
    /// untouched so Studio can always re-render the project non-destructively.
    var finalURL: URL {
        let fileName = directoryURL
            .deletingPathExtension()
            .lastPathComponent
            .appending(".mov")
        return directoryURL.appendingPathComponent(fileName)
    }
    var eventsURL: URL { directoryURL.appendingPathComponent(Self.eventsFileName) }
    var manifestURL: URL { directoryURL.appendingPathComponent(Self.manifestFileName) }
    var projectURL: URL { directoryURL.appendingPathComponent(Self.projectFileName) }

    var hasCamera: Bool {
        FileManager.default.fileExists(atPath: cameraURL.path)
    }

    var hasFinalVideo: Bool {
        FileManager.default.fileExists(atPath: finalURL.path)
    }

    /// Uses an existing flattened cache when one is available; otherwise
    /// history previews the screen master so the project can appear without
    /// turning Stop into an implicit export.
    var deliverableURL: URL {
        hasFinalVideo ? finalURL : screenURL
    }

    static func isSessionDirectory(_ url: URL) -> Bool {
        url.pathExtension == directoryExtension
            && FileManager.default.fileExists(atPath: url.appendingPathComponent(screenFileName).path)
    }

    func loadManifest() -> ***REMOVED***? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? ***REMOVED***.decoder.decode(***REMOVED***.self, from: data)
    }

    func loadEvents() -> ***REMOVED***? {
        guard let data = try? Data(contentsOf: eventsURL) else { return nil }
        return try? ***REMOVED***.decoder.decode(***REMOVED***.self, from: data)
    }

    func writeManifest(_ manifest: ***REMOVED***) throws {
        let data = try ***REMOVED***.encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    func writeEvents(_ events: ***REMOVED***) throws {
        let data = try ***REMOVED***.encoder.encode(events)
        try data.write(to: eventsURL, options: .atomic)
    }

    func loadProject() -> RecordingProject? {
        guard let data = try? Data(contentsOf: projectURL) else { return nil }
        return try? ***REMOVED***.decoder.decode(RecordingProject.self, from: data)
    }

    func writeProject(_ project: RecordingProject) throws {
        let data = try ***REMOVED***.encoder.encode(project)
        try data.write(to: projectURL, options: .atomic)
    }
}

nonisolated struct ***REMOVED***: Codable, Sendable, Equatable {
    var version = 1
    var createdAt = Date()
    /// Duration of the finished screen movie, in seconds.
    var duration: TimeInterval = 0
    var pixelWidth = 0
    var pixelHeight = 0
    /// Points→pixels scale of the captured source (Retina factor).
    var pointPixelScale: Double = 1
    var displayID: UInt32?
    var hasSystemAudio = false
    var hasMicrophone = false
    /// Where the camera movie's t=0 falls on the screen movie's timeline.
    /// Positive means the camera started after the screen recording.
    var ***REMOVED***: TimeInterval?
    var cameraPixelWidth: Int?
    var cameraPixelHeight: Int?

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Sidecar of everything the user did during the recording, on the screen
/// movie's timeline. Coordinates are normalized (0...1) with a top-left
/// origin so they stay valid at any render resolution.
nonisolated struct ***REMOVED***: Codable, Sendable, Equatable {
    var version = 1
    var moves: [***REMOVED***] = []
    var clicks: [***REMOVED***] = []
}

nonisolated struct ***REMOVED***: Codable, Sendable, Equatable {
    /// Seconds on the screen movie timeline.
    var t: TimeInterval
    var x: Double
    var y: Double
}

nonisolated struct ***REMOVED***: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable {
        case down
        case up
    }

    var t: TimeInterval
    var x: Double
    var y: Double
    var button: Int
    var phase: Phase
}

nonisolated enum RecordingSessionStore {
    static var recordingsDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL
            .appendingPathComponent("Screendrop", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    static func createSession() throws -> RecordingSession {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = "Screendrop_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(6))"
        let directory = recordingsDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(RecordingSession.directoryExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RecordingSession(directoryURL: directory)
    }

    static func allSessions() -> [RecordingSession] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { RecordingSession.isSessionDirectory($0) }
            .map { RecordingSession(directoryURL: $0) }
    }

    static func deleteSession(_ session: RecordingSession) {
        try? FileManager.default.removeItem(at: session.directoryURL)
    }
}
