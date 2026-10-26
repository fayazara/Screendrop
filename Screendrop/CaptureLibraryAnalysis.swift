//
//  CaptureLibraryAnalysis.swift
//  Screendrop
//

import AppKit

/// What a capture shows, as the Library files it. A fixed set, so the sidebar
/// stays short and the on-device model chooses rather than invents.
nonisolated enum CaptureCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case code, design, website, document, chat, email, data, error, receipt, social, media, settings, other

    var id: Self { self }

    var title: String {
        switch self {
        case .code: "Code"
        case .design: "Design"
        case .website: "Websites"
        case .document: "Documents"
        case .chat: "Conversations"
        case .email: "Email"
        case .data: "Charts & Data"
        case .error: "Errors"
        case .receipt: "Receipts & Orders"
        case .social: "Social"
        case .media: "Photos & Video"
        case .settings: "Settings"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .code: "apple.terminal.fill"
        case .design: "paintpalette"
        case .website: "globe"
        case .document: "doc.text"
        case .chat: "bubble.left.and.bubble.right"
        case .email: "envelope"
        case .data: "chart.bar"
        case .error: "exclamationmark.triangle"
        case .receipt: "receipt"
        case .social: "person.2"
        case .media: "photo.on.rectangle.angled"
        case .settings: "gearshape"
        case .other: "photo.stack"
        }
    }

    /// The meaning the model is given for each category.
    var guidance: String {
        switch self {
        case .code: "source code, terminals, IDEs, diffs, logs, developer tools"
        case .design: "UI designs, mockups, design tools, icons, typography, layouts"
        case .website: "web pages, landing pages, articles in a browser, search results"
        case .document: "documents, notes, PDFs, wikis, slides, long-form text"
        case .chat: "chat and messaging threads, comments, DMs"
        case .email: "email messages and inboxes"
        case .data: "spreadsheets, tables, charts, dashboards, analytics"
        case .error: "error messages, crash reports, warnings, failed builds, alerts"
        case .receipt: "receipts, invoices, orders, payments, bookings, tickets"
        case .social: "social media posts, profiles and feeds"
        case .media: "photos, video frames, artwork, maps, games"
        case .settings: "settings, preferences, system dialogs, configuration screens"
        case .other: "anything that fits none of the others"
        }
    }
}

/// One line of recognized text.
nonisolated struct CaptureTextLine: Codable, Sendable, Equatable {
    var text: String
    /// Normalized to the image, top-left origin. Nil for text read from a
    /// video frame other than the one the Library shows.
    var box: CGRect?
}

/// The lines of text in a capture, saved as an array of lines but held as
/// one string with each line's end and box. A Library's worth of captures
/// otherwise makes a small allocation for nearly every line, and the heap
/// those leave behind stays with the app long after they're freed.
nonisolated struct CaptureTextLines: Codable, Sendable, Equatable, RandomAccessCollection {
    /// Every line, joined by newlines.
    private(set) var text = ""
    /// Where each line ends in `text`, in UTF-8 bytes.
    private var ends: [UInt32] = []
    /// Each line's box as x, y, width and height; NaN for a line without
    /// one. Normalized coordinates don't need doubles.
    private var boxes: [Float] = []

    init() {}

    init(_ lines: [CaptureTextLine]) {
        text = lines.map(\.text).joined(separator: "\n")
        ends.reserveCapacity(lines.count)
        boxes.reserveCapacity(lines.count * 4)
        var offset = 0
        for line in lines {
            offset += line.text.utf8.count
            ends.append(UInt32(offset))
            let box = line.box
            boxes += box.map { [Float($0.minX), Float($0.minY), Float($0.width), Float($0.height)] } ?? [.nan, .nan, .nan, .nan]
            offset += 1
        }
    }

    init(from decoder: Decoder) throws {
        self.init(try [CaptureTextLine](from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        try Array(self).encode(to: encoder)
    }

    var startIndex: Int { 0 }
    var endIndex: Int { ends.count }

    subscript(position: Int) -> CaptureTextLine {
        let utf8 = text.utf8
        let start = position == 0 ? 0 : Int(ends[position - 1]) + 1
        let lower = utf8.index(utf8.startIndex, offsetBy: start)
        let upper = utf8.index(lower, offsetBy: Int(ends[position]) - start)
        let i = position * 4
        let box = boxes[i].isNaN ? nil : CGRect(x: CGFloat(boxes[i]), y: CGFloat(boxes[i + 1]),
                                                width: CGFloat(boxes[i + 2]), height: CGFloat(boxes[i + 3]))
        return CaptureTextLine(text: String(decoding: utf8[lower..<upper], as: UTF8.self), box: box)
    }
}

/// Everything the Library learns about a capture by looking at it. Stored
/// apart from the capture so the index can be rebuilt without touching it.
nonisolated struct CaptureAnalysis: Codable, Sendable, Equatable {
    enum Classifier: String, Codable, Sendable {
        /// Apple's on-device language model.
        case model
        /// App and keyword rules, used while the model is unavailable.
        case rules
    }

    /// Bump to re-analyze every capture after the pipeline changes.
    static let currentVersion = 1

    var id: String
    var version = Self.currentVersion
    /// The capture's thumbnail key: path plus modification date, so an edit
    /// re-reads the new pixels.
    var fingerprint: String
    var lines = CaptureTextLines()
    /// Spoken words from a recording's transcript, when it has one.
    var transcript: String?
    var category: CaptureCategory?
    /// A short description written by the model.
    var title: String?
    var keywords: [String] = []
    var classifier: Classifier?
    /// The model was available but gave no answer (guardrails, language), so
    /// the rules' category stands until the pipeline version changes.
    var modelDeclined = false
    var hasFeaturePrint = false

    var text: String { lines.text }
}

/// The fallback classifier: the source app first, then telltale words.
nonisolated enum CaptureCategoryRules {
    static func category(source: CaptureSource?, text: String, isVideo: Bool) -> CaptureCategory {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if hits(errorWords, in: folded) >= 2 { return .error }
        if hits(receiptWords, in: folded) >= 2, folded.range(of: #"[$€£¥₹]\s?\d"#, options: .regularExpression) != nil {
            return .receipt
        }
        if let category = appCategory(source) { return category }
        if hits(codeWords, in: folded) >= 3 { return .code }
        if isVideo { return .media }
        return folded.count > 400 ? .document : .other
    }

    private static func hits(_ words: [String], in text: String) -> Int {
        words.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
    }

    private static let errorWords = ["error", "exception", "failed", "fatal", "traceback", "stack trace", "crash", "warning:", "undefined"]
    private static let receiptWords = ["total", "subtotal", "invoice", "receipt", "order", "paid", "payment", "tax", "amount due"]
    private static let codeWords = ["func ", "return ", "import ", "const ", "let ", "class ", "def ", "=> ", "();", "{", "}"]

    private static func appCategory(_ source: CaptureSource?) -> CaptureCategory? {
        guard let source else { return nil }
        let id = source.bundleIdentifier?.lowercased() ?? ""
        let name = source.appName.lowercased()
        func matches(_ needles: [String]) -> Bool { needles.contains { id.contains($0) || name.contains($0) } }
        if matches(["xcode", "terminal", "iterm", "vscode", "visualstudio", "cursor", "ghostty", "zed", "jetbrains", "warp", "sublime", "nova", "tower", "fork", "github"]) { return .code }
        if matches(["figma", "sketch", "pixelmator", "photoshop", "illustrator", "affinity", "framer", "spline", "rive"]) { return .design }
        if matches(["slack", "messages", "ichat", "discord", "whatsapp", "telegram", "signal", "teams", "messenger"]) { return .chat }
        if matches(["mail", "outlook", "spark", "mimestream", "superhuman", "airmail"]) { return .email }
        if matches(["numbers", "excel", "tableplus", "sequel", "datagrip"]) { return .data }
        if matches(["pages", "word", "notes", "notion", "obsidian", "bear", "craft", "preview", "acrobat", "keynote", "powerpoint", "textedit"]) { return .document }
        if matches(["safari", "chrome", "firefox", "arc", "edge", "brave", "orion", "opera", "dia"]) { return .website }
        if matches(["photos", "quicktime", "music", "tv", "maps", "iina", "vlc"]) { return .media }
        if matches(["systempreferences", "systemsettings", "system settings"]) { return .settings }
        if matches(["twitter", "tweetbot", "ivory", "mastodon", "threads", "bluesky"]) { return .social }
        return appStoreCategory(id)
    }

    /// The category an app declares in its Info.plist, for apps the rules
    /// above don't name.
    private static func appStoreCategory(_ bundleIdentifier: String) -> CaptureCategory? {
        guard !bundleIdentifier.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let declared = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        else { return nil }
        switch declared.replacingOccurrences(of: "public.app-category.", with: "") {
        case "developer-tools": return .code
        case "graphics-design": return .design
        case "photography", "video", "music", "entertainment", "games": return .media
        case "social-networking": return .social
        case "productivity", "business", "reference", "education": return .document
        case "finance": return .data
        default: return nil
        }
    }
}
