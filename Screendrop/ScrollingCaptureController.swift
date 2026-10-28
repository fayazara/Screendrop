//
//  ScrollingCaptureController.swift
//  Screendrop
//  Contributed by Rochak Agrawal (Screenshot X).
//
//  CleanShot-style scrolling capture. Pick a region, Screendrop scrolls the
//  content under the pointer, captures a sequence of viewports, matches the
//  overlap between consecutive frames and stitches them into one tall image.
//
//  Posting the scroll events needs Accessibility; the permission is requested
//  from the Enable Automatic Scrolling menu item.
//

import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

@MainActor
final class ScrollingCaptureController {
    static let shared = ScrollingCaptureController()

    private var isRunning = false
    private var cancelled = false
    private var hud: ScrollingCaptureHUD?
    private var livePreview: ScrollingLivePreview?
    private var regionOverlay: ScrollingCaptureRegionOverlay?
    private var keyMonitor: Any?

    private init() {}

    func start() {
        guard !isRunning else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            FailureAlert.present(
                message: "Screen Recording permission is required.",
                error: ScrollingCaptureError.captureUnavailable,
                detail: "Enable Screendrop under Privacy & Security → Screen & System Audio Recording, then try again."
            )
            return
        }
        guard ScrollingCapturePermission.isTrusted else {
            ScrollingCapturePermission.request()
            return
        }
        guard let screen = ActiveDisplayResolver.activeScreen(preferPointer: true) ?? NSScreen.main else {
            return
        }
        let displayID = ActiveDisplayResolver.displayID(for: screen)

        Task {
            let rect = await withCheckedContinuation { (continuation: CheckedContinuation<CGRect?, Never>) in
                RecordingAreaSelectionPresenter.shared.selectArea(on: screen) { rect in
                    continuation.resume(returning: rect)
                }
            }
            guard let rect, rect.width >= 40, rect.height >= 40 else { return }
            // Let the selection overlay leave the screen.
            try? await Task.sleep(for: .milliseconds(260))
            await run(rect: rect, screen: screen, displayID: displayID)
        }
    }

    #if DEBUG
    /// End-to-end check of the scrolling pipeline without synthetic input: it
    /// shows a tall test page, scrolls it between captures and stitches with
    /// the same capture and matching code the live session uses.
    func runSimulationTest(output: URL) {
        Task {
            let rect = CGRect(x: 240, y: 300, width: 480, height: 300)
            var report: [String: Any] = [:]
            report["rect"] = "\(rect)"

            let window = ScrollSimulationWindow(rect: rect)
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(700))

            guard let first = await capture(rect) else {
                report["result"] = "no-first-frame"
                ScrollSimulationReport.write(report, to: output)
                exit(1)
            }
            report["firstBlank"] = ScrollStitcher.isBlank(first)
            report["firstSize"] = "\(first.width)x\(first.height)"

            let stitcher = ScrollStitcher(first: first)
            var previous = first
            var blankFrames = 0
            // Deliberately uneven, sometimes far larger than the expected step.
            let steps: [CGFloat] = [60, 150, 90, 210, 120, 180]
            var scrolled: CGFloat = 0
            for step in steps {
                window.scroll(by: step)
                scrolled += step
                try? await Task.sleep(for: .milliseconds(340))
                guard let next = await capture(rect) else { continue }
                if ScrollStitcher.isBlank(next) {
                    blankFrames += 1
                    continue
                }
                if let dy = ScrollStitcher.overlap(previous: previous, next: next, expectedPixels: 168),
                   dy >= 2 {
                    stitcher.append(next, dy: dy)
                    previous = next
                }
            }

            report["frames"] = stitcher.count
            report["blankFrames"] = blankFrames
            report["stitchedHeight"] = stitcher.totalHeight
            report["scrolledPixels"] = Int(scrolled) * 2
            let composed = stitcher.count > 1 ? stitcher.compose() : nil
            report["composed"] = composed != nil
            if let composed, let url = writeTemporaryPNG(composed) {
                let target = output.appendingPathComponent("scroll-result.png")
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: url, to: target)
                try? FileManager.default.removeItem(at: url)
                report["result"] = "ok"
                report["blank"] = ScrollStitcher.isBlank(composed)
            } else {
                report["result"] = "compose-failed"
            }
            window.orderOut(nil)
            ScrollSimulationReport.write(report, to: output)
            exit(report["result"] as? String == "ok" ? 0 : 1)
        }
    }

    func runProbe(rect: CGRect) {
        Task {
            await run(rect: rect, screen: NSScreen.main ?? NSScreen.screens[0], displayID: nil)
        }
    }
    #endif

    private func run(rect: CGRect, screen: NSScreen, displayID: CGDirectDisplayID?) async {
        isRunning = true
        cancelled = false
        // Our own pins and preview cards are excluded from screen captures.
        // When one of them covers the chosen region the exclusion leaves a
        // transparent hole, which reads as a black frame and stitches into
        // nothing. Hide them for the whole session and put them back after.
        CaptureShelfPresenter.shared.hidePreviewForCapture()
        PinnedScreenshotPresenter.shared.hideAllForCapture()
        defer {
            isRunning = false
            removeKeyMonitor()
            hideOverlays()
            restoreFloatingCaptures()
        }

        var first: CGImage?
        var blankReports: [String] = []
        for attempt in 0..<4 {
            if let image = await capture(rect) {
                let blank = ScrollStitcher.isBlank(image)
                let report = "attempt \(attempt) size=\(image.width)x\(image.height) blank=\(blank)"
                blankReports.append(report)
                UserDefaults.standard.set(blankReports.joined(separator: " | "), forKey: "scrollFirstAttempt")
                if !blank {
                    first = image
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(320))
        }
        guard let first else {
            CaptureShelfPresenter.shared.restoreAdoptedAppIfNeeded()
            let sawBlank = blankReports.contains { $0.contains("blank=true") }
            FailureAlert.present(
                message: sawBlank
                    ? "The selected area came back blank."
                    : "The selected area could not be captured.",
                error: sawBlank
                    ? ScrollingCaptureError.emptyResult
                    : ScrollingCaptureError.captureUnavailable,
                detail: sawBlank
                    ? "Screendrop could not read any pixels there. Check Screen Recording in System Settings → Privacy & Security, and try an area that does not sit over a protected or full-screen video window."
                    : "Check that Screen Recording is enabled for Screendrop and that the area is not a secure or protected window."
            )
            return
        }

        let stitcher = ScrollStitcher(first: first)
        let model = ScrollingCaptureModel()
        model.frames = 1
        model.height = first.height
        model.preview = NSImage(cgImage: first, size: NSSize(width: first.width, height: first.height))

        showRegionOverlay(rect: rect)
        showHUD(model: model, rect: rect, screen: screen)
        showLivePreview(model: model, screen: screen, rect: rect)
        installKeyMonitor(model: model)

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        CGWarpMouseCursorPosition(
            CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        )
        try? await Task.sleep(for: .milliseconds(300))

        let scale = screen.backingScaleFactor
        let stepPoints = max(60, Int(rect.height * 0.3))
        let expectedPixels = Int(Double(stepPoints) * scale)

        var previous = first
        var misses = 0
        #if DEBUG
        let autoFinishDeadline = UserDefaults.standard.bool(forKey: "scrollAutoFinishTest")
            ? Date().addingTimeInterval(5)
            : nil
        #endif

        while !model.finishRequested && !model.cancelRequested {
            #if DEBUG
            // Lets the automated flow test end the session without synthetic
            // Return-key events, which need Accessibility.
            if let autoFinishDeadline, Date() >= autoFinishDeadline { break }
            #endif
            if model.autoScroll {
                postScroll(points: stepPoints, scale: scale)
                // Slow enough to watch; each step overlaps the previous view.
                try? await Task.sleep(for: .milliseconds(850))
            } else {
                // Poll quickly so a fast manual scroll is still matched step by
                // step instead of jumping past the overlap window.
                try? await Task.sleep(for: .milliseconds(140))
            }
            if model.finishRequested || model.cancelRequested { break }

            guard let next = await capture(rect), !ScrollStitcher.isBlank(next) else {
                model.status = "Area reads blank — keep it off protected or full-screen video"
                misses += 1
                // In manual mode keep waiting: the user may simply not have
                // scrolled yet. Auto mode stops when the page has ended.
                if model.autoScroll && misses >= 3 { break }
                continue
            }

            model.preview = NSImage(cgImage: next, size: NSSize(width: next.width, height: next.height))

            if let dy = ScrollStitcher.overlap(
                previous: previous,
                next: next,
                expectedPixels: expectedPixels
            ), dy >= 2 {
                stitcher.append(next, dy: dy)
                previous = next
                misses = 0
            } else {
                // Keep the last matched frame as the reference: a skipped
                // capture would otherwise break continuity and stop the count.
                misses += 1
            }
            if !model.autoScroll {
                model.status = misses == 0
                    ? "Capturing…"
                    : "Scroll the page to keep adding frames"
            }
            model.frames = stitcher.count
            model.height = stitcher.totalHeight
            if model.autoScroll && misses >= 8 { break }
            if stitcher.totalHeight > 30_000 { break }
        }

        removeKeyMonitor()
        hideOverlays()
        restoreFloatingCaptures()

        guard !model.cancelRequested else {
            CaptureShelfPresenter.shared.restoreAdoptedAppIfNeeded()
            return
        }

        let composed = stitcher.count > 1 ? stitcher.compose() : nil
        let result: CGImage? = composed ?? stitcher.firstImage
        UserDefaults.standard.set(
            "count=\(stitcher.count) height=\(stitcher.totalHeight) composed=\(composed != nil)",
            forKey: "scrollResultInfo"
        )
        guard let result, !ScrollStitcher.isBlank(result),
              let url = writeTemporaryPNG(result, scale: screen.backingScaleFactor)
        else {
            UserDefaults.standard.set("guard-failed", forKey: "scrollResultInfo")
            CaptureShelfPresenter.shared.restoreAdoptedAppIfNeeded()
            FailureAlert.present(
                message: "The scrolling capture did not produce an image.",
                error: ScrollingCaptureError.emptyResult,
                detail: "Try again and keep the selected border visible while the page scrolls."
            )
            return
        }

        if CaptureCoordinator.shared.presentScrollingCapture(url: url, displayID: displayID) == nil {
            CaptureShelfPresenter.shared.restoreAdoptedAppIfNeeded()
        }
    }

    // MARK: Capture and scroll

    private func capture(_ rect: CGRect) async -> CGImage? {
        UserDefaults.standard.set("\(rect)", forKey: "scrollCaptureRect")
        if let url = await ScreenshotManager.shared.captureRect(rect) {
            defer { try? FileManager.default.removeItem(at: url) }
            // Decode immediately: the temporary file is deleted as soon as
            // this function returns, and a lazily decoded image would draw as
            // fully transparent once the file is gone.
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, options) {
                UserDefaults.standard.set("rect", forKey: "scrollCaptureMode")
                return image
            }
        }

        // `screencapture -R` can refuse a region (for example while another
        // capture is still settling). Fall back to a display capture cropped
        // to exactly the same rectangle.
        if let image = await captureDisplayAndCrop(rect) {
            UserDefaults.standard.set("display-crop", forKey: "scrollCaptureMode")
            return image
        }
        UserDefaults.standard.set("nil", forKey: "scrollCaptureMode")
        return nil
    }

    private func captureDisplayAndCrop(_ rect: CGRect) async -> CGImage? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else {
            return nil
        }
        let displayID = ActiveDisplayResolver.displayID(for: screen)
        guard let url = await ScreenshotManager.shared.captureFullscreen(displayID: displayID) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }

        let scaleX = CGFloat(full.width) / max(screen.frame.width, 1)
        let scaleY = CGFloat(full.height) / max(screen.frame.height, 1)
        let x = (rect.minX - screen.frame.minX) * scaleX
        let top = (screen.frame.maxY - rect.maxY) * scaleY
        let width = max(1, rect.width * scaleX)
        let height = max(1, rect.height * scaleY)

        guard let context = CGContext(
            data: nil,
            width: Int(width.rounded()),
            height: Int(height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(
            full,
            in: CGRect(
                x: -x,
                y: -(CGFloat(full.height) - top - height),
                width: CGFloat(full.width),
                height: CGFloat(full.height)
            )
        )
        return context.makeImage()
    }

    private func postScroll(points: Int, scale: CGFloat) {
        let pixels = Int(Double(points) * scale)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(-pixels),
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.location = CGEvent(source: nil)?.location ?? .zero
        event.post(tap: .cghidEventTap)
    }

    private func writeTemporaryPNG(_ image: CGImage, scale: CGFloat = 2) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Screendrop_Scrolling_\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            ImageDPI.properties(scale: scale) as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    // MARK: Overlay, HUD and keys

    private func showRegionOverlay(rect: CGRect) {
        let overlay = ScrollingCaptureRegionOverlay()
        overlay.show(rect: rect)
        regionOverlay = overlay
    }

    private func showHUD(model: ScrollingCaptureModel, rect: CGRect, screen: NSScreen) {
        let hud = ScrollingCaptureHUD(model: model)
        hud.show(frame: hudFrame(for: rect, on: screen))
        self.hud = hud
    }

    private func showLivePreview(model: ScrollingCaptureModel, screen: NSScreen, rect: CGRect) {
        let preview = ScrollingLivePreview(model: model, screen: screen)
        preview.show(avoiding: rect)
        livePreview = preview
    }

    private func restoreFloatingCaptures() {
        CaptureShelfPresenter.shared.restorePreviewAfterCapture()
        PinnedScreenshotPresenter.shared.restoreAfterCapture()
    }

    private func hideOverlays() {
        hud?.hide()
        hud = nil
        livePreview?.hide()
        livePreview = nil
        regionOverlay?.hide()
        regionOverlay = nil
    }

    private func installKeyMonitor(model: ScrollingCaptureModel) {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: // Esc
                model.cancelRequested = true
                return nil
            case 36, 76: // Return / keypad Enter
                model.finishRequested = true
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func hudFrame(for rect: CGRect, on screen: NSScreen) -> CGRect {
        let size = CGSize(width: 390, height: 150)
        let visible = screen.visibleFrame
        let margin: CGFloat = 12

        var x = rect.minX
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)

        var y = rect.minY - size.height - margin
        if y < visible.minY + margin {
            y = rect.maxY + margin
        }
        if y + size.height > visible.maxY - margin {
            y = max(visible.minY + margin, visible.maxY - size.height - margin)
        }

        let proposed = CGRect(origin: CGPoint(x: x, y: y), size: size)
        if !proposed.insetBy(dx: -margin, dy: -margin).intersects(rect) {
            return proposed
        }

        // The region is large enough that the HUD would cover it; use a corner
        // of the screen that is clear of the capture instead.
        let corners = [
            CGPoint(x: visible.minX + margin, y: visible.minY + margin),
            CGPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin),
            CGPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin),
            CGPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
        ]
        for corner in corners {
            let candidate = CGRect(origin: corner, size: size)
            if !candidate.insetBy(dx: -margin, dy: -margin).intersects(rect) {
                return candidate
            }
        }
        return proposed
    }
}

private enum ScrollingCaptureError: LocalizedError {
    case captureUnavailable
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .captureUnavailable:
            "ScreenDrop could not read the screen."
        case .emptyResult:
            "The stitched image was empty."
        }
    }
}

// MARK: - Stitching

@MainActor
final class ScrollStitcher {
    private let first: CGImage
    private var segments: [(image: CGImage, dy: Int)] = []

    var count: Int { 1 + segments.count }
    var totalHeight: Int { first.height + segments.reduce(0) { $0 + $1.dy } }
    var firstImage: CGImage { first }

    init(first: CGImage) {
        self.first = first
    }

    func append(_ image: CGImage, dy: Int) {
        segments.append((image, dy))
    }

    func compose() -> CGImage? {
        let width = first.width
        let height = first.height
        let total = totalHeight
        guard total > height, width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: total,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(first, in: CGRect(x: 0, y: total - height, width: width, height: height))

        var y = total - height
        for segment in segments {
            y -= segment.dy
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: y, width: width, height: segment.dy))
            // The bottom `dy` rows of the new frame are the newly revealed
            // content; drawing the whole frame with its bottom at `y` puts
            // exactly those rows in the strip.
            context.setBlendMode(.copy)
            context.draw(
                segment.image,
                in: CGRect(x: 0, y: y, width: width, height: segment.image.height)
            )
            context.restoreGState()
        }
        return context.makeImage()
    }

    /// True when the capture is fully transparent. `screencapture` can return
    /// such an image when the calling app lacks Screen Recording permission,
    /// and the old stitcher would happily build a many-thousand-pixel blank
    /// file out of it.
    static func isBlank(_ image: CGImage) -> Bool {
        let width = 24
        let height = 24
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }

        var maxAlpha: UInt8 = 0
        for index in stride(from: 3, to: data.count, by: 4) {
            maxAlpha = max(maxAlpha, data[index])
        }
        return maxAlpha == 0
    }

    /// Vertical distance the content moved between frames, in pixels.
    ///
    /// A vertical scroll shifts whole rows. Row brightness alone gives a cheap
    /// first pass, but on a page of text every line looks alike, so the first
    /// pass only nominates candidate shifts; each candidate is then scored on
    /// the actual horizontal detail. That keeps the search fast while making a
    /// one-line alias score worse than the true offset, so a long page is not
    /// stitched from repeated rows.
    static func overlap(previous: CGImage, next: CGImage, expectedPixels: Int) -> Int? {
        guard previous.width == next.width, previous.height == next.height else { return nil }
        let coarseWidth = 160
        let fineWidth = 40
        let sampleHeight = min(previous.height, 1400)
        guard let coarseA = gray(previous, width: coarseWidth, height: sampleHeight),
              let coarseB = gray(next, width: coarseWidth, height: sampleHeight),
              hasDetail(coarseA), hasDetail(coarseB),
              let fineA = gray(previous, width: fineWidth, height: sampleHeight),
              let fineB = gray(next, width: fineWidth, height: sampleHeight)
        else { return nil }

        let expected = max(1, Int((Double(expectedPixels) * Double(sampleHeight) / Double(previous.height)).rounded()))
        let profileA = rowProfile(coarseA, width: coarseWidth, height: sampleHeight)
        let profileB = rowProfile(coarseB, width: coarseWidth, height: sampleHeight)
        let candidates = candidateShifts(profileA, profileB, expected: expected)
        guard !candidates.isEmpty else { return nil }

        var best: (dy: Int, score: Double)?
        for dy in candidates {
            let score = correlation(fineA, fineB, width: fineWidth, height: sampleHeight, dy: dy)
            if score > (best?.score ?? -1) {
                best = (dy, score)
            } else if let current = best, abs(score - current.score) <= 0.01,
                      abs(dy - expected) < abs(current.dy - expected) {
                best = (dy, score)
            }
        }

        guard let best, best.score >= 0.6 else { return nil }
        let pixels = Int((Double(best.dy) * Double(previous.height) / Double(sampleHeight)).rounded())
        guard pixels >= 3, pixels < previous.height else { return nil }
        return pixels
    }

    /// Average brightness of every row, which turns a vertical scroll into a
    /// plain shift of one array.
    private static func rowProfile(_ pixels: [UInt8], width: Int, height: Int) -> [Double] {
        var profile = [Double](repeating: 0, count: height)
        for y in 0..<height {
            var total = 0
            let row = y * width
            for x in 0..<width {
                total += Int(pixels[row + x])
            }
            profile[y] = Double(total) / Double(width)
        }
        return profile
    }

    /// Shifts worth scoring properly: the best row-profile matches that are not
    /// simply the same peak, plus the expected step.
    private static func candidateShifts(_ a: [Double], _ b: [Double], expected: Int) -> [Int] {
        let count = a.count
        guard count > 40, count == b.count else { return [] }
        let minimumOverlap = max(32, count / 4)
        var scores: [Double] = []
        var best = -1.0

        for dy in 2...(count - minimumOverlap) {
            let overlap = count - dy
            var sumA = 0.0
            var sumB = 0.0
            var sumAB = 0.0
            var sumAA = 0.0
            var sumBB = 0.0
            for index in 0..<overlap {
                let av = a[dy + index]
                let bv = b[index]
                sumA += av
                sumB += bv
                sumAB += av * bv
                sumAA += av * av
                sumBB += bv * bv
            }
            let n = Double(overlap)
            let varA = sumAA - sumA * sumA / n
            let varB = sumBB - sumB * sumB / n
            guard varA > 1e-6, varB > 1e-6 else {
                scores.append(-1)
                continue
            }
            let covariance = sumAB - sumA * sumB / n
            scores.append(covariance / (varA * varB).squareRoot())
            best = max(best, scores[scores.count - 1])
        }

        guard best >= 0.3 else { return [] }
        let floor = best - 0.25
        var peaks: [(dy: Int, score: Double)] = []
        for (index, score) in scores.enumerated() where score >= floor {
            let dy = index + 2
            guard !peaks.contains(where: { abs($0.dy - dy) < 5 }) else { continue }
            peaks.append((dy, score))
        }
        peaks.sort { $0.score > $1.score }
        var result = peaks.prefix(8).map(\.dy)
        if !result.contains(where: { abs($0 - expected) < 4 }) {
            result.append(expected)
        }
        return result
    }

    /// Normalised cross-correlation of the real pixel detail for one shift.
    private static func correlation(
        _ a: [UInt8],
        _ b: [UInt8],
        width: Int,
        height: Int,
        dy: Int
    ) -> Double {
        let overlap = height - dy
        guard overlap > 16 else { return -1 }
        var sumA = 0.0
        var sumB = 0.0
        var sumAB = 0.0
        var sumAA = 0.0
        var sumBB = 0.0
        for y in 0..<overlap {
            let aRow = (y + dy) * width
            let bRow = y * width
            for x in 0..<width {
                let av = Double(a[aRow + x])
                let bv = Double(b[bRow + x])
                sumA += av
                sumB += bv
                sumAB += av * bv
                sumAA += av * av
                sumBB += bv * bv
            }
        }
        let n = Double(overlap * width)
        let varA = sumAA - sumA * sumA / n
        let varB = sumBB - sumB * sumB / n
        guard varA > 1e-6, varB > 1e-6 else { return -1 }
        let covariance = sumAB - sumA * sumB / n
        return covariance / (varA * varB).squareRoot()
    }

    private static func hasDetail(_ pixels: [UInt8]) -> Bool {
        var low: UInt8 = 255
        var high: UInt8 = 0
        for value in pixels {
            low = min(low, value)
            high = max(high, value)
        }
        return Int(high) - Int(low) >= 2
    }

    private static func gray(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: width * height)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }
}

// MARK: - Region border

@MainActor
private final class ScrollingCaptureRegionOverlay {
    private var panel: NSPanel?

    func show(rect: CGRect) {
        hide()

        let frame = rect.insetBy(dx: -6, dy: -6)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Deliberately captured, not excluded: its frame spans the whole
        // selection and an excluded window is rendered as an empty hole by the
        // screen-capture APIs, which turned every frame black. The border is
        // drawn just outside the selected rectangle, so it stays out of the
        // result while the transparent interior shows the page.
        panel.sharingType = .readOnly
        panel.contentView = ScrollingCaptureRegionView(
            frame: CGRect(origin: .zero, size: frame.size)
        )
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class ScrollingCaptureRegionView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 3, dy: 3),
            xRadius: 8,
            yRadius: 8
        )

        NSColor.black.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 4
        path.stroke()

        NSColor.white.withAlphaComponent(0.95).setStroke()
        path.lineWidth = 2.5
        path.stroke()
    }
}

// MARK: - HUD

@MainActor
@Observable
final class ScrollingCaptureModel {
    var frames = 1
    var height = 0
    var autoScroll = false
    var finishRequested = false
    var cancelRequested = false
    var preview: NSImage?
    var status: String?
}

@MainActor
private final class ScrollingCaptureHUD {
    private let model: ScrollingCaptureModel
    private var panel: NSPanel?

    init(model: ScrollingCaptureModel) {
        self.model = model
    }

    func show(frame: CGRect) {
        let panel = ScrollingCaptureHUDPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: ScrollingCaptureHUDView(model: model))
        PreviewWindowCaptureExclusion.shared.register(window: panel)

        panel.setFrame(frame, display: false)
        // A non-activating panel can be key without bringing another window
        // forward, so Return/Esc reach this capture while the page underneath
        // stays visible and scrollable.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class ScrollingCaptureHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct ScrollingCaptureHUDView: View {
    let model: ScrollingCaptureModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            preview

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scrolling capture")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("\(model.frames) frames · \(model.height) px")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(
                    model.autoScroll
                        ? "Auto-scrolling slowly. Press Return to finish."
                        : "Scroll the page yourself, then press Return to finish."
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text("The border marks the area being captured. Esc cancels.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button(model.autoScroll ? "Manual" : "Auto Scroll") {
                        model.autoScroll.toggle()
                    }
                    .controlSize(.small)

                    Spacer(minLength: 0)

                    Button("Cancel") { model.cancelRequested = true }
                        .controlSize(.small)

                    Button("Done") { model.finishRequested = true }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .padding(2)
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.black.opacity(0.25))

            if let image = model.preview {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "rectangle.dashed")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 104, height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
    }
}

/// A small live card in the bottom-right while a scrolling capture runs. It
/// shows the latest viewport plus the frame count and stitched height, so it
/// is obvious that frames are being registered.
@MainActor
private final class ScrollingLivePreview {
    private let model: ScrollingCaptureModel
    private let screen: NSScreen
    private var panel: NSPanel?

    init(model: ScrollingCaptureModel, screen: NSScreen) {
        self.model = model
        self.screen = screen
    }

    func show(avoiding rect: CGRect) {
        let size = CGSize(width: 220, height: 140)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: ScrollingLivePreviewView(model: model))
        PreviewWindowCaptureExclusion.shared.register(window: panel)

        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        let candidates = [
            CGPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin),
            CGPoint(x: visible.minX + margin, y: visible.minY + margin),
            CGPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin),
            CGPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin)
        ]
        let origin = candidates.first {
            !CGRect(origin: $0, size: size).insetBy(dx: -12, dy: -12).intersects(rect)
        } ?? candidates[0]
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ScrollingLivePreviewView: View {
    let model: ScrollingCaptureModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.9)

            if let image = model.preview {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: model.autoScroll ? "arrow.down.circle.fill" : "hand.draw.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(model.frames) frames · \(model.height) px")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())

                if !model.autoScroll, let status = model.status {
                    Text(status)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: Capsule())
                }
            }
            .padding(8)
        }
        .frame(width: 220, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

#if DEBUG
/// A tall page for the scrolling self-test. It draws striped bands with a
/// readable position marker so consecutive viewports always differ.
@MainActor
final class ScrollSimulationWindow {
    private let window: NSWindow
    private let page = ScrollSimulationPage()

    init(rect: CGRect) {
        window = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .white
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = page
    }

    func orderFrontRegardless() {
        window.orderFrontRegardless()
    }

    func scroll(by points: CGFloat) {
        page.offset += points
        page.needsDisplay = true
        page.display()
        window.displayIfNeeded()
    }

    func orderOut(_ sender: Any?) {
        window.orderOut(sender)
    }
}

@MainActor
final class ScrollSimulationPage: NSView {
    var offset: CGFloat = 0

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        // Prose-like rows: real glyphs with uneven lines, so the row profile is
        // not periodic and the matcher cannot lock onto a repeated band.
        let words = [
            "screenshot", "window", "scrolling", "capture", "preview", "region",
            "scroll", "page", "content", "display", "border", "sticky", "header",
            "footer", "column", "button", "toolbar", "settings", "overlay"
        ]
        let line: CGFloat = 26
        var y = -offset.truncatingRemainder(dividingBy: line) - line
        var index = Int((offset / line).rounded(.down)) - 1
        while y < bounds.height + line {
            var text = "\(index)  "
            let seed = abs(index &* 2654435761)
            var value = seed
            let count = 4 + seed % 9
            for _ in 0..<count {
                value = (value &* 1103515245 &+ 12345) & 0x7fff_ffff
                text += words[value % words.count] + " "
            }
            (text as NSString).draw(
                at: NSPoint(x: 18, y: y),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor(white: 0.15, alpha: 1)
                ]
            )
            y += line
            index += 1
        }
    }
}

enum ScrollSimulationReport {
    static func write(_ report: [String: Any], to folder: URL) {
        let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: folder.appendingPathComponent("scroll-simulation.json"))
        if let data, let text = String(data: data, encoding: .utf8) {
            print("scrollSimulation \(text)")
        }
    }
}
#endif
