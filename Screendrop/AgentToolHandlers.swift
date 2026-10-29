//
//  AgentToolHandlers.swift
//  Screendrop
//
//  What each agent tool does. Reads come straight off the loaded Studio
//  model. Edits either call the model's own operations (cuts, transcript
//  edits, media import) or transform its edit document as JSON and apply
//  the result with `applyAgentDocument`, which makes the change a single
//  undo step. Every edit is flushed to the draft before the tool returns.
//

import AppKit
import AVFoundation
import Foundation

/// The kinds of timed item an agent can add, change, or remove, and where
/// each lives in the edit document.
enum AgentItemKind: String, CaseIterable {
    case zoom
    case text
    case redaction
    case cameraLayout = "camera_layout"
    case caption
    case image
    case audio

    var documentKey: String {
        switch self {
        case .zoom: "zoomCues"
        case .text: "textOverlays"
        case .redaction: "redactions"
        case .cameraLayout: "cameraLayoutCues"
        case .caption: "subtitleCues"
        case .image: "imageOverlays"
        case .audio: "audioClips"
        }
    }

    /// Added audio is placed on the edited movie; everything else rides
    /// on the footage it was put over.
    var isOnEditedClock: Bool { self == .audio }

    var title: String {
        switch self {
        case .zoom: "Zoom"
        case .text: "Text"
        case .redaction: "Redaction"
        case .cameraLayout: "Layout"
        case .caption: "Caption"
        case .image: "Image"
        case .audio: "Audio"
        }
    }

    /// Decodes one item through its real model type and re-encodes it, so
    /// defaults are filled in and bad fields are caught before they reach
    /// the document.
    func normalized(_ item: JSONValue) throws -> JSONValue {
        switch self {
        case .zoom: try JSONValue(encoding: item.decode(as: ZoomCue.self))
        case .text: try JSONValue(encoding: item.decode(as: RecordingTextOverlay.self))
        case .redaction: try JSONValue(encoding: item.decode(as: RecordingRedaction.self))
        case .cameraLayout: try JSONValue(encoding: item.decode(as: RecordingCameraLayoutCue.self))
        case .caption: try JSONValue(encoding: item.decode(as: RecordingSubtitleCue.self))
        case .image: try JSONValue(encoding: item.decode(as: RecordingImageOverlay.self))
        case .audio: try JSONValue(encoding: item.decode(as: RecordingAudioClip.self))
        }
    }
}

extension AgentTools {
    // MARK: - Reading

    static func listRecordings(_ arguments: AgentArguments) throws -> [JSONValue] {
        let query = arguments.optionalString("query")?.lowercased()
        let limit = max(1, arguments.raw["limit"]?.intValue ?? 20)

        struct Row {
            let session: RecordingSession
            let name: String
            let manifest: CaptureManifest?
            let metadata: RecordingProjectMetadata?
            var lastActivity: Date { metadata?.lastOpenedAt ?? manifest?.createdAt ?? .distantPast }
        }

        let rows = RecordingSessionStore.allSessions()
            .map { Row(session: $0, name: $0.displayName, manifest: $0.loadCaptureManifest(), metadata: $0.loadProjectMetadata()) }
            .filter { row in query.map { row.name.lowercased().contains($0) } ?? true }
            .sorted { $0.lastActivity > $1.lastActivity }

        let formatter = ISO8601DateFormatter()
        let listed: [JSONValue] = rows.prefix(limit).map { row in
            var entry: [String: JSONValue] = [
                "id": .string(AgentProjects.id(for: row.session)),
                "name": .string(row.name),
                "path": .string(row.session.directoryURL.path),
                "hasCamera": .bool(row.session.hasCamera),
                "isOpenInStudio": .bool(StudioProjectRegistry.shared.editorModel(for: row.session.directoryURL) != nil),
                "isSaved": .bool(row.session.hasSavedProject),
                "hasUnsavedDraft": .bool(row.session.hasUnsavedDraft),
            ]
            if let manifest = row.manifest {
                entry["createdAt"] = .string(formatter.string(from: manifest.createdAt))
                entry["durationSeconds"] = seconds(manifest.duration)
                entry["width"] = .number(Double(manifest.pixelWidth))
                entry["height"] = .number(Double(manifest.pixelHeight))
                entry["hasMicrophone"] = .bool(manifest.includesMicrophone)
                entry["hasSystemAudio"] = .bool(manifest.includesSystemAudio)
            }
            return .object(entry)
        }
        return [json(["total": .number(Double(rows.count)), "recordings": .array(listed)])]
    }

    static func getRecording(_ arguments: AgentArguments) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        return [json(try recordingSummary(model))]
    }

    static func recordingSummary(_ model: RecordingStudioModel) throws -> JSONValue {
        var document = try JSONValue(encoding: model.editDocument)
        // Transcripts run to thousands of words; get_transcript serves them.
        document = document.merging(["subtitleWords": .null, "subtitleCues": .null])

        let timeline = model.clipTimeline
        let clips: [JSONValue] = timeline.segments.enumerated().map { index, segment in
            let edited = timeline.editorRange(for: segment.id)
            return [
                "index": .number(Double(index)),
                "id": .string(segment.id.uuidString),
                "sourceStart": seconds(segment.sourceStart),
                "sourceEnd": seconds(segment.sourceEnd),
                "speed": .number(segment.speed),
                "editedStart": edited.map { seconds($0.lowerBound) } ?? .null,
                "editedEnd": edited.map { seconds($0.upperBound) } ?? .null,
            ]
        }

        let fullDocument = try JSONValue(encoding: model.editDocument)
        var items: [JSONValue] = []
        for kind in AgentItemKind.allCases where kind != .caption {
            for item in fullDocument[kind.documentKey]?.arrayValue ?? [] {
                items.append(timelineEntry(item, kind: kind, model: model))
            }
        }

        return [
            "id": .string(model.session.map(AgentProjects.id(for:)) ?? model.sessionURL.lastPathComponent),
            "name": .string(model.projectDisplayName),
            "path": .string(model.sessionURL.path),
            "isOpenInStudio": .bool(!model.isAgentSession),
            "hasUnsavedChanges": .bool(model.hasUnsavedChanges),
            "canUndo": .bool(model.canUndo),
            "canRedo": .bool(model.canRedo),
            "source": [
                "duration": seconds(model.sourceDuration),
                "width": .number(Double(model.videoSize.width)),
                "height": .number(Double(model.videoSize.height)),
                "hasCamera": .bool(model.hasCameraVideo),
                "hasAudio": .bool(model.hasRecordedAudio),
                "clicks": .number(Double(model.pointerCapture.presses.count { $0.phase == .down })),
                "keystrokes": .number(Double(model.pointerCapture.keystrokes.count)),
            ],
            "edited": ["duration": seconds(model.duration)],
            "transcript": [
                "words": .number(Double(model.transcriptWords.count)),
                "captions": .number(Double(model.subtitleCues.count)),
            ],
            "clips": .array(clips),
            "items": .array(items),
            "document": document,
        ]
    }

    /// One item as the timeline shows it: id, a short label, and its range
    /// on both clocks (edited is null when the footage under it is cut).
    private static func timelineEntry(_ item: JSONValue, kind: AgentItemKind, model: RecordingStudioModel) -> JSONValue {
        var entry: [String: JSONValue] = ["kind": .string(kind.rawValue), "id": item["id"] ?? .null]
        let label: JSONValue? = switch kind {
        case .zoom: item["zoom"].flatMap(\.doubleValue).map { .string("\($0)x") }
        case .text, .caption: item["text"]
        case .redaction: item["style"]
        case .cameraLayout: item["layout"]?["kind"]
        case .image, .audio: item["displayName"]
        }
        entry["label"] = label ?? .null

        if kind.isOnEditedClock {
            let start = item["start"]?.doubleValue ?? 0
            let length = (item["trimEnd"]?.doubleValue ?? 0) - (item["trimStart"]?.doubleValue ?? 0)
            entry["editedStart"] = seconds(start)
            entry["editedEnd"] = seconds(start + max(0, length))
        } else {
            let start = item["start"]?.doubleValue ?? 0
            let end = item["end"]?.doubleValue ?? start
            entry["sourceStart"] = seconds(start)
            entry["sourceEnd"] = seconds(end)
            let slices = model.clipTimeline.slices(overlapping: start, sourceEnd: end)
            entry["editedStart"] = slices.first.map { seconds($0.editorStart) } ?? .null
            entry["editedEnd"] = slices.last.map { seconds($0.editorEnd) } ?? .null
        }
        return .object(entry)
    }

    static func getTranscript(_ arguments: AgentArguments, progress: @escaping AgentProgress) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        if model.transcriptWords.isEmpty, arguments.bool("transcribe_if_missing", default: false) {
            guard model.hasRecordedAudio else {
                throw AgentToolError.message("This recording has no audio to transcribe.")
            }
            if !model.transcriptionState.isTranscribing {
                model.transcribe()
            }
            var waited = 0.0
            while model.transcriptionState.isTranscribing {
                progress(min(0.95, waited / 120), "Transcribing on device…")
                try await Task.sleep(for: .milliseconds(500))
                waited += 0.5
            }
            if case .failed(let message) = model.transcriptionState {
                throw AgentToolError.message("Transcription failed: \(message)")
            }
            model.flushDraft()
        }

        let words = model.transcriptWords
        let includeCut = arguments.bool("include_cut_words", default: true)
        let timeline = model.clipTimeline
        guard !words.isEmpty || !model.subtitleCues.isEmpty else {
            throw AgentToolError.message("This recording has no transcript. Call get_transcript again with transcribe_if_missing: true.")
        }

        var lines: [String] = []
        var cutCount = 0
        for (index, word) in words.enumerated() {
            let edited = timeline.editorTime(forSourceTime: word.midpoint).flatMap { _ in
                timeline.editorTime(forSourceTime: word.start) ?? timeline.editorTime(forSourceTime: word.midpoint)
            }
            if edited == nil { cutCount += 1 }
            guard includeCut || edited != nil else { continue }
            let flags = TranscriptEditPlanner.isFiller(word) ? "F" : ""
            lines.append("\(index) | \(format(word.start))-\(format(word.end)) | \(edited.map(format) ?? "-") | \(flags) | \(word.displayText)")
        }

        var output = """
        Transcript of \(model.projectDisplayName): \(words.count) words, \(cutCount) cut from the edit.
        Columns: index | source start-end (s) | edited start (s, "-" = cut) | flags (F = filler) | word

        """
        output += lines.joined(separator: "\n")
        if words.isEmpty {
            output += "(Only captions are stored; transcribe again for word timing.)"
        }
        if !model.subtitleCues.isEmpty {
            output += "\n\nCaptions (kind \"caption\"): id | source start-end | edited start | text\n"
            output += model.subtitleCues.map { cue in
                let edited = timeline.editorTime(forSourceTime: cue.start).map(format) ?? "-"
                return "\(cue.id.uuidString) | \(format(cue.start))-\(format(cue.end)) | \(edited) | \(cue.text)"
            }.joined(separator: "\n")
        }
        return [text(output)]
    }

    static func getInputEvents(_ arguments: AgentArguments) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        let clock = try arguments.clock()
        let timeline = model.clipTimeline
        let windowStart = arguments.optionalDouble("start") ?? 0
        let windowEnd = arguments.optionalDouble("end") ?? (clock == .source ? model.sourceDuration : model.duration)

        func times(_ sourceTime: TimeInterval) -> (source: JSONValue, edited: JSONValue)? {
            let edited = timeline.editorTime(forSourceTime: sourceTime)
            let onClock = clock == .source ? sourceTime : edited
            guard let onClock, onClock >= windowStart, onClock <= windowEnd else { return nil }
            return (seconds(sourceTime), edited.map(seconds) ?? .null)
        }

        let capture = model.pointerCapture
        let clicks: [JSONValue] = capture.presses.filter { $0.phase == .down }.compactMap { press in
            guard let t = times(press.time) else { return nil }
            return [
                "sourceTime": t.source, "editedTime": t.edited,
                "x": rounded(press.x), "y": rounded(press.y),
                "button": .string(press.button == 0 ? "left" : press.button == 1 ? "right" : "other"),
            ]
        }
        let keystrokes: [JSONValue] = capture.keystrokes.compactMap { event in
            guard let t = times(event.time) else { return nil }
            return ["sourceTime": t.source, "editedTime": t.edited, "keys": .string(event.modifiers.joined() + event.key)]
        }

        var result: [String: JSONValue] = [
            "note": "x/y are normalized 0...1 with a top-left origin, in the recorded picture.",
            "clicks": .array(clicks),
            "keystrokes": .array(keystrokes),
        ]
        if arguments.bool("include_cursor", default: false) {
            let interval = 1 / max(0.1, min(arguments.optionalDouble("cursor_hz") ?? 4, 30))
            var next = -Double.infinity
            var cursor: [JSONValue] = []
            for sample in capture.travel where sample.time >= next {
                guard let t = times(sample.time) else { continue }
                next = sample.time + interval
                cursor.append([
                    "sourceTime": t.source, "editedTime": t.edited,
                    "x": rounded(sample.x), "y": rounded(sample.y),
                    "dragging": .bool(sample.kind == .drag),
                ])
            }
            result["cursor"] = .array(cursor)
        }
        return [json(.object(result))]
    }

    static func getFrame(_ arguments: AgentArguments) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        let clock = try arguments.clock()
        let time = try arguments.double("time")
        let sourceTime = min(max(try toSource(time, clock: clock, model: model), 0), max(0, model.sourceDuration - 0.01))
        let maxSize = min(max(arguments.raw["max_size"]?.intValue ?? 1280, 160), 3840)

        let (data, size) = try await frameJPEG(url: model.screenURL, seconds: sourceTime, maxSize: maxSize)
        let edited = model.clipTimeline.editorTime(forSourceTime: sourceTime)
        let caption = "Raw screen at source \(format(sourceTime))s (edited \(edited.map { format($0) + "s" } ?? "cut")), \(Int(size.width))×\(Int(size.height)) px."
        return [image(data, mimeType: "image/jpeg"), text(caption)]
    }

    private static func frameJPEG(url: URL, seconds: TimeInterval, maxSize: Int) async throws -> (Data, CGSize) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        let tolerance = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let (cgImage, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw AgentToolError.message("The frame could not be encoded.")
        }
        return (data, CGSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - Cutting

    static func cut(_ arguments: AgentArguments) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        let clock = try arguments.clock()
        let ranges = try arguments.array("ranges").map { range -> ClosedRange<TimeInterval> in
            guard let start = range["start"]?.doubleValue, let end = range["end"]?.doubleValue, end > start else {
                throw AgentToolError.message("Each range needs a start and a larger end.")
            }
            let sourceStart = try toSource(start, clock: clock, model: model)
            let sourceEnd = try toSource(end, clock: clock, model: model)
            return min(sourceStart, sourceEnd)...max(sourceStart, sourceEnd)
        }
        let before = model.duration
        model.performAgentEdit { model.cutSourceRanges(ranges, actionName: "Cut") }
        guard model.duration != before else {
            throw AgentToolError.message("Nothing changed: those ranges are already cut, too short, or would remove the whole video.")
        }
        model.flushDraft()
        return [json(editResult(model, removedSeconds: before - model.duration))]
    }

    static func setSpeed(_ arguments: AgentArguments) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        let clock = try arguments.clock()
        let speed = min(max(try arguments.double("speed"), RecordingClipSegment.minimumSpeed), RecordingClipSegment.maximumSpeed)
        let a = try toSource(try arguments.double("start"), clock: clock, model: model)
        let b = try toSource(try arguments.double("end"), clock: clock, model: model)
        let lower = min(a, b), upper = max(a, b)
        let minimum = RecordingClipSegment.minimumDuration

        var segments: [RecordingClipSegment] = []
        for segment in model.clipTimeline.segments {
            var start = max(segment.sourceStart, lower)
            var end = min(segment.sourceEnd, upper)
            guard end - start > 0.001 else {
                segments.append(segment)
                continue
            }
            // Never leave a sliver too short to be a clip at either edge.
            if start - segment.sourceStart < minimum { start = segment.sourceStart }
            if segment.sourceEnd - end < minimum { end = segment.sourceEnd }
            var pieces: [RecordingClipSegment] = []
            if start > segment.sourceStart {
                pieces.append(RecordingClipSegment(sourceStart: segment.sourceStart, sourceEnd: start, speed: segment.speed))
            }
            pieces.append(RecordingClipSegment(sourceStart: start, sourceEnd: end, speed: speed))
            if end < segment.sourceEnd {
                pieces.append(RecordingClipSegment(sourceStart: end, sourceEnd: segment.sourceEnd, speed: segment.speed))
            }
            pieces[0].id = segment.id
            segments.append(contentsOf: pieces)
        }

        var document = model.editDocument
        document.clips = segments
        let before = model.duration
        model.performAgentEdit { model.applyAgentDocument(document, actionName: "Change Speed") }
        model.flushDraft()
        return [json(editResult(model, removedSeconds: before - model.duration))]
    }

    static func editTranscript(_ arguments: AgentArguments) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        guard model.hasTranscriptWords else {
            throw AgentToolError.message("This recording has no word-level transcript. Call get_transcript with transcribe_if_missing: true first.")
        }
        let before = model.duration
        switch try arguments.string("action") {
        case "remove_filler_words":
            guard model.removableFillerWordCount > 0 else {
                throw AgentToolError.message("There are no filler words left to remove.")
            }
            model.performAgentEdit { model.removeFillerWords() }
        case "trim_silences":
            guard model.trimmableSilenceCount > 0 else {
                throw AgentToolError.message("There are no long pauses left to trim.")
            }
            model.performAgentEdit { model.trimNarrationSilences() }
        case "cut_words":
            guard let from = arguments.raw["from_index"]?.intValue,
                  let to = arguments.raw["to_index"]?.intValue,
                  from >= 0, to >= from, to < model.transcriptWords.count else {
                throw AgentToolError.message("cut_words needs from_index ≤ to_index, both within 0...\(model.transcriptWords.count - 1).")
            }
            model.performAgentEdit { model.cutTranscriptWords(in: from...to) }
        case let action:
            throw AgentToolError.message("Unknown action \"\(action)\".")
        }
        model.flushDraft()
        return [json(editResult(model, removedSeconds: before - model.duration))]
    }

    // MARK: - Items

    static func addItems(_ arguments: AgentArguments) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        let kind = try itemKind(arguments)
        guard kind != .image, kind != .audio else {
            throw AgentToolError.message("Add images and audio with add_media; then change them with update_items.")
        }
        let clock = try arguments.clock()
        let requested = try arguments.array("items")
        guard !requested.isEmpty else { throw AgentToolError.message("Pass at least one item.") }

        let document = try JSONValue(encoding: model.editDocument)
        var list = document[kind.documentKey]?.arrayValue ?? []
        var created: [JSONValue] = []
        for (index, item) in requested.enumerated() {
            guard var fields = item.objectValue else {
                throw AgentToolError.message("Item \(index) is not an object.")
            }
            guard fields["start"]?.doubleValue != nil, fields["end"]?.doubleValue != nil else {
                throw AgentToolError.message("Item \(index) needs start and end.")
            }
            fields = try convertTimes(fields, kind: kind, clock: clock, model: model)
            fields["id"] = .string(UUID().uuidString)
            if kind == .cameraLayout {
                // A partial layout ({"kind": "camera"}) fills in from the
                // project's default arrangement.
                let base = try JSONValue(encoding: model.style.camera.layout)
                fields["layout"] = base.merging(fields["layout"] ?? [:])
            }
            let normalized = try validated(.object(fields), kind: kind, label: "Item \(index)")
            list.append(normalized)
            created.append(normalized)
        }

        var patch: [String: JSONValue] = [kind.documentKey: .array(list)]
        if kind == .zoom { patch["zoomEnabled"] = true }
        if kind == .caption { patch["showsSubtitles"] = true }
        try apply(document.merging(.object(patch)), to: model, actionName: "Add \(kind.title)")
        let entries = created.map { timelineEntry($0, kind: kind, model: model) }
        return [json(["created": .array(created), "timeline": .array(entries), "editedDuration": seconds(model.duration)])]
    }

    static func updateItems(_ arguments: AgentArguments) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        let kind = try itemKind(arguments)
        let clock = try arguments.clock()
        let patches = try arguments.array("items")

        let document = try JSONValue(encoding: model.editDocument)
        var list = document[kind.documentKey]?.arrayValue ?? []
        var updated: [JSONValue] = []
        for (index, patch) in patches.enumerated() {
            guard var fields = patch.objectValue, let id = fields.removeValue(forKey: "id")?.stringValue else {
                throw AgentToolError.message("Entry \(index) needs the id of the item to change.")
            }
            guard let position = list.firstIndex(where: { sameID($0["id"], id) }) else {
                throw AgentToolError.message("No \(kind.rawValue) item has id \(id). get_recording lists them.")
            }
            fields = try convertTimes(fields, kind: kind, clock: clock, model: model)
            let normalized = try validated(list[position].merging(.object(fields)), kind: kind, label: "Entry \(index)")
            list[position] = normalized
            updated.append(normalized)
        }
        try apply(document.merging([kind.documentKey: .array(list)]), to: model, actionName: "Edit \(kind.title)")
        return [json(["updated": .array(updated), "timeline": .array(updated.map { timelineEntry($0, kind: kind, model: model) })])]
    }

    static func removeItems(_ arguments: AgentArguments) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        let kind = try itemKind(arguments)
        let ids = try arguments.array("ids").compactMap(\.stringValue)
        let document = try JSONValue(encoding: model.editDocument)
        let list = document[kind.documentKey]?.arrayValue ?? []
        let missing = ids.filter { id in !list.contains { sameID($0["id"], id) } }
        guard missing.isEmpty else {
            throw AgentToolError.message("No \(kind.rawValue) items with ids: \(missing.joined(separator: ", ")).")
        }
        let remaining = list.filter { item in !ids.contains { sameID(item["id"], $0) } }
        try apply(document.merging([kind.documentKey: .array(remaining)]), to: model, actionName: "Remove \(kind.title)")
        return [json(["removed": .number(Double(list.count - remaining.count)), "remaining": .number(Double(remaining.count))])]
    }

    static func addMedia(_ arguments: AgentArguments) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        let clock = try arguments.clock()
        let path = (try arguments.string("path") as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
            throw AgentToolError.message("No file at \(path). Pass an absolute path.")
        }
        let time = try arguments.double("time")
        let editedTime: TimeInterval
        switch clock {
        case .edited: editedTime = min(max(time, 0), model.duration)
        case .source:
            guard let mapped = model.clipTimeline.editorTime(forSourceTime: time) else {
                throw AgentToolError.message("Source time \(format(time))s has been cut from the edit.")
            }
            editedTime = mapped
        }

        let imageIDs = Set(model.imageOverlays.map(\.id))
        let audioIDs = Set(model.audioClips.map(\.id))
        guard await model.importMediaFile(URL(fileURLWithPath: path), atEditorTime: editedTime) else {
            throw AgentToolError.message("Couldn't add \((path as NSString).lastPathComponent). Images, GIFs and audio files can be added.")
        }
        model.closeOpenUndoGroups()
        model.flushDraft()
        if let image = model.imageOverlays.first(where: { !imageIDs.contains($0.id) }) {
            return [json(["kind": "image", "item": try JSONValue(encoding: image)])]
        }
        if let clip = model.audioClips.first(where: { !audioIDs.contains($0.id) }) {
            return [json(["kind": "audio", "item": try JSONValue(encoding: clip)])]
        }
        return [text("Added.")]
    }

    static func updateProject(_ arguments: AgentArguments) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        guard let patch = arguments.raw["patch"], let keys = patch.objectValue?.keys, !keys.isEmpty else {
            throw AgentToolError.message("Pass \"patch\": an object of the document fields to change.")
        }
        let document = try JSONValue(encoding: model.editDocument)
        try apply(document.merging(patch), to: model, actionName: "Edit Project")
        return [json(["applied": .array(keys.sorted().map { .string($0) }), "editedDuration": seconds(model.duration)])]
    }

    // MARK: - Project

    static func undoRedo(_ arguments: AgentArguments, redo: Bool) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        let steps = max(1, arguments.raw["steps"]?.intValue ?? 1)
        var done = 0
        model.closeOpenUndoGroups()
        while done < steps, redo ? model.canRedo : model.canUndo {
            redo ? model.redo() : model.undo()
            done += 1
        }
        guard done > 0 else {
            throw AgentToolError.message(redo ? "There is nothing to redo." : "There is nothing to undo.")
        }
        model.flushDraft()
        return [json([
            redo ? "redone" : "undone": .number(Double(done)),
            "canUndo": .bool(model.canUndo),
            "canRedo": .bool(model.canRedo),
            "editedDuration": seconds(model.duration),
        ])]
    }

    static func saveProject(_ arguments: AgentArguments) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        guard model.saveProject() else {
            throw AgentToolError.message("The project could not be saved.")
        }
        return [text("Saved \(model.projectDisplayName).")]
    }

    static func openInStudio(_ arguments: AgentArguments) throws -> [JSONValue] {
        let session = try AgentProjects.shared.session(for: arguments.recording())
        RecordingProjectOpener.shared.open(session)
        NSApp.activate()
        return [text("Opened \(session.displayName) in Studio.")]
    }

    // MARK: - Export

    /// Where the last agent export ended up (it may have been moved to an
    /// output_path), by project path.
    private static var exportNotes: [String: String] = [:]

    static func exportVideo(_ arguments: AgentArguments, progress: @escaping AgentProgress) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        guard !model.exportState.isExporting else {
            throw AgentToolError.message("This recording is already exporting. Poll export_status.")
        }
        guard !model.shareState.isBusy else {
            throw AgentToolError.message("This recording is being shared; try again when that finishes.")
        }
        let destination = try outputURL(arguments)

        model.exportState = .idle
        if let patch = arguments.raw["settings"], patch.objectValue?.isEmpty == false {
            let merged = try JSONValue(encoding: model.exportSettings).merging(patch)
            let settings: VideoCompressionSettings
            do {
                settings = try merged.decode(as: VideoCompressionSettings.self)
            } catch {
                throw AgentToolError.message("Invalid export settings: \(describe(error)). See get_editing_guide.")
            }
            model.export(settings: settings)
        } else {
            model.export()
        }

        let key = model.sessionURL.path
        exportNotes[key] = nil
        let finish: () async throws -> URL = {
            do {
                let url = try await waitForExport(state: { model.exportState }, progress: progress, label: "Rendering")
                let saved = try move(url, to: destination)
                exportNotes[key] = "Saved to \(saved.path)"
                return saved
            } catch is CancellationError {
                model.cancelExport()
                throw CancellationError()
            } catch {
                exportNotes[key] = "Failed: \(error.localizedDescription)"
                throw error
            }
        }

        guard arguments.bool("wait", default: true) else {
            Task { _ = try? await finish() }
            return [text("Export started. Poll export_status for progress.")]
        }
        let url = try await finish()
        return [json(exportedFile(url, duration: model.duration))]
    }

    static func exportAudio(_ arguments: AgentArguments, progress: @escaping AgentProgress) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        guard model.hasAudio else { throw AgentToolError.message("This recording has no audio.") }
        guard !model.audioExportState.isExporting else {
            throw AgentToolError.message("Audio is already exporting. Poll export_status.")
        }
        if let raw = arguments.optionalString("format") {
            guard let format = RecordingAudioFormat(rawValue: raw) else {
                let values = RecordingAudioFormat.allCases.map(\.rawValue).joined(separator: ", ")
                throw AgentToolError.message("Unknown audio format \"\(raw)\". Use one of: \(values).")
            }
            model.audioExportFormat = format
        }
        let destination = try outputURL(arguments)
        model.audioExportState = .idle
        model.exportAudio()

        let finish: () async throws -> URL = {
            do {
                let url = try await waitForExport(state: { model.audioExportState }, progress: progress, label: "Exporting audio")
                return try move(url, to: destination)
            } catch is CancellationError {
                model.cancelAudioExport()
                throw CancellationError()
            }
        }
        guard arguments.bool("wait", default: true) else {
            Task { _ = try? await finish() }
            return [text("Audio export started. Poll export_status for progress.")]
        }
        let url = try await finish()
        return [json(exportedFile(url, duration: model.duration))]
    }

    static func exportStatus(_ arguments: AgentArguments) async throws -> [JSONValue] {
        let model = try await AgentProjects.shared.model(for: arguments.recording())
        func describe(_ state: RecordingStudioExportState) -> JSONValue {
            switch state {
            case .idle: ["state": "idle"]
            case .exporting(let progress): ["state": "exporting", "progress": rounded(progress)]
            case .finished(let url) where FileManager.default.fileExists(atPath: url.path):
                ["state": "finished", "path": .string(url.path)]
            case .finished: ["state": "finished"]
            case .failed(let message): ["state": "failed", "error": .string(message)]
            }
        }
        var result: [String: JSONValue] = [
            "video": describe(model.exportState),
            "audio": describe(model.audioExportState),
        ]
        if let note = exportNotes[model.sessionURL.path] {
            result["lastAgentExport"] = .string(note)
        }
        return [json(.object(result))]
    }

    private static func waitForExport(
        state: () -> RecordingStudioExportState,
        progress: AgentProgress,
        label: String
    ) async throws -> URL {
        let began = ContinuousClock.now
        var started = false
        var lastPercent = -1
        while true {
            switch state() {
            case .exporting(let fraction):
                started = true
                let percent = Int(fraction * 100)
                if percent != lastPercent {
                    lastPercent = percent
                    progress(fraction, "\(label) \(percent)%")
                }
            case .finished(let url):
                return url
            case .failed(let message):
                throw AgentToolError.message("Export failed: \(message)")
            case .idle:
                if started { throw AgentToolError.message("The export was cancelled.") }
                if ContinuousClock.now - began > .seconds(20) {
                    throw AgentToolError.message("The export did not start.")
                }
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    private static func outputURL(_ arguments: AgentArguments) throws -> URL? {
        guard let raw = arguments.optionalString("output_path"), !raw.isEmpty else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else {
            throw AgentToolError.message("output_path must be absolute.")
        }
        return URL(fileURLWithPath: path)
    }

    private static func move(_ url: URL, to destination: URL?) throws -> URL {
        guard let destination, destination.standardizedFileURL != url.standardizedFileURL else { return url }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: url, to: destination)
        return destination
    }

    private static func exportedFile(_ url: URL, duration: TimeInterval) -> JSONValue {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
        return ["path": .string(url.path), "bytes": .number(size), "durationSeconds": seconds(duration)]
    }

    // MARK: - Helpers

    private static func itemKind(_ arguments: AgentArguments) throws -> AgentItemKind {
        let raw = try arguments.string("kind")
        guard let kind = AgentItemKind(rawValue: raw) else {
            let kinds = AgentItemKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw AgentToolError.message("Unknown kind \"\(raw)\". Use one of: \(kinds).")
        }
        return kind
    }

    /// Moves an item's time fields onto the clock its kind is stored on.
    private static func convertTimes(
        _ fields: [String: JSONValue],
        kind: AgentItemKind,
        clock: AgentClock,
        model: RecordingStudioModel
    ) throws -> [String: JSONValue] {
        var fields = fields
        if kind.isOnEditedClock {
            guard clock == .source, let start = fields["start"]?.doubleValue else { return fields }
            guard let edited = model.clipTimeline.editorTime(forSourceTime: start) else {
                throw AgentToolError.message("Source time \(format(start))s has been cut from the edit.")
            }
            fields["start"] = .number(edited)
            return fields
        }
        guard clock == .edited else { return fields }
        for key in ["start", "end"] {
            if let value = fields[key]?.doubleValue {
                fields[key] = .number(try toSource(value, clock: .edited, model: model))
            }
        }
        return fields
    }

    private static func validated(_ item: JSONValue, kind: AgentItemKind, label: String) throws -> JSONValue {
        let normalized: JSONValue
        do {
            normalized = try kind.normalized(item)
        } catch {
            throw AgentToolError.message("\(label) is not a valid \(kind.rawValue): \(describe(error)).")
        }
        if !kind.isOnEditedClock,
           let start = normalized["start"]?.doubleValue,
           let end = normalized["end"]?.doubleValue,
           end <= start {
            throw AgentToolError.message("\(label) ends before it starts.")
        }
        return normalized
    }

    private static func apply(_ document: JSONValue, to model: RecordingStudioModel, actionName: String) throws {
        let decoded: RecordingEditDocument
        do {
            decoded = try document.decode(as: RecordingEditDocument.self)
        } catch {
            throw AgentToolError.message("That would not be a valid project: \(describe(error)).")
        }
        model.performAgentEdit { model.applyAgentDocument(decoded, actionName: actionName) }
        model.flushDraft()
    }

    static func toSource(_ time: TimeInterval, clock: AgentClock, model: RecordingStudioModel) throws -> TimeInterval {
        guard time.isFinite else { throw AgentToolError.message("Times must be numbers of seconds.") }
        switch clock {
        case .source:
            return min(max(time, 0), model.sourceDuration)
        case .edited:
            return model.sourceTime(atEditorTime: min(max(time, 0), model.duration))
        }
    }

    private static func editResult(_ model: RecordingStudioModel, removedSeconds: TimeInterval) -> JSONValue {
        let timeline = model.clipTimeline
        return [
            "editedDuration": seconds(model.duration),
            "secondsRemoved": seconds(removedSeconds),
            "clips": .array(timeline.segments.map { segment in
                let edited = timeline.editorRange(for: segment.id)
                return [
                    "sourceStart": seconds(segment.sourceStart),
                    "sourceEnd": seconds(segment.sourceEnd),
                    "speed": .number(segment.speed),
                    "editedStart": edited.map { seconds($0.lowerBound) } ?? .null,
                    "editedEnd": edited.map { seconds($0.upperBound) } ?? .null,
                ]
            }),
        ]
    }

    private static func sameID(_ value: JSONValue?, _ id: String) -> Bool {
        value?.stringValue?.caseInsensitiveCompare(id) == .orderedSame
    }

    /// DecodingError's own description buries the field; lead with it.
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return path.isEmpty ? "" : "\(path): "
        }
        switch error {
        case .keyNotFound(let key, let context): return "\(path(context))missing \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context))\(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }

    static func seconds(_ value: TimeInterval) -> JSONValue {
        .number((value * 1000).rounded() / 1000)
    }

    static func rounded(_ value: Double) -> JSONValue {
        .number((value * 10_000).rounded() / 10_000)
    }

    static func format(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }
}
