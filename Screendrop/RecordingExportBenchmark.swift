//
//  RecordingExportBenchmark.swift
//  Screendrop
//
//  Debug-only headless export timing. Launch the binary with
//  `-benchmarkExport <path to .screendroprec>` and it renders that
//  project's Studio export, prints the wall time to stdout, deletes the
//  output (unless `-benchmarkKeepOutput YES`), and exits - no windows,
//  hotkeys, or updater. The exporter's own StudioExport log lines carry
//  the per-stage breakdown.
//
//  The project's saved export settings apply unless overridden with
//  `-benchmarkCodec`, `-benchmarkFPS`, `-benchmarkMotionBlur`, or
//  `-benchmarkResolution`, using the settings' raw values ("HEVC",
//  "30 fps", "YES", "1080p").
//
//  `-benchmarkMatteCache <path to .screendroprec>` instead builds that
//  project's cutout matte cache, as Studio does in the background, and
//  prints how long it took.
//

#if DEBUG
import AVFoundation
import AppKit
import Foundation

enum RecordingExportBenchmark {
    static let argumentKey = "benchmarkExport"

    /// Returns true when this launch is a benchmark run; the caller must
    /// then skip normal startup.
    static func runIfRequested() -> Bool {
        if let path = UserDefaults.standard.string(forKey: "benchmarkMatteCache") {
            let session = RecordingSession(directoryURL: URL(fileURLWithPath: path).standardizedFileURL)
            Task {
                let started = CFAbsoluteTimeGetCurrent()
                await StudioCameraMatteCache.generate(cameraURL: session.cameraURL)
                let complete = StudioCameraMatteCache.isComplete(forCamera: session.cameraURL)
                print("benchmarkMatteCache seconds=\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - started)) complete=\(complete)")
                exit(complete ? 0 : 1)
            }
            return true
        }
        if let path = UserDefaults.standard.string(forKey: "studioEngineCheck") {
            Task { await runEngineCheck(projectPath: path) }
            return true
        }
        guard let path = UserDefaults.standard.string(forKey: argumentKey) else { return false }
        let session = RecordingSession(directoryURL: URL(fileURLWithPath: path).standardizedFileURL)
        Task {
            do {
                var configuration = try await RecordingSessionRenderer.makeConfiguration(for: session)
                applyOverrides(to: &configuration.exportSettings)
                let started = CFAbsoluteTimeGetCurrent()
                let outputURL = try await RecordingStudioExporter().export(configuration) { _ in }
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                let keepsOutput = UserDefaults.standard.bool(forKey: "benchmarkKeepOutput")
                if !keepsOutput { try? FileManager.default.removeItem(at: outputURL) }
                let settings = configuration.exportSettings
                print(
                    "benchmarkExport seconds=\(String(format: "%.2f", elapsed))"
                        + " codec=\(settings.codec.rawValue)"
                        + " fps=\(settings.effectiveFrameRate.framesPerSecond)"
                        + " motionBlur=\(settings.effectiveMotionBlurEnabled)"
                        + " canvas=\(Int(configuration.canvasSize.width))x\(Int(configuration.canvasSize.height))"
                        + (keepsOutput ? " output=\(outputURL.path)" : "")
                )
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("benchmarkExport failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        return true
    }

    /// `-studioEngineCheck <project> [-studioEngineCheckAudio <file>]`: loads
    /// the project through Studio's model with no window, runs the editing
    /// operations a person would (split, delete, cut, link, detach, undo,
    /// redo), prints the clips and audio after each, and leaves the result
    /// in the project's draft for `-benchmarkExport` to render. Run it on a
    /// copy: it edits the project.
    private static func runEngineCheck(projectPath: String) async {
        let model = RecordingStudioModel(url: URL(fileURLWithPath: projectPath).standardizedFileURL)
        model.isAgentSession = true
        await model.load()
        guard model.isLoaded else {
            FileHandle.standardError.write(Data("studioEngineCheck: could not load\n".utf8))
            exit(1)
        }
        func show(_ step: String) {
            let clips = model.clipTimeline.segments.map {
                String(format: "%.2f-%.2f@%gx%@", $0.sourceStart, $0.sourceEnd, $0.speed, $0.isMuted ? " muted" : "")
            }
            let audio = model.audioClips.map {
                String(
                    format: "[%@ L%d %.2f-%.2f file %.2f-%.2f@%gx%@%@]",
                    $0.source.rawValue, $0.lane, $0.start, $0.end, $0.trimStart, $0.trimEnd, $0.speed,
                    $0.isLinked ? " linked" : "", $0.isMuted ? " muted" : ""
                )
            }
            print("\(step): duration=\(String(format: "%.2f", model.duration)) clips=\(clips) audio=\(audio)")
        }
        func step(_ name: String, _ edit: () -> Void) {
            model.performAgentEdit(edit)
            show(name)
        }
        show("loaded")
        step("split at 2") { model.blade(at: 2) }
        step("delete second clip") {
            model.selectClip(id: model.clipTimeline.segments[1].id)
            model.deleteSelectedClip()
        }
        if let audioPath = UserDefaults.standard.string(forKey: "studioEngineCheckAudio") {
            _ = await model.importMediaFile(URL(fileURLWithPath: audioPath), atEditorTime: 1)
            model.closeOpenUndoGroups()
            show("import audio at 1")
            if let id = model.audioClips.last?.id {
                step("link audio") { model.setAudioClipLinked(true, id: id) }
                step("cut source 9-10") { model.cutSourceRanges([9...10], actionName: "Cut") }
                step("mute audio pieces") {
                    for clip in model.audioClips where clip.source == .file {
                        model.toggleAudioClipMuted(id: clip.id)
                    }
                }
            }
        }
        step("split everything at 0.5") { model.blade(at: 0.5, everything: true) }
        step("move last clip first") {
            if let last = model.clipTimeline.segments.last { model.moveClip(id: last.id, to: 0) }
        }
        print("hard cuts: \(model.clipTimeline.hardCuts)")
        step("marker at 0.25") {
            model.seek(to: 0.25)
            model.toggleMarker()
        }
        print("markers: \(model.markerEditorTimes.map(\.time))")
        step("mark 0.1-0.3 and delete it") {
            model.seek(to: 0.1)
            model.markRange(.start)
            model.seek(to: 0.3)
            model.markRange(.end)
            model.deleteRange()
        }
        if model.replacementAudio != nil {
            let file = model.replacementAudio?.url.lastPathComponent ?? ""
            step("remove replaced audio") { model.removeReplacementAudio() }
            model.undo()
            print("undo brings replaced audio back: \(model.replacementAudio?.url.lastPathComponent == file) file exists: \(FileManager.default.fileExists(atPath: model.replacementAudio?.url.path ?? ""))")
            model.redo()
            model.undo()
        }
        step("detach audio of first clip") { model.detachAudio(fromClipID: model.clipTimeline.segments[0].id) }
        step("trim start to playhead at 1") {
            model.seek(to: 1)
            model.clearTimelineSelection()
            model.trimToPlayhead(.start)
        }
        let edited = model.editDocument
        var undone = 0
        while model.canUndo { model.undo(); undone += 1 }
        show("undo x\(undone)")
        while model.canRedo { model.redo() }
        show("redo all")
        print("redo restores the edit: \(model.editDocument == edited)")
        print("player item duration: \(String(format: "%.2f", model.screenPlayer.currentItem?.asset.duration.seconds ?? -1))")
        model.flushDraft()
        exit(0)
    }

    private static func applyOverrides(to settings: inout VideoCompressionSettings) {
        let defaults = UserDefaults.standard
        if let codec = defaults.string(forKey: "benchmarkCodec").flatMap(VideoCompressionCodec.init(rawValue:)) {
            settings.codec = codec
        }
        if let frameRate = defaults.string(forKey: "benchmarkFPS").flatMap(VideoExportFrameRate.init(rawValue:)) {
            settings.frameRate = frameRate
        }
        if defaults.object(forKey: "benchmarkMotionBlur") != nil {
            settings.motionBlurEnabled = defaults.bool(forKey: "benchmarkMotionBlur")
        }
        if let resolution = defaults.string(forKey: "benchmarkResolution")
            .flatMap(VideoCompressionResolution.init(rawValue:)) {
            settings.resolution = resolution
        }
    }
}
#endif
