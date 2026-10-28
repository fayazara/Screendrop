//
//  PreviewSelfTest.swift
//  Screendrop
//  Contributed by Rochak Agrawal (Screenshot X).
//
//  Debug-only headless check for the floating preview. Launch with
//  `-previewSelfTest YES -previewSelfTestOutput <folder>` and the app shows a
//  sample capture, writes PNGs of the card at rest and on hover, drags it to
//  a new place, verifies the place is remembered and stays on screen, writes
//  a JSON report, then exits.
//
//  It renders the panel's own content view, so it needs no screen-recording
//  permission and no synthetic mouse clicks. The cursor is only warped onto
//  the card so its hover controls can be photographed.
//

#if DEBUG
import AppKit
import ApplicationServices
import Foundation
import ImageIO

enum PreviewSelfTest {
    static let argumentKey = "previewSelfTest"

    /// Returns true when this launch is a preview self-test; the caller must
    /// then skip normal startup.
    static func runIfRequested() -> Bool {
        guard UserDefaults.standard.bool(forKey: argumentKey) else { return false }
        Task { await run() }
        return true
    }

    private static func run() async {
        let output = URL(
            fileURLWithPath: UserDefaults.standard.string(forKey: "previewSelfTestOutput")
                ?? NSTemporaryDirectory()
        )
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var report: [String: Any] = [:]
        report["axTrusted"] = AXIsProcessTrusted()
        report["screenCaptureTrusted"] = CGPreflightScreenCaptureAccess()

        if UserDefaults.standard.bool(forKey: "captureMetaTest") {
            let rect = CGRect(x: 200, y: 300, width: 500, height: 300)
            var report: [String: Any] = [:]
            if let url = await ScreenshotManager.shared.captureRect(rect),
               let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                report["dpiWidth"] = props[kCGImagePropertyDPIWidth]
                report["dpiHeight"] = props[kCGImagePropertyDPIHeight]
                try? FileManager.default.copyItem(
                    at: url,
                    to: output.appendingPathComponent("meta-capture.png")
                )
                try? FileManager.default.removeItem(at: url)
            }
            report["result"] = "ok"
            ScrollSimulationReport.write(report, to: output)
            exit(0)
        }

        if UserDefaults.standard.bool(forKey: "autoNameTest") {
            await runAutoNameTest(output: output)
            return
        }

        if UserDefaults.standard.bool(forKey: "pinResizeTest") {
            await runPinResizeTest(output: output)
            return
        }

        if UserDefaults.standard.bool(forKey: "pinChainTest") {
            await runPinChainTest(output: output)
            return
        }

        if UserDefaults.standard.bool(forKey: "scrollFlowTest") {
            await runScrollFlowTest(output: output)
            return
        }

        if UserDefaults.standard.bool(forKey: "scrollSimulation") {
            ScrollingCaptureController.shared.runSimulationTest(output: output)
            return
        }

        if UserDefaults.standard.bool(forKey: "scrollRunProbe") {
            ScrollingCaptureController.shared.runProbe(rect: CGRect(x: 200, y: 300, width: 500, height: 300))
            return
        }

        if UserDefaults.standard.bool(forKey: "scrollCaptureProbe") {
            let screens = NSScreen.screens.map { "\($0.frame) scale=\($0.backingScaleFactor)" }
            let rect = CGRect(x: 200, y: 300, width: 500, height: 300)
            let url = await ScreenshotManager.shared.captureRect(rect)
            var probe: [String: Any] = ["screens": screens, "rect": "200,300,500,300", "url": url?.path ?? "nil"]
            if let url,
               let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                probe["size"] = "\(image.width)x\(image.height)"
                probe["blank"] = ScrollStitcher.isBlank(image)
                try? FileManager.default.removeItem(at: url)
            }
            finish(report: probe, output: output)
            return
        }

        if UserDefaults.standard.bool(forKey: "scrollStitchTest") {
            let width = 400, sourceHeight = 1800, viewport = 500
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil, width: width, height: sourceHeight,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { finish(report: ["error": "no context"], output: output); return }
            for band in 0..<36 {
                let hue = Double(band) / 36.0
                context.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: band * 50, width: width, height: 50))
                context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
                context.fill(CGRect(x: 12 + band * 7 % 260, y: band * 50 + 16, width: 120, height: 14))
            }
            guard let source = context.makeImage() else {
                finish(report: ["error": "no source"], output: output); return
            }
            var frames: [CGImage] = []
            for offset in stride(from: 0, through: 1000, by: 250) {
                if let crop = source.cropping(to: CGRect(x: 0, y: offset, width: width, height: viewport)) {
                    frames.append(crop)
                }
            }
            guard frames.count > 1 else {
                finish(report: ["error": "no crops"], output: output); return
            }
            let stitcher = ScrollStitcher(first: frames[0])
            var dys: [Int] = []
            for index in 1..<frames.count {
                if let dy = ScrollStitcher.overlap(
                    previous: frames[index - 1],
                    next: frames[index],
                    expectedPixels: 250
                ) {
                    stitcher.append(frames[index], dy: dy)
                    dys.append(dy)
                }
            }
            let composed = stitcher.compose()
            var report: [String: Any] = [
                "frames": frames.count,
                "dys": dys,
                "stitchedHeight": stitcher.totalHeight,
                "expectedHeight": viewport + 250 * (frames.count - 1)
            ]
            if let composed {
                let url = output.appendingPathComponent("scroll-stitch.png")
                if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, composed, nil)
                    CGImageDestinationFinalize(destination)
                    report["png"] = url.path
                }
                report["composedSize"] = "\(composed.width)x\(composed.height)"
            }
            finish(report: report, output: output)
            return
        }

        if UserDefaults.standard.bool(forKey: "previewRecentStripTest") {
            RecentCapturesStripPresenter.shared.show()
            try? await Task.sleep(for: .milliseconds(1800))
            let url = output.appendingPathComponent("recent-strip.png")
            render(view: RecentCapturesStripPresenter.shared.panelForTesting?.contentView, to: url)
            report["recentStripPNG"] = url.path
            report["recentStripCount"] = RecentCapturesStripModel.shared.items.count
            report["recentStripThumbs"] = RecentCapturesStripModel.shared.thumbnails.count
            finish(report: report, output: output)
            return
        }

        guard let sampleURL = makeSampleCapture(in: output) else {
            finish(report: ["error": "could not create sample capture"], output: output)
            return
        }

        CaptureShelf.shared.showForTesting(url: sampleURL)
        // Start from the default corner so the drag below is not already
        // pinned against an edge by a position left over from an earlier run.
        PreviewPlacementStore.reset()
        CaptureShelfPresenter.shared.show(displayID: ActiveDisplayResolver.activeDisplayID())
        try? await Task.sleep(for: .milliseconds(1200))

        if let panel = CaptureShelfPresenter.shared.panel {
            report["panelFrame"] = frameString(panel.frame)
            report["panelVisible"] = panel.isVisible
            report["level"] = panel.level.rawValue
            report["ignoresMouseEvents"] = panel.ignoresMouseEvents
            report["styleMask"] = panel.styleMask.rawValue
        } else {
            report["panelFrame"] = "missing"
        }
        report["cardSize"] = sizeString(CaptureShelfPresenter.shared.previewCardSize)
        report["screenVisibleFrame"] = frameString(NSScreen.main?.visibleFrame ?? .zero)
        report["samplePixelSize"] = sizeString(samplePixelSize(at: sampleURL))

        renderPanel(to: output.appendingPathComponent("preview-rest.png"))
        report["restPNG"] = output.appendingPathComponent("preview-rest.png").path

        // Hover: warp the pointer onto the card and let AppKit deliver the
        // mouse-enter, then photograph the controls.
        if let frame = CaptureShelfPresenter.shared.panel?.frame {
            warpCursor(to: CGPoint(x: frame.midX, y: frame.midY))
            try? await Task.sleep(for: .milliseconds(700))
            renderPanel(to: output.appendingPathComponent("preview-hover.png"))
            report["hoverPNG"] = output.appendingPathComponent("preview-hover.png").path
        }

        // Move the preview and check it followed the drag exactly.
        let before = CaptureShelfPresenter.shared.panel?.frame ?? .zero
        CaptureShelfPresenter.shared.moveForTesting(by: CGSize(width: -300, height: -160))
        try? await Task.sleep(for: .milliseconds(300))
        let after = CaptureShelfPresenter.shared.panel?.frame ?? .zero
        let stored = PreviewPlacementStore.load()
        report["dragFrom"] = frameString(before)
        report["dragTo"] = frameString(after)
        report["dragDelta"] = sizeString(CGSize(width: after.minX - before.minX, height: after.minY - before.minY))
        report["dragOffset"] = stored.map { "\(Int($0.width)),\(Int($0.height))" } ?? "none"
        report["dragOffsetMatchesMove"] = stored.map {
            abs($0.width - (after.minX - before.minX)) < 1
                && abs($0.height - (after.minY - before.minY)) < 1
        } ?? false
        renderPanel(to: output.appendingPathComponent("preview-moved.png"))
        report["movedPNG"] = output.appendingPathComponent("preview-moved.png").path

        // Remembered for the next capture: hide, then show again.
        CaptureShelfPresenter.shared.panel?.orderOut(nil)
        CaptureShelfPresenter.shared.show(displayID: ActiveDisplayResolver.activeDisplayID())
        try? await Task.sleep(for: .milliseconds(500))
        report["restoredFrame"] = frameString(CaptureShelfPresenter.shared.panel?.frame ?? .zero)
        report["restoredMatchesDrag"] = (CaptureShelfPresenter.shared.panel?.frame.origin ?? .zero)
            .equalTo(after.origin)

        // Clamp: a huge drag must still leave the card fully on screen.
        CaptureShelfPresenter.shared.moveForTesting(by: CGSize(width: -10_000, height: -10_000))
        try? await Task.sleep(for: .milliseconds(250))
        if let frame = CaptureShelfPresenter.shared.panel?.frame, let visible = NSScreen.main?.visibleFrame {
            report["clampedFrame"] = frameString(frame)
            report["clampedInsideVisibleFrame"] = visible.insetBy(dx: 0.5, dy: 0.5).contains(frame)
        }

        // An area capture is a floating thumbnail again: it opens in the
        // chosen bottom corner, capped to the card size, not on the selection.
        PreviewPlacementStore.reset()
        let selection = CGRect(x: 220, y: 380, width: 900, height: 500)
        CaptureShelfPresenter.shared.show(
            displayID: ActiveDisplayResolver.activeDisplayID(),
            selection: selection
        )
        try? await Task.sleep(for: .milliseconds(400))
        if let frame = CaptureShelfPresenter.shared.panel?.frame,
           let visible = NSScreen.main?.visibleFrame {
            let expectedX = visible.maxX - frame.width - PreviewCardMetrics.screenMargin
            let expectedY = visible.minY + PreviewCardMetrics.screenMargin
            report["cornerFrame"] = frameString(frame)
            report["cornerPlacement"] = abs(frame.minX - expectedX) < 1
                && abs(frame.minY - expectedY) < 1
            report["cardCapped"] = frame.width <= 380 && frame.height <= 300
            renderPanel(to: output.appendingPathComponent("preview-corner.png"))
            report["cornerPNG"] = output.appendingPathComponent("preview-corner.png").path
        }

        // The scroll-opacity maths, on a synthesised wheel event (posting a
        // real one needs Accessibility access).
        if let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 2,
            wheel2: 0,
            wheel3: 0
        ), let event = NSEvent(cgEvent: cg) {
            report["scrollOpacity"] = [
                "deltaY": event.scrollingDeltaY,
                "precise": event.hasPreciseScrollingDeltas,
                "from50": PreviewOpacity.alpha(0.5, after: event),
                "clampedHigh": PreviewOpacity.alpha(1, after: event),
                "clampedLow": PreviewOpacity.alpha(0.15, after: event)
            ] as [String: Any]
        }

        await renderPinnedSample(to: output, report: &report)

        finish(report: report, output: output, hold: UserDefaults.standard.double(forKey: "previewSelfTestHold"))
    }

    /// Turns a captured page into a file name with the on-device pipeline.
    private static func runAutoNameTest(output: URL) async {
        let rect = CGRect(x: 260, y: 320, width: 460, height: 300)
        let window = ScrollSimulationWindow(rect: rect)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(700))
        guard let shot = await ScreenshotManager.shared.captureRect(rect) else {
            ScrollSimulationReport.write(["result": "no-capture"], to: output)
            exit(1)
        }
        window.orderOut(nil)

        var report: [String: Any] = [:]
        report["modelAvailable"] = CaptureLibraryAnalyzer.isModelAvailable
        report["name"] = await CaptureAutoNamer.fileName(for: shot) ?? "nil"
        report["sanitised"] = CaptureAutoNamer.sanitised("Invoices: Q4 / Dashboard*2026?")
        report["result"] = "ok"
        try? FileManager.default.removeItem(at: shot)
        ScrollSimulationReport.write(report, to: output)
        exit(0)
    }

    /// Exercises the resize maths: both axes must grow, aspect must hold and
    /// the frame must stay on screen.
    private static func runPinResizeTest(output: URL) async {
        let rect = CGRect(x: 300, y: 340, width: 400, height: 260)
        let window = ScrollSimulationWindow(rect: rect)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(500))
        guard let shot = await ScreenshotManager.shared.captureRect(rect),
              let original = PinnedScreenshotPresenter.shared.panelsForTesting.first ?? nil
                ?? { PinnedScreenshotPresenter.shared.pin(url: shot, at: rect); return PinnedScreenshotPresenter.shared.panelsForTesting.first }()
        else {
            ScrollSimulationReport.write(["result": "no-pin"], to: output)
            exit(1)
        }
        window.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(300))

        var report: [String: Any] = [:]
        report["start"] = frameString(original.frame)

        // A diagonal drag down-right: both axes ask for growth.
        PinnedScreenshotPresenter.shared.resizeForTesting(original, delta: CGSize(width: 90, height: -90))
        try? await Task.sleep(for: .milliseconds(200))
        report["grown"] = frameString(original.frame)
        report["grownAspect"] = String(format: "%.3f", original.frame.width / original.frame.height)

        // A drag up-left past the minimum: must clamp, keeping the aspect.
        PinnedScreenshotPresenter.shared.resizeForTesting(original, delta: CGSize(width: -2000, height: 2000))
        try? await Task.sleep(for: .milliseconds(200))
        report["shrunk"] = frameString(original.frame)
        report["shrunkAspect"] = String(format: "%.3f", original.frame.width / original.frame.height)
        report["onScreen"] = (NSScreen.main?.visibleFrame.contains(original.frame) ?? false)
        report["result"] = "ok"

        try? FileManager.default.removeItem(at: shot)
        ScrollSimulationReport.write(report, to: output)
        exit(0)
    }

    /// Three pins, closed one by one: the keyboard must stay on the pin stack
    /// in reverse order and only leave the app after the last one is gone.
    private static func runPinChainTest(output: URL) async {
        let rect = CGRect(x: 240, y: 300, width: 480, height: 300)
        let window = ScrollSimulationWindow(rect: rect)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(600))

        var report: [String: Any] = [:]
        guard let shot = await ScreenshotManager.shared.captureRect(rect) else {
            report["result"] = "no-capture"
            ScrollSimulationReport.write(report, to: output)
            exit(1)
        }
        window.orderOut(nil)

        var urls: [URL] = []
        for index in 0..<3 {
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("pin-chain-\(index)-\(UUID().uuidString).png")
            try? FileManager.default.copyItem(at: shot, to: copy)
            urls.append(copy)
            PinnedScreenshotPresenter.shared.pin(url: copy, at: rect)
            try? await Task.sleep(for: .milliseconds(350))
        }
        report["pinned"] = PinnedScreenshotPresenter.shared.panelsForTesting.count
        report["focusedAfterPinning"] = PinnedScreenshotPresenter.shared.isPinKeyWindow

        for step in 0..<3 {
            _ = PinnedScreenshotPresenter.shared.closeMostRecent()
            try? await Task.sleep(for: .milliseconds(300))
            report["activeFast\(step)"] = NSApp.isActive
            try? await Task.sleep(for: .milliseconds(900))
            report["remaining\(step)"] = PinnedScreenshotPresenter.shared.panelsForTesting.count
            report["focused\(step)"] = PinnedScreenshotPresenter.shared.isPinKeyWindow
            report["active\(step)"] = NSApp.isActive
            report["keyWindow\(step)"] = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil"
        }
        report["result"] = "ok"

        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: shot)
        ScrollSimulationReport.write(report, to: output)
        exit(0)
    }

    /// Drives the real scrolling session (overlays, HUD, live preview, export)
    /// against a tall test page that scrolls itself.
    private static func runScrollFlowTest(output: URL) async {
        let rect = CGRect(x: 240, y: 300, width: 480, height: 300)
        let folder = ScreendropPreferences.exportDirectory
        let before = newestPNG(in: folder)

        let window = ScrollSimulationWindow(rect: rect)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(700))

        // Reproduce the reported case: a pinned screenshot sits over the
        // region while the scrolling capture runs.
        var pinned = false
        if UserDefaults.standard.bool(forKey: "scrollPinOverlayTest"),
           let shot = await ScreenshotManager.shared.captureRect(rect) {
            PinnedScreenshotPresenter.shared.pin(url: shot, at: rect)
            try? await Task.sleep(for: .milliseconds(500))
            pinned = PinnedScreenshotPresenter.shared.panelsForTesting.contains { $0.isVisible }
        }

        UserDefaults.standard.set(true, forKey: "scrollAutoFinishTest")
        ScrollingCaptureController.shared.runProbe(rect: rect)

        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(350))
            window.scroll(by: 84)
        }
        try? await Task.sleep(for: .milliseconds(3000))
        window.orderOut(nil)
        UserDefaults.standard.removeObject(forKey: "scrollAutoFinishTest")

        var report: [String: Any] = [
            "folder": folder.path,
            "before": before?.lastPathComponent ?? "none",
            "pinOverlay": pinned,
            "pinRestored": PinnedScreenshotPresenter.shared.panelsForTesting.contains { $0.isVisible }
        ]
        if let saved = newestPNG(in: folder), saved != before {
            report["saved"] = saved.path
            // Reproduce the post-capture ordering: pin first, preview card
            // after. The pin must still own the keyboard.
            PinnedScreenshotPresenter.shared.pin(url: saved, at: rect)
            try? await Task.sleep(for: .milliseconds(300))
            CaptureShelfPresenter.shared.show(displayID: nil, selection: nil)
            try? await Task.sleep(for: .milliseconds(500))
            report["appActive"] = NSApp.isActive
            report["keyIsPin"] = PinnedScreenshotPresenter.shared.isPinKeyWindow
            report["keyWindow"] = String(describing: NSApp.keyWindow.map { type(of: $0) })

            if let source = CGImageSourceCreateWithURL(saved as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                report["size"] = "\(image.width)x\(image.height)"
                report["blank"] = ScrollStitcher.isBlank(image)
                if let url = try? Data(contentsOf: saved) {
                    let copy = output.appendingPathComponent("flow-result.png")
                    try? url.write(to: copy)
                }
            }
        } else {
            report["saved"] = "none"
        }
        if UserDefaults.standard.bool(forKey: "autoNameCaptures") {
            try? await Task.sleep(for: .seconds(10))
            report["shelfURL"] = CaptureShelf.shared.items.first?.url.lastPathComponent ?? "none"
            report["shelfSavedURL"] = CaptureShelf.shared.items.first?.savedURL?.lastPathComponent ?? "none"
            report["newestInFolder"] = newestPNG(in: folder)?.lastPathComponent ?? "none"
        }

        let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: output.appendingPathComponent("scroll-flow.json"))
        if let data, let text = String(data: data, encoding: .utf8) { print("scrollFlow \(text)") }
        exit(report["saved"] as? String == "none" ? 1 : 0)
    }

    private static func newestPNG(in folder: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return items
            .filter { $0.pathExtension.lowercased() == "png" }
            .max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a < b
            }
    }

    // MARK: Helpers

    /// The pinned window uses the same compact controls; photograph it too.
    private static func renderPinnedSample(to folder: URL, report: inout [String: Any]) async {
        let previewFrame = CaptureShelfPresenter.shared.panel?.frame
        PinnedScreenshotPresenter.shared.pin(
            url: folder.appendingPathComponent("preview-selftest-sample.png"),
            at: previewFrame
        )
        try? await Task.sleep(for: .milliseconds(2200))
        guard let pin = PinnedScreenshotPresenter.shared.panelsForTesting.last else { return }
        report["pinFrame"] = frameString(pin.frame)
        if let previewFrame {
            let sameX = abs(pin.frame.minX - previewFrame.minX) < 1
            let sameY = abs(pin.frame.minY - previewFrame.minY) < 1
            report["pinMatchesPreview"] = sameX && sameY
        } else {
            report["pinMatchesPreview"] = false
        }
        let url = folder.appendingPathComponent("pin-hover.png")
        render(view: pin.contentView, to: url)
        report["pinPNG"] = url.path

        // A pin too small for the toolbar: the corner controls must still show.
        let smallSource = folder.appendingPathComponent("preview-selftest-sample.png")
        let smallCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("pin-small-\(UUID().uuidString).png")
        try? FileManager.default.copyItem(at: smallSource, to: smallCopy)
        PinnedScreenshotPresenter.shared.pin(
            url: smallCopy,
            at: CGRect(x: 420, y: 420, width: 72, height: 72)
        )
        try? await Task.sleep(for: .milliseconds(1600))
        if let small = PinnedScreenshotPresenter.shared.panelsForTesting.first(where: { $0.frame.width < 120 }) {
            let smallURL = folder.appendingPathComponent("pin-small.png")
            render(view: small.contentView, to: smallURL)
            report["smallPinPNG"] = smallURL.path
            report["smallPinFrame"] = frameString(small.frame)

            // Growing it must reveal the full toolbar again.
            PinnedScreenshotPresenter.shared.resizeForTesting(small, delta: CGSize(width: 260, height: -260))
            try? await Task.sleep(for: .milliseconds(700))
            let grownURL = folder.appendingPathComponent("pin-small-grown.png")
            render(view: small.contentView, to: grownURL)
            report["grownPinPNG"] = grownURL.path
            report["grownPinFrame"] = frameString(small.frame)
            if !UserDefaults.standard.bool(forKey: "previewKeepPin") {
                small.orderOut(nil)
            }
        }
        if !UserDefaults.standard.bool(forKey: "previewKeepPin") {
            pin.orderOut(nil)
        }
    }

    private static func finish(report: [String: Any], output: URL, hold: Double = 0) {
        let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let reportURL = output.appendingPathComponent("preview-selftest.json")
        try? json?.write(to: reportURL)
        if let json, let text = String(data: json, encoding: .utf8) {
            print("previewSelfTest \(text)")
        }
        print("previewSelfTestReport \(reportURL.path)")
        if hold > 0 {
            // Give an external screencapture time to photograph the card on
            // the desktop, then exit.
            Thread.sleep(forTimeInterval: hold)
        }
        exit(0)
    }

    private static func renderPanel(to url: URL) {
        render(view: CaptureShelfPresenter.shared.panel?.contentView, to: url)
    }

    private static func render(view: NSView?, to url: URL) {
        guard let view,
              view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    /// Screen point (AppKit coordinates, y up) to a Core Graphics warp point
    /// (y down from the top of the primary display).
    private static func warpCursor(to point: CGPoint) {
        guard let primary = NSScreen.screens.first else { return }
        CGWarpMouseCursorPosition(
            CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        )
    }

    private static func frameString(_ rect: CGRect) -> String {
        "\(Int(rect.origin.x.rounded())),\(Int(rect.origin.y.rounded())) \(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }

    private static func sizeString(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    private static func samplePixelSize(at url: URL) -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return .zero }
        return CGSize(width: width, height: height)
    }

    /// A Retina-sized sample that looks like a screenshot of a document, so
    /// the card's proportions and contrast are realistic.
    private static func makeSampleCapture(in folder: URL) -> URL? {
        let size = CGSize(width: 1440, height: 900)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.98, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.16, alpha: 1).setFill()
        NSRect(x: 0, y: 740, width: size.width, height: 160).fill()
        NSColor(calibratedWhite: 1, alpha: 0.9).setFill()
        NSRect(x: 64, y: 790, width: 420, height: 46).fill()
        NSColor(calibratedRed: 0.22, green: 0.42, blue: 0.95, alpha: 1).setFill()
        NSRect(x: 64, y: 600, width: 300, height: 58).fill()
        NSColor(calibratedWhite: 0.6, alpha: 1).setFill()
        for index in 0..<7 {
            NSRect(x: 64, y: 520 - CGFloat(index) * 52, width: 780 - CGFloat(index) * 40, height: 20).fill()
        }
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        NSRect(x: 980, y: 120, width: 390, height: 520).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        let url = folder.appendingPathComponent("preview-selftest-sample.png")
        try? png.write(to: url)
        return url
    }
}

private extension CGPoint {
    func equalTo(_ other: CGPoint) -> Bool {
        abs(x - other.x) < 1 && abs(y - other.y) < 1
    }
}
#endif
