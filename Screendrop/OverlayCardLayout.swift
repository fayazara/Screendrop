//
//  OverlayCardLayout.swift
//  Screendrop
//
//  Describes which actions appear on the floating preview card and where.
//  The card has four corner slots (each holding a single action rendered as a
//  circular icon button) and a center column (an ordered list of actions
//  rendered as labelled pills). Actions can also be hidden.
//
//  All positions are user-customisable from the Overlay settings pane. The
//  layout is persisted as JSON in UserDefaults via `OverlayCardLayoutStore`.
//

import Foundation

/// Every action that can be placed on the preview card.
enum OverlayCardAction: String, CaseIterable, Codable, Identifiable {
    case copy
    case compress
    case save
    case pin
    case annotate
    case view
    case upload
    case delete
    case close

    var id: String { rawValue }

    /// SF Symbol for this action. `annotate` shows scissors for recordings.
    func symbol(for kind: PreviewMediaKind = .image) -> String {
        switch self {
        case .copy: "doc.on.doc"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .save: "square.and.arrow.down"
        case .pin: "pin.fill"
        case .annotate: kind == .video ? "scissors" : "pencil.tip"
        case .view: "eye"
        case .upload: "cloud"
        case .delete: "trash"
        case .close: "xmark"
        }
    }

    /// Short label used for center pills and the editor. `annotate` becomes
    /// "Edit" for recordings.
    func label(for kind: PreviewMediaKind = .image) -> String {
        switch self {
        case .copy: "Copy"
        case .compress: "Compress"
        case .save: "Save"
        case .pin: "Pin"
        case .annotate: kind == .video ? "Edit" : "Annotate"
        case .view: "View"
        case .upload: "Upload"
        case .delete: "Delete"
        case .close: "Dismiss"
        }
    }

    /// Help/tooltip text for the live card.
    func help(for kind: PreviewMediaKind = .image) -> String {
        switch self {
        case .copy: "Copy to clipboard"
        case .compress: "Copy a compressed JPG"
        case .save: "Save to disk"
        case .pin: "Pin to screen"
        case .annotate: kind == .video ? "Edit recording" : "Annotate screenshot"
        case .view: "Quick Look"
        case .upload: "Upload to cloud"
        case .delete: kind == .video ? "Delete recording" : "Delete screenshot"
        case .close: "Dismiss preview"
        }
    }

    /// A one-line description shown in the editor.
    var detail: String {
        switch self {
        case .copy: "Copy the capture to the clipboard"
        case .compress: "Copy a smaller JPG to the clipboard"
        case .save: "Save the capture to your export folder"
        case .pin: "Pin the screenshot as a floating window"
        case .annotate: "Open the annotation / video editor"
        case .view: "Open a Quick Look preview"
        case .upload: "Upload to the cloud and copy a share link"
        case .delete: "Delete the file from disk"
        case .close: "Dismiss the preview (keeps the file)"
        }
    }
}

/// The four card corners.
enum OverlayCardCorner: String, CaseIterable, Codable, Identifiable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: String { rawValue }
}

/// A destination region in the card editor.
enum OverlayCardZone: Hashable {
    case corner(OverlayCardCorner)
    case center
    case tray
}

/// The full placement of every action on the card.
struct OverlayCardLayout: Codable, Equatable {
    /// Maximum number of actions allowed in the center column.
    static let centerCapacity = 3

    var topLeading: OverlayCardAction?
    var topTrailing: OverlayCardAction?
    var bottomLeading: OverlayCardAction?
    var bottomTrailing: OverlayCardAction?
    /// Ordered top-to-bottom list of center pills.
    var center: [OverlayCardAction]
    /// Actions that are not shown on the card.
    var hidden: [OverlayCardAction]

    /// Matches the original hard-coded card layout, with the new `view` action
    /// tucked away in the hidden tray so existing behaviour is unchanged.
    static let `default` = OverlayCardLayout(
        topLeading: .delete,
        topTrailing: .close,
        bottomLeading: .annotate,
        bottomTrailing: .upload,
        center: [.copy, .save, .pin],
        hidden: [.view, .compress]
    )

    // MARK: - Reads

    func action(at corner: OverlayCardCorner) -> OverlayCardAction? {
        switch corner {
        case .topLeading: topLeading
        case .topTrailing: topTrailing
        case .bottomLeading: bottomLeading
        case .bottomTrailing: bottomTrailing
        }
    }

    func zone(of action: OverlayCardAction) -> OverlayCardZone? {
        for corner in OverlayCardCorner.allCases where self.action(at: corner) == action {
            return .corner(corner)
        }
        if center.contains(action) { return .center }
        if hidden.contains(action) { return .tray }
        return nil
    }

    // MARK: - Mutations

    mutating func setCorner(_ corner: OverlayCardCorner, _ action: OverlayCardAction?) {
        switch corner {
        case .topLeading: topLeading = action
        case .topTrailing: topTrailing = action
        case .bottomLeading: bottomLeading = action
        case .bottomTrailing: bottomTrailing = action
        }
    }

    /// Detaches an action from wherever it currently lives.
    mutating func remove(_ action: OverlayCardAction) {
        for corner in OverlayCardCorner.allCases where self.action(at: corner) == action {
            setCorner(corner, nil)
        }
        center.removeAll { $0 == action }
        hidden.removeAll { $0 == action }
    }

    /// Moves `action` into `zone`. When dropping onto an occupied corner, the
    /// displaced action is relocated to `fallback` (typically the dragged
    /// action's origin) so it stays visible — i.e. a swap.
    mutating func place(
        _ action: OverlayCardAction,
        into zone: OverlayCardZone,
        centerIndex: Int? = nil,
        fallback: OverlayCardZone = .center
    ) {
        let origin = self.zone(of: action)
        remove(action)

        switch zone {
        case .corner(let corner):
            if let occupant = self.action(at: corner), occupant != action {
                setCorner(corner, nil)
                // Send the displaced action back to where the dragged one came
                // from, so corners feel like a swap rather than an eviction.
                place(occupant, into: origin ?? fallback)
            }
            setCorner(corner, action)
        case .center:
            let clamped = min(max(centerIndex ?? center.count, 0), center.count)
            center.insert(action, at: clamped)
        case .tray:
            hidden.append(action)
        }
    }

    /// Ensures every action appears exactly once. Unknown/duplicate entries are
    /// dropped and any action missing entirely (e.g. added in a newer build) is
    /// appended to the hidden tray.
    func normalized() -> OverlayCardLayout {
        var seen = Set<OverlayCardAction>()
        var result = OverlayCardLayout(
            topLeading: nil,
            topTrailing: nil,
            bottomLeading: nil,
            bottomTrailing: nil,
            center: [],
            hidden: []
        )

        func claim(_ action: OverlayCardAction?) -> OverlayCardAction? {
            guard let action, seen.insert(action).inserted else { return nil }
            return action
        }

        result.topLeading = claim(topLeading)
        result.topTrailing = claim(topTrailing)
        result.bottomLeading = claim(bottomLeading)
        result.bottomTrailing = claim(bottomTrailing)
        result.center = center.filter { seen.insert($0).inserted }
        result.hidden = hidden.filter { seen.insert($0).inserted }

        for action in OverlayCardAction.allCases where seen.insert(action).inserted {
            result.hidden.append(action)
        }

        // Enforce the center capacity, pushing any overflow into the tray.
        if result.center.count > Self.centerCapacity {
            let overflow = result.center.suffix(from: Self.centerCapacity)
            result.hidden.append(contentsOf: overflow)
            result.center = Array(result.center.prefix(Self.centerCapacity))
        }

        return result
    }
}
