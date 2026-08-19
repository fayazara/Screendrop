//
//  CloudSidecarUploader.swift
//  Screendrop
//
//  After a video reaches the cloud worker, this ships the assets that
//  turn its share page into a Loom-style viewer: a poster frame, a human
//  title, and the transcript. Transcript times are remapped from the
//  session's source timeline onto the uploaded cut when the exported
//  (edited) movie is what went up.
//
//  Sidecars are best-effort: the share link already works without them,
//  so failures are logged and swallowed.
//

import AVFoundation
import AppKit
import Foundation

/// Wire format for the worker's transcript sidecar
/// (`parseTranscript` on the worker side).
nonisolated private struct CloudTranscriptPayload: Encodable {
    struct Cue: Encodable {
        let start: Double
        let end: Double
        let text: String
    }

    struct Word: Encodable {
        let text: String
        let start: Double
        let end: Double
    }

    let cues: [Cue]
    let words: [Word]?
}

nonisolated enum CloudSidecarUploader {
    /// Fire-and-forget sidecar upload for a video that just finished its
    /// primary upload. `sessionDirectory` is nil for bare video files.
    static func uploadVideoSidecars(
        uploadID: String,
        uploadedFileURL: URL,
        sessionDirectory: URL?,
        createdAt: Date,
        customTitle: String? = nil,
        creds: CloudCredentials
    ) async {
        var fields: [(name: String, value: String)] = []
        var files: [(name: String, filename: String, contentType: String, data: Data)] = []

        let trimmedCustomTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        fields.append(("title", trimmedCustomTitle?.isEmpty == false ? trimmedCustomTitle! : defaultTitle(for: createdAt)))

        if let poster = await posterFrame(for: uploadedFileURL) {
            files.append(("poster", "poster.jpg", "image/jpeg", poster))
        }

        if let storyboard = await storyboard(for: uploadedFileURL) {
            files.append(("storyboard", "storyboard.jpg", "image/jpeg", storyboard.imageData))
            fields.append(("storyboard_meta", storyboard.metaJSON))
        }

        if let sessionDirectory,
           let transcript = transcriptPayload(
               sessionDirectory: sessionDirectory,
               uploadedFileURL: uploadedFileURL
           ),
           let encoded = try? JSONEncoder().encode(transcript) {
            fields.append(("transcript", String(decoding: encoded, as: UTF8.self)))
        }

        do {
            try await postAssets(
                uploadID: uploadID,
                fields: fields,
                files: files,
                creds: creds
            )
        } catch {
            print("Sidecar upload failed for \(uploadID): \(error)")
        }
    }

    // MARK: - Title

    /// "Screen Recording — Jul 17 at 9:46 PM": what the share page shows
    /// instead of a timestamped filename.
    private static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mm a"
        return "Screen Recording — \(formatter.string(from: date))"
    }

    // MARK: - Poster

    /// A frame from just past the start (the very first frame is often a
    /// blank desktop), sized for link previews.
    private static func posterFrame(for videoURL: URL) async -> Data? {
        let asset = AVURLAsset(url: videoURL)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0 else {
            return nil
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        let time = CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600)

        guard let image = try? await generator.image(at: time).image else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.82]
        )
    }

    // MARK: - Storyboard

    private struct Storyboard {
        let imageData: Data
        let metaJSON: String
    }

    private struct StoryboardMeta: Encodable {
        let tileWidth: Int
        let tileHeight: Int
        let columns: Int
        let interval: Double
        let count: Int
    }

    private static let storyboardTileWidth = 160
    private static let maximumStoryboardTiles = 100

    /// Sprite sheet for the share page's hover-scrub preview: one tile
    /// per interval, laid out in a near-square grid so the JPEG stays
    /// compact. The worker turns the grid metadata into a thumbnails
    /// WebVTT for the player.
    private static func storyboard(for videoURL: URL) async -> Storyboard? {
        let asset = AVURLAsset(url: videoURL)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration >= 2 else {
            return nil
        }

        let interval = max(1, (duration / Double(maximumStoryboardTiles)).rounded(.up))
        let count = max(1, Int((duration / interval).rounded(.up)))
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let rows = Int((Double(count) / Double(columns)).rounded(.up))

        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              naturalSize.width > 0, naturalSize.height > 0 else {
            return nil
        }
        let tileWidth = storyboardTileWidth
        var tileHeight = Int((CGFloat(tileWidth) * naturalSize.height / naturalSize.width).rounded())
        tileHeight += tileHeight % 2
        guard tileHeight > 0 else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: tileWidth * 2, height: tileHeight * 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: interval / 4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: interval / 4, preferredTimescale: 600)

        // A tile shows the frame from just inside its interval, so the
        // preview matches where a click would land.
        let times = (0..<count).map { index in
            CMTime(
                seconds: min(duration - 0.05, Double(index) * interval + min(0.5, interval / 2)),
                preferredTimescale: 600
            )
        }

        guard let context = CGContext(
            data: nil,
            width: tileWidth * columns,
            height: tileHeight * rows,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: tileWidth * columns, height: tileHeight * rows))

        var index = 0
        for await result in generator.images(for: times) {
            guard let image = try? result.image else {
                index += 1
                continue
            }
            let column = index % columns
            let row = index / columns
            // CGContext's origin is bottom-left; the sprite grid is
            // addressed top-left, so rows flip.
            let rect = CGRect(
                x: column * tileWidth,
                y: (rows - 1 - row) * tileHeight,
                width: tileWidth,
                height: tileHeight
            )
            context.draw(image, in: rect)
            index += 1
        }

        guard let sprite = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: sprite)
        guard let imageData = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.7]
        ) else {
            return nil
        }

        let meta = StoryboardMeta(
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            columns: columns,
            interval: interval,
            count: count
        )
        guard let metaData = try? JSONEncoder().encode(meta) else { return nil }
        return Storyboard(
            imageData: imageData,
            metaJSON: String(decoding: metaData, as: UTF8.self)
        )
    }

    // MARK: - Transcript

    private static func transcriptPayload(
        sessionDirectory: URL,
        uploadedFileURL: URL
    ) -> CloudTranscriptPayload? {
        let session = RecordingSession(directoryURL: sessionDirectory)
        // The upload was rendered from what the editor currently shows, so
        // the transcript has to come from the same document — the draft when
        // there is one, not the last saved state.
        guard let document = session.effectiveEditDocument(),
              let cues = document.subtitleCues, !cues.isEmpty else {
            return nil
        }
        let words = document.subtitleWords

        // The raw screen movie shares the transcript's source timeline;
        // only the exported cut needs its times remapped through the
        // clip timeline (which also accounts for per-clip speed).
        let uploadedFinalCut =
            uploadedFileURL.standardizedFileURL == session.finalURL.standardizedFileURL
        guard uploadedFinalCut else {
            return CloudTranscriptPayload(
                cues: cues.map { .init(start: $0.start, end: $0.end, text: $0.text) },
                words: words?.map { .init(text: $0.text, start: $0.start, end: $0.end) }
            )
        }

        guard let clips = document.clips, !clips.isEmpty else { return nil }
        let timeline = RecordingClipTimeline(segments: clips)

        let mappedCues = cues.compactMap { cue -> CloudTranscriptPayload.Cue? in
            guard let range = mapRange(cue.start, cue.end, through: timeline) else {
                return nil
            }
            return .init(start: range.0, end: range.1, text: cue.text)
        }
        guard !mappedCues.isEmpty else { return nil }

        let mappedWords = words?.compactMap { word -> CloudTranscriptPayload.Word? in
            guard let range = mapRange(word.start, word.end, through: timeline) else {
                return nil
            }
            return .init(text: word.text, start: range.0, end: range.1)
        }

        return CloudTranscriptPayload(cues: mappedCues, words: mappedWords)
    }

    /// Source range → surviving editor range; nil when fully cut out.
    private static func mapRange(
        _ start: TimeInterval,
        _ end: TimeInterval,
        through timeline: RecordingClipTimeline
    ) -> (Double, Double)? {
        let slices = timeline.slices(overlapping: start, sourceEnd: end)
        guard let first = slices.first, let last = slices.last,
              last.editorEnd > first.editorStart else {
            return nil
        }
        return (first.editorStart, last.editorEnd)
    }

    // MARK: - Multipart POST

    private static func postAssets(
        uploadID: String,
        fields: [(name: String, value: String)],
        files: [(name: String, filename: String, contentType: String, data: Data)],
        creds: CloudCredentials
    ) async throws {
        guard !fields.isEmpty || !files.isEmpty else { return }

        let workerBase = creds.workerURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = workerBase.lowercased().hasPrefix("http") ? workerBase : "https://\(workerBase)"
        guard let url = URL(string: "\(base)/api/assets/\(uploadID)") else {
            throw CloudUploadError.invalidURL
        }

        let boundary = "screendrop-\(UUID().uuidString)"
        var body = Data()
        func appendLine(_ string: String) {
            body.append(Data(string.utf8))
            body.append(Data("\r\n".utf8))
        }
        for field in fields {
            appendLine("--\(boundary)")
            appendLine("Content-Disposition: form-data; name=\"\(field.name)\"")
            appendLine("")
            appendLine(field.value)
        }
        for file in files {
            appendLine("--\(boundary)")
            appendLine(
                "Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\""
            )
            appendLine("Content-Type: \(file.contentType)")
            appendLine("")
            body.append(file.data)
            appendLine("")
        }
        appendLine("--\(boundary)--")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        let token = creds.uploadToken.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let (responseData, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let bodyText = String(data: responseData, encoding: .utf8) ?? ""
            throw CloudUploadError.serverError(
                (response as? HTTPURLResponse)?.statusCode ?? 0,
                bodyText
            )
        }
    }
}
