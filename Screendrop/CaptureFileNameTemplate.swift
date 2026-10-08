//
//  CaptureFileNameTemplate.swift
//  Screendrop
//

import Foundation

/// The dynamic values a file name template can draw on for one capture.
struct CaptureNamingContext {
    var date = Date()
    /// Name of the app that owns the captured window, when known.
    var appName: String?
    /// Title of the captured window, when known.
    var windowTitle: String?
    /// Value for the `%i` token. Nil leaves the token empty.
    var sequenceNumber: Int?
}

/// Renders capture file names from a user-editable template such as
/// `%t-%y-%m-%d`. Tokens are `%` followed by a single letter; anything else
/// is copied through verbatim. A token with no value (an unknown window
/// title, for example) disappears along with the separator that follows it,
/// so `%t-%y` on a capture without a title still yields `2026`.
enum CaptureFileNameTemplate {
    static let defaultTemplate = "Screendrop_%y-%m-%d-%H-%M-%S"

    enum Token: Character, CaseIterable, Identifiable {
        case year = "y"
        case month = "m"
        case monthName = "n"
        case day = "d"
        case weekday = "w"
        case windowTitle = "t"
        case appName = "a"
        case hour = "H"
        case minute = "M"
        case second = "S"
        case meridiem = "p"
        case random = "r"
        case sequence = "i"

        var id: Character { rawValue }

        var placeholder: String { "%\(rawValue)" }

        var title: String {
            switch self {
            case .year: "Year"
            case .month: "Month (numeric)"
            case .monthName: "Month (name)"
            case .day: "Day"
            case .weekday: "Day of week"
            case .windowTitle: "Window title"
            case .appName: "App name"
            case .hour: "Hour"
            case .minute: "Minutes"
            case .second: "Seconds"
            case .meridiem: "AM/PM"
            case .random: "Random characters"
            case .sequence: "Auto-increment"
            }
        }
    }

    /// Characters that separate tokens and get dropped next to an empty one.
    private static let separators = CharacterSet(charactersIn: "-_. ")
    /// Keeps the stem comfortably inside the 255-byte file name limit even
    /// with multi-byte window titles and a numbered-copy suffix appended.
    private static let maximumStemLength = 180

    static func usesSequenceNumber(_ template: String) -> Bool {
        segments(of: template).contains { segment in
            if case .token(.sequence) = segment { return true }
            return false
        }
    }

    /// The file name stem (no extension) for `context`. A template that
    /// renders to nothing at all falls back to the default template so a
    /// capture is never written as a dot file or an empty name.
    static func stem(
        template: String,
        context: CaptureNamingContext,
        timeZone: TimeZone = .current
    ) -> String {
        let rendered = sanitize(render(template: template, context: context, timeZone: timeZone))
        if rendered.isEmpty, template != defaultTemplate {
            return stem(template: defaultTemplate, context: context, timeZone: timeZone)
        }
        return rendered
    }

    // MARK: - Parsing

    private enum Segment {
        case literal(String)
        case token(Token)
    }

    private static func segments(of template: String) -> [Segment] {
        var segments: [Segment] = []
        var literal = ""
        var iterator = template.makeIterator()

        while let character = iterator.next() {
            guard character == "%" else {
                literal.append(character)
                continue
            }
            guard let next = iterator.next() else {
                literal.append(character)
                break
            }
            if let token = Token(rawValue: next) {
                if !literal.isEmpty {
                    segments.append(.literal(literal))
                    literal = ""
                }
                segments.append(.token(token))
            } else {
                literal.append(character)
                literal.append(next)
            }
        }

        if !literal.isEmpty {
            segments.append(.literal(literal))
        }
        return segments
    }

    // MARK: - Rendering

    private static func render(template: String, context: CaptureNamingContext, timeZone: TimeZone) -> String {
        var output = ""
        var dropLeadingSeparators = false

        for segment in segments(of: template) {
            switch segment {
            case .literal(let text):
                if dropLeadingSeparators {
                    output.append(contentsOf: text.drop { $0.unicodeScalars.allSatisfy(separators.contains) })
                    dropLeadingSeparators = false
                } else {
                    output.append(text)
                }
            case .token(let token):
                let value = resolve(token, context: context, timeZone: timeZone)
                if value.isEmpty {
                    dropLeadingSeparators = true
                } else {
                    output.append(value)
                }
            }
        }

        return output
    }

    private static func resolve(_ token: Token, context: CaptureNamingContext, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: context.date)

        switch token {
        case .year:
            return String(format: "%04d", components.year ?? 0)
        case .month:
            return String(format: "%02d", components.month ?? 0)
        case .monthName:
            return formatted(context.date, pattern: "MMMM", timeZone: timeZone)
        case .day:
            return String(format: "%02d", components.day ?? 0)
        case .weekday:
            return formatted(context.date, pattern: "EEEE", timeZone: timeZone)
        case .windowTitle:
            return context.windowTitle ?? ""
        case .appName:
            return context.appName ?? ""
        case .hour:
            return String(format: "%02d", components.hour ?? 0)
        case .minute:
            return String(format: "%02d", components.minute ?? 0)
        case .second:
            return String(format: "%02d", components.second ?? 0)
        case .meridiem:
            return (components.hour ?? 0) < 12 ? "AM" : "PM"
        case .random:
            return randomCharacters(count: 6)
        case .sequence:
            return context.sequenceNumber.map(String.init) ?? ""
        }
    }

    private static func formatted(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(pattern)
        return formatter.string(from: date)
    }

    private static func randomCharacters(count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<count).map { _ in alphabet.randomElement()! })
    }

    // MARK: - Sanitizing

    /// Strips what a file system or Finder cannot show: control characters
    /// are removed, path separators become dashes, and the result is trimmed
    /// so a title that ends in a separator does not leave a dangling dash.
    private static func sanitize(_ stem: String) -> String {
        var cleaned = ""
        for scalar in stem.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                cleaned.append("-")
            } else if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                continue
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }

        let trimmed = cleaned.trimmingCharacters(in: separators.union(.whitespaces))
        return String(trimmed.prefix(maximumStemLength))
            .trimmingCharacters(in: separators.union(.whitespaces))
    }
}
