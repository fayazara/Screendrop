//
//  AgentTools.swift
//  Screendrop
//
//  The tools the agent (MCP) server offers, and their dispatch. The
//  descriptions are written for the model on the other end: they are the
//  only documentation it gets, so they spell out units, clocks, and what
//  each call changes.
//

import Foundation

/// Which timeline a time refers to. Source time is the raw recording;
/// edited time is the movie after cuts and speed changes.
enum AgentClock: String {
    case source
    case edited
}

/// Typed access to a tool's arguments, with errors the model can act on.
struct AgentArguments {
    let raw: JSONValue

    func string(_ key: String) throws -> String {
        guard let value = raw[key]?.stringValue, !value.isEmpty else {
            throw AgentToolError.message("Missing required string argument \"\(key)\".")
        }
        return value
    }

    func optionalString(_ key: String) -> String? {
        raw[key]?.stringValue
    }

    func double(_ key: String) throws -> Double {
        guard let value = raw[key]?.doubleValue, value.isFinite else {
            throw AgentToolError.message("Missing required number argument \"\(key)\".")
        }
        return value
    }

    func optionalDouble(_ key: String) -> Double? {
        raw[key]?.doubleValue
    }

    func bool(_ key: String, default defaultValue: Bool) -> Bool {
        raw[key]?.boolValue ?? defaultValue
    }

    func array(_ key: String) throws -> [JSONValue] {
        guard let value = raw[key]?.arrayValue else {
            throw AgentToolError.message("Missing required array argument \"\(key)\".")
        }
        return value
    }

    func clock() throws -> AgentClock {
        guard let raw = raw["clock"]?.stringValue else {
            throw AgentToolError.message("Pass \"clock\": \"source\" or \"edited\" to say which timeline the times are on.")
        }
        guard let clock = AgentClock(rawValue: raw) else {
            throw AgentToolError.message("\"clock\" must be \"source\" or \"edited\", not \"\(raw)\".")
        }
        return clock
    }

    func recording() throws -> String {
        try string("recording")
    }
}

@MainActor
enum AgentTools {
    static let instructions = """
    Screendrop is a local macOS screen recorder with a non-destructive video editor (Studio). \
    These tools read and edit Screendrop recordings and export the result.

    Workflow: list_recordings → get_recording (timeline, clips, every overlay) → get_transcript and \
    get_input_events to find moments → edit → get_frame to look at the picture → export_video.

    Two clocks. "source" time is seconds into the raw recording and never changes. "edited" time is \
    seconds into the cut movie, after cuts and speed changes. Every tool that takes a time asks which \
    clock it is on, and outputs give both where they exist. Zooms, text, redactions, camera layouts and \
    captions are stored on the source clock, so they stay attached to their footage when you cut; \
    added audio clips are on the edited clock.

    Coordinates are normalized 0...1 with a top-left origin. Points encode as [x, y] and rects as \
    [[x, y], [width, height]].

    Edits are saved to the project's draft right away and each one is a single undo step. If the \
    recording is open in Studio the user sees the change live and can undo it there. Call \
    save_project when the user wants the edit committed. Call get_editing_guide for every allowed \
    enum value (fonts, animations, layouts, export formats, backgrounds).
    """

    static var definitions: [JSONValue] {
        [
            tool(
                "list_recordings",
                title: "List recordings",
                description: "Lists Screendrop recordings, most recently used first, with their ids, names, durations and sizes. Use the id with every other tool.",
                properties: [
                    "query": ["type": "string", "description": "Only recordings whose name contains this text (case-insensitive)."],
                    "limit": ["type": "integer", "description": "Most to return. Defaults to 20."],
                ],
                readOnly: true
            ),
            tool(
                "get_recording",
                title: "Get recording",
                description: "The whole edit of one recording: source and edited durations, the clip list (source range, speed, edited range), every zoom, text, redaction, camera layout, image and audio clip with its source and edited times, the style, and the export settings. The `document` field is the editable project; update_project patches it.",
                properties: ["recording": recordingProperty],
                required: ["recording"],
                readOnly: true
            ),
            tool(
                "get_transcript",
                title: "Get transcript",
                description: "Word-level transcript with source times, edited times (blank when the word has been cut), and filler-word flags, plus the caption cues. Word indices are what edit_transcript's cut_words takes. Set transcribe_if_missing to run on-device speech recognition first when the recording has none (can take a minute).",
                properties: [
                    "recording": recordingProperty,
                    "transcribe_if_missing": ["type": "boolean", "description": "Transcribe the recording if it has no transcript yet. Defaults to false."],
                    "include_cut_words": ["type": "boolean", "description": "Include words already cut from the edit. Defaults to true."],
                ],
                required: ["recording"],
                readOnly: false
            ),
            tool(
                "get_input_events",
                title: "Get input events",
                description: "What the user did while recording: mouse clicks (with normalized position), keyboard shortcuts, and optionally the cursor path. Times are given on both clocks. Good for finding where to zoom, what to cut, or what a moment shows.",
                properties: [
                    "recording": recordingProperty,
                    "start": ["type": "number", "description": "Start of the window, in seconds on `clock`. Defaults to the beginning."],
                    "end": ["type": "number", "description": "End of the window, in seconds on `clock`. Defaults to the end."],
                    "clock": clockProperty,
                    "include_cursor": ["type": "boolean", "description": "Include cursor positions sampled at cursor_hz. Defaults to false."],
                    "cursor_hz": ["type": "number", "description": "Cursor samples per second when include_cursor is true. Defaults to 4."],
                ],
                required: ["recording", "clock"],
                readOnly: true
            ),
            tool(
                "get_frame",
                title: "Get frame",
                description: "A JPEG of the raw recorded screen at a moment, so you can see what is on screen. This is the unstyled source picture (no background, zoom or overlays), which is the same space redaction rects and zoom points use.",
                properties: [
                    "recording": recordingProperty,
                    "time": ["type": "number", "description": "Seconds on `clock`."],
                    "clock": clockProperty,
                    "max_size": ["type": "integer", "description": "Longest side in pixels. Defaults to 1280."],
                ],
                required: ["recording", "time", "clock"],
                readOnly: true
            ),
            tool(
                "cut",
                title: "Cut ranges",
                description: "Removes time ranges from the edited movie. Non-destructive: the footage stays in the source and can be restored with undo or by patching `clips`. Captions overlapping a cut lose the cut words.",
                properties: [
                    "recording": recordingProperty,
                    "ranges": [
                        "type": "array",
                        "description": "Ranges to remove, each {start, end} in seconds on `clock`.",
                        "items": rangeSchema,
                    ],
                    "clock": clockProperty,
                ],
                required: ["recording", "ranges", "clock"]
            ),
            tool(
                "set_speed",
                title: "Set speed",
                description: "Plays a range faster (1 to 8x), splitting clips at its edges. Audio speeds up with the picture. Use 1 to return a range to normal speed.",
                properties: [
                    "recording": recordingProperty,
                    "start": ["type": "number", "description": "Seconds on `clock`."],
                    "end": ["type": "number", "description": "Seconds on `clock`."],
                    "clock": clockProperty,
                    "speed": ["type": "number", "description": "Playback rate, 1...8."],
                ],
                required: ["recording", "start", "end", "clock", "speed"]
            ),
            tool(
                "edit_transcript",
                title: "Edit by transcript",
                description: "Transcript-driven cuts. remove_filler_words cuts \"um\", \"uh\" and similar; trim_silences shortens long pauses in the narration; cut_words cuts the footage under words from_index through to_index (inclusive, indices from get_transcript). Needs a transcript.",
                properties: [
                    "recording": recordingProperty,
                    "action": ["type": "string", "enum": ["remove_filler_words", "trim_silences", "cut_words"]],
                    "from_index": ["type": "integer", "description": "First word to cut (cut_words)."],
                    "to_index": ["type": "integer", "description": "Last word to cut, inclusive (cut_words)."],
                ],
                required: ["recording", "action"]
            ),
            tool(
                "add_items",
                title: "Add items",
                description: "Adds zooms, text, redactions (blur/pixelate), camera layout changes, or captions. Each item is a partial object: give start and end (on `clock`) plus any fields you want to set; the rest take defaults. Field names match get_recording's document. Returns the created items with their ids. Images and audio are added with add_media.",
                properties: [
                    "recording": recordingProperty,
                    "kind": ["type": "string", "enum": ["zoom", "text", "redaction", "camera_layout", "caption"]],
                    "clock": clockProperty,
                    "items": ["type": "array", "items": ["type": "object"], "description": itemFieldsDescription],
                ],
                required: ["recording", "kind", "clock", "items"]
            ),
            tool(
                "update_items",
                title: "Update items",
                description: "Changes existing items by id. Each entry is {id, ...fields to change}; fields you leave out keep their values (merge patch). Times you give are on `clock`.",
                properties: [
                    "recording": recordingProperty,
                    "kind": itemKindProperty,
                    "clock": clockProperty,
                    "items": ["type": "array", "items": ["type": "object"], "description": itemFieldsDescription],
                ],
                required: ["recording", "kind", "clock", "items"]
            ),
            tool(
                "remove_items",
                title: "Remove items",
                description: "Removes items by id.",
                properties: [
                    "recording": recordingProperty,
                    "kind": itemKindProperty,
                    "ids": ["type": "array", "items": ["type": "string"]],
                ],
                required: ["recording", "kind", "ids"],
                destructive: true
            ),
            tool(
                "add_media",
                title: "Add media",
                description: "Copies an image, GIF, or audio file into the project and places it at a time. Images become overlays (move them with update_items kind \"image\"); audio becomes a clip under the video.",
                properties: [
                    "recording": recordingProperty,
                    "path": ["type": "string", "description": "Absolute path to the file."],
                    "time": ["type": "number", "description": "Where it starts, seconds on `clock`."],
                    "clock": clockProperty,
                ],
                required: ["recording", "path", "time", "clock"]
            ),
            tool(
                "update_project",
                title: "Update project",
                description: "Applies a JSON merge patch (RFC 7386) to the project document from get_recording: objects merge, arrays replace, null removes. Use it for style (background, padding, cornerRadius, shadow, cursor, camera), toggles (zoomEnabled, showsSubtitles, showsKeystrokes, showsClickEffects, showsSpeedBadge), subtitle look, exportAspect/exportAspectMode, videoCropRect, audioVolume, exportSettings, or the `clips` list itself (source ranges with speeds, in order). Rejected if the result is not a valid project.",
                properties: [
                    "recording": recordingProperty,
                    "patch": ["type": "object", "description": "Merge patch against get_recording's `document`."],
                ],
                required: ["recording", "patch"]
            ),
            tool(
                "undo",
                title: "Undo",
                description: "Undoes the last edit (yours or the user's in Studio).",
                properties: [
                    "recording": recordingProperty,
                    "steps": ["type": "integer", "description": "How many edits to undo. Defaults to 1."],
                ],
                required: ["recording"]
            ),
            tool(
                "redo",
                title: "Redo",
                description: "Redoes the last undone edit.",
                properties: [
                    "recording": recordingProperty,
                    "steps": ["type": "integer", "description": "How many edits to redo. Defaults to 1."],
                ],
                required: ["recording"]
            ),
            tool(
                "save_project",
                title: "Save project",
                description: "Commits the current edit as the project's saved state (like ⌘S in Studio). Edits are already autosaved to a draft; saving is what the user sees as \"saved\".",
                properties: ["recording": recordingProperty],
                required: ["recording"]
            ),
            tool(
                "open_in_studio",
                title: "Open in Studio",
                description: "Opens the recording in a Screendrop Studio window so the user can watch and review the edit.",
                properties: ["recording": recordingProperty],
                required: ["recording"]
            ),
            tool(
                "export_video",
                title: "Export video",
                description: "Renders the edited video with everything applied and saves it. By default it goes to the user's Screendrop export folder; output_path moves it somewhere specific. Waits for the render and reports progress unless wait is false (then poll export_status).",
                properties: [
                    "recording": recordingProperty,
                    "output_path": ["type": "string", "description": "Absolute file path to move the finished video to. Its extension should match the container."],
                    "settings": ["type": "object", "description": "Merge patch for the export settings: quality, speed, codec, resolution, container, frameRate, motionBlurEnabled, removeAudio. See get_editing_guide for values. Saved into the project."],
                    "wait": ["type": "boolean", "description": "Wait for the export to finish. Defaults to true."],
                ],
                required: ["recording"]
            ),
            tool(
                "export_audio",
                title: "Export audio",
                description: "Writes the edited soundtrack on its own (cuts and speed applied).",
                properties: [
                    "recording": recordingProperty,
                    "output_path": ["type": "string", "description": "Absolute file path to move the finished audio to."],
                    "format": ["type": "string", "description": "Audio format; see get_editing_guide. Defaults to the project's."],
                    "wait": ["type": "boolean", "description": "Wait for the export to finish. Defaults to true."],
                ],
                required: ["recording"]
            ),
            tool(
                "export_status",
                title: "Export status",
                description: "Progress or result of the latest video and audio export for a recording.",
                properties: ["recording": recordingProperty],
                required: ["recording"],
                readOnly: true
            ),
            tool(
                "get_editing_guide",
                title: "Editing guide",
                description: "Reference for editing: every allowed enum value (zoom anchors, fonts, text animations, redaction styles, camera layouts, keystroke placements, export aspect, quality, codec, container, frame rate, audio formats, cursor styles), the item field lists, and the background presets.",
                properties: [:],
                readOnly: true
            ),
        ]
    }

    static func call(_ name: String, arguments raw: JSONValue, progress: @escaping AgentProgress) async throws -> [JSONValue] {
        let arguments = AgentArguments(raw: raw)
        switch name {
        case "list_recordings": return try listRecordings(arguments)
        case "get_recording": return try await getRecording(arguments)
        case "get_transcript": return try await getTranscript(arguments, progress: progress)
        case "get_input_events": return try await getInputEvents(arguments)
        case "get_frame": return try await getFrame(arguments)
        case "cut": return try await cut(arguments)
        case "set_speed": return try await setSpeed(arguments)
        case "edit_transcript": return try await editTranscript(arguments)
        case "add_items": return try await addItems(arguments)
        case "update_items": return try await updateItems(arguments)
        case "remove_items": return try await removeItems(arguments)
        case "add_media": return try await addMedia(arguments)
        case "update_project": return try await updateProject(arguments)
        case "undo": return try await undoRedo(arguments, redo: false)
        case "redo": return try await undoRedo(arguments, redo: true)
        case "save_project": return try await saveProject(arguments)
        case "open_in_studio": return try openInStudio(arguments)
        case "export_video": return try await exportVideo(arguments, progress: progress)
        case "export_audio": return try await exportAudio(arguments, progress: progress)
        case "export_status": return try await exportStatus(arguments)
        case "get_editing_guide": return [text(AgentEditingGuide.text)]
        default: throw AgentToolError.message("Unknown tool \"\(name)\".")
        }
    }

    // MARK: - Schema helpers

    static let recordingProperty: JSONValue = [
        "type": "string",
        "description": "Recording id from list_recordings (an absolute package path also works).",
    ]

    static let clockProperty: JSONValue = [
        "type": "string",
        "enum": ["source", "edited"],
        "description": "Timeline the times are on: \"source\" = seconds into the raw recording, \"edited\" = seconds into the cut movie.",
    ]

    static let itemKindProperty: JSONValue = [
        "type": "string",
        "enum": ["zoom", "text", "redaction", "camera_layout", "caption", "image", "audio"],
    ]

    static let rangeSchema: JSONValue = [
        "type": "object",
        "properties": ["start": ["type": "number"], "end": ["type": "number"]],
        "required": ["start", "end"],
    ]

    static let itemFieldsDescription: JSONValue = """
    zoom: start, end, zoom (magnification, e.g. 1.5-3), anchorMode, pinnedPoint [x,y] (framed when anchorMode is \"pinnedAnchor\"), isEnabled. \
    text: start, end, text, center [x,y], fontSize (fraction of canvas height, 0.02-0.3), font, color {red,green,blue,alpha 0-1}, isBold, hasBackground, backgroundColor, animationIn, animationOut. \
    redaction: start, end, rect [[x,y],[w,h]] in the recorded picture, style (pixelate|blur), amount 0-1, cornerRadius, fadeIn, fadeOut. \
    camera_layout: start, end, layout (see get_editing_guide). \
    caption: start, end, text. \
    image: start, end, center [x,y], width (fraction of canvas width), rotation (degrees), opacity, cornerRadius, shadow, fadeIn, fadeOut. \
    audio: start (edited clock), trimStart, trimEnd, volume 0-1, fadeIn, fadeOut.
    """

    private static func tool(
        _ name: String,
        title: String,
        description: String,
        properties: [String: JSONValue],
        required: [String] = [],
        readOnly: Bool = false,
        destructive: Bool = false
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object(schema),
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(readOnly),
                "openWorldHint": false,
            ],
        ]
    }

    // MARK: - Content helpers

    static func text(_ string: String) -> JSONValue {
        ["type": "text", "text": .string(string)]
    }

    /// Compact: tool output is read by a model, and pretty-printing
    /// roughly doubles its token cost.
    static func json(_ value: JSONValue) -> JSONValue {
        text(value.compactString)
    }

    static func image(_ data: Data, mimeType: String) -> JSONValue {
        ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)]
    }
}
