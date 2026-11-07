//
//  BrowserContentLocator.swift
//  Screendrop
//
//  Finds the page area of a browser window: the tab's web content without the
//  tab strip, toolbar, bookmarks bar or side panels. Browsers draw all of that
//  into one window, so ScreenCaptureKit can only see the whole window; the
//  page's own rectangle comes from the Accessibility tree, where every major
//  engine (Chromium, WebKit, Gecko) exposes it as an `AXWebArea`. Captures
//  then crop the window to it with `SCStreamConfiguration.sourceRect`, which
//  for a window filter is in window-local points with a top-left origin.
//

import AppKit
import ApplicationServices
import CoreGraphics

/// A browser window and where its page sits.
nonisolated struct BrowserContent: Sendable, Equatable {
    let windowID: CGWindowID
    let processID: pid_t
    let windowTitle: String?
    /// Global Quartz coordinates (top-left origin), like `SCWindow.frame`.
    let windowFrame: CGRect
    /// Global Quartz coordinates (top-left origin).
    let contentFrame: CGRect

    /// The page inside the window, in window-local points with a top-left
    /// origin: the space `SCStreamConfiguration.sourceRect` uses for a
    /// window filter.
    var rectInWindow: CGRect {
        contentFrame
            .offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
            .intersection(CGRect(origin: .zero, size: windowFrame.size))
            .integral
    }

    /// The page in AppKit's global space (bottom-left origin), for overlays.
    var appKitContentFrame: CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: contentFrame.minX,
            y: primaryHeight - contentFrame.maxY,
            width: contentFrame.width,
            height: contentFrame.height
        )
    }

    var captureSource: CaptureSource {
        let app = NSRunningApplication(processIdentifier: processID)
        return CaptureSource(
            bundleIdentifier: app?.bundleIdentifier,
            appName: app?.localizedName ?? "Browser",
            windowTitle: windowTitle
        )
    }
}

@MainActor
enum BrowserContentLocator {
    /// Pages smaller than this are side panels or popups, not a tab.
    private static let minimumContentSize = CGSize(width: 120, height: 80)
    /// An unresponsive app must never stall a capture or the picker.
    private static let messagingTimeout: Float = 0.25
    /// Bounds the tree walk; a browser's page sits well inside these.
    private static let maximumDepth = 16
    private static let maximumVisitedElements = 1_500

    /// Chromium builds its Accessibility tree lazily. Asking once per process
    /// is enough; asking again would only repeat the wake-up.
    private static var enabledProcesses: Set<pid_t> = []

    // MARK: Permission

    static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    /// Reading another app's page area needs Accessibility access. Without
    /// it, explain why and route the user to the right Settings pane.
    static func ensureAccessibilityAccess() -> Bool {
        if AXIsProcessTrusted() { return true }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { return true }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility permission needed"
        alert.informativeText = """
        To capture just a browser tab, Screendrop reads where the page sits \
        inside the browser window. Allow Screendrop under Privacy & Security > \
        Accessibility, then try again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    static func presentNoBrowserFound() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "No browser tab found"
        alert.informativeText = """
        Bring the browser window you want to capture to the front, then try \
        again. Chrome, Safari, Arc, Edge, Brave and Firefox are supported.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Lookup

    /// The page of the given window, waking the browser's Accessibility tree
    /// and retrying briefly if it isn't built yet.
    static func content(
        windowID: CGWindowID,
        processID: pid_t,
        windowFrame: CGRect,
        windowTitle: String? = nil
    ) async -> BrowserContent? {
        for attempt in 0..<4 {
            if let content = locate(
                windowID: windowID,
                processID: processID,
                windowFrame: windowFrame,
                windowTitle: windowTitle
            ) {
                return content
            }
            if attempt == 0, !wakeAccessibilityTree(processID: processID) { return nil }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return nil
    }

    /// The frontmost browser page on screen: the frontmost app's windows
    /// first, then everything else front to back.
    static func frontmostContent() async -> BrowserContent? {
        let windows = onScreenWindows()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ordered = windows.filter { $0.processID == frontmostPID }
            + windows.filter { $0.processID != frontmostPID }

        // Cheap pass first, so an already-awake browser behind a
        // non-browser front window wins without waking anything.
        for window in ordered.prefix(8) {
            if let content = locate(
                windowID: window.windowID,
                processID: window.processID,
                windowFrame: window.frame,
                windowTitle: window.title
            ) {
                return content
            }
        }
        for window in ordered.prefix(8) where isLikelyBrowser(processID: window.processID) {
            if let content = await self.content(
                windowID: window.windowID,
                processID: window.processID,
                windowFrame: window.frame,
                windowTitle: window.title
            ) {
                return content
            }
        }
        return nil
    }

    /// Finds the same page again at the window's current position, for a
    /// window that may have moved or resized since it was first found.
    static func relocate(_ content: BrowserContent) -> BrowserContent? {
        guard let frame = currentWindowFrame(of: content.windowID) else { return nil }
        return locate(
            windowID: content.windowID,
            processID: content.processID,
            windowFrame: frame,
            windowTitle: content.windowTitle
        )
    }

    static func currentWindowFrame(of windowID: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// A synchronous lookup with no retry, for tracking a page that was
    /// already found once (its tree is awake).
    static func locate(
        windowID: CGWindowID,
        processID: pid_t,
        windowFrame: CGRect,
        windowTitle: String? = nil
    ) -> BrowserContent? {
        guard AXIsProcessTrusted(), processID != getpid() else { return nil }

        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        guard let axWindow = matchingWindow(in: application, frame: windowFrame) else { return nil }

        let windowBounds = CGRect(origin: windowFrame.origin, size: windowFrame.size)
        guard let page = largestWebArea(in: axWindow, within: windowBounds) else { return nil }

        let title = windowTitle ?? stringValue(axWindow, kAXTitleAttribute)
        return BrowserContent(
            windowID: windowID,
            processID: processID,
            windowTitle: title?.isEmpty == false ? title : nil,
            windowFrame: windowFrame,
            contentFrame: page
        )
    }

    // MARK: Accessibility tree

    /// Accessibility windows carry no `CGWindowID` in public API, so match on
    /// the frame, which both report in the same top-left global space.
    private static func matchingWindow(in application: AXUIElement, frame: CGRect) -> AXUIElement? {
        guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let scored = windows.compactMap { window -> (AXUIElement, CGFloat)? in
            guard let windowFrame = frameValue(window) else { return nil }
            let distance = abs(windowFrame.minX - frame.minX) + abs(windowFrame.minY - frame.minY)
                + abs(windowFrame.width - frame.width) + abs(windowFrame.height - frame.height)
            return (window, distance)
        }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= 8 else { return nil }
        return best.0
    }

    /// Breadth-first, stopping at each web area: nested ones are iframes.
    /// Of the top-level web areas (the page, and in Chromium any side panel
    /// or docked DevTools), the largest is the tab.
    private static func largestWebArea(in window: AXUIElement, within bounds: CGRect) -> CGRect? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        var best: CGRect?

        while index < queue.count, index < maximumVisitedElements {
            let (element, depth) = queue[index]
            index += 1

            if stringValue(element, kAXRoleAttribute) == "AXWebArea" {
                if let frame = frameValue(element)?.intersection(bounds),
                   !frame.isNull,
                   frame.width >= minimumContentSize.width,
                   frame.height >= minimumContentSize.height,
                   frame.width * frame.height > (best.map { $0.width * $0.height } ?? 0) {
                    best = frame
                }
                continue
            }

            guard depth < maximumDepth,
                  let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return best
    }

    /// Chromium-based browsers only build their tree once an assistive app
    /// asks for it. `AXManualAccessibility` is the switch they honor that
    /// leaves window animations alone (`AXEnhancedUserInterface` does not).
    /// Returns false when the app is not one worth waiting on.
    private static func wakeAccessibilityTree(processID: pid_t) -> Bool {
        guard isLikelyBrowser(processID: processID) else { return false }
        guard !enabledProcesses.contains(processID) else { return true }
        enabledProcesses.insert(processID)
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return true
    }

    /// Browsers declare they open web URLs. This only gates the slow path
    /// (waking a tree and waiting); a page found on the fast path counts
    /// whatever app it's in.
    private static func isLikelyBrowser(processID: pid_t) -> Bool {
        guard let bundleURL = NSRunningApplication(processIdentifier: processID)?.bundleURL,
              let bundle = Bundle(url: bundleURL),
              let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            return false
        }
        return urlTypes.contains { type in
            let schemes = type["CFBundleURLSchemes"] as? [String] ?? []
            return schemes.contains { $0.caseInsensitiveCompare("https") == .orderedSame }
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func stringValue(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func frameValue(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    // MARK: Window list

    private struct OnScreenWindow {
        let windowID: CGWindowID
        let processID: pid_t
        let title: String?
        let frame: CGRect
    }

    /// Ordinary app windows front to back, Quartz frames.
    private static func onScreenWindows() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = getpid()
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= minimumContentSize.width,
                  bounds.height >= minimumContentSize.height else { return nil }
            let title = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return OnScreenWindow(
                windowID: CGWindowID(number.uint32Value),
                processID: pid,
                title: title?.isEmpty == false ? title : nil,
                frame: bounds
            )
        }
    }
}
