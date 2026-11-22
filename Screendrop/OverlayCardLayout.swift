//
//  OverlayCardLayout.swift
//  Screendrop
//
//  Describes which actions appear on the floating preview card and where.
//  The card has four corner slots (each holding a single action rendered as a
//  circular icon button) and a center column (an ordered list of actions
//  rendered as labelled pills). Actions can also be hidden.
//
//  All positions are user-customisable from Settings → Capture Cards. The
//  layout is persisted as JSON in UserDefaults via `OverlayCardLayoutStore`;
//  its keys must stay stable so saved layouts keep loading.
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

extension OverlayCardCorner {
    var title: String {
        switch self {
        case .topLeading: "Top left"
        case .topTrailing: "Top right"
        case .bottomLeading: "Bottom left"
        case .bottomTrailing: "Bottom right"
        }
    }
}

/// One place on the card an action can sit: a corner, or a position in the
/// center column. `center(center.count)` is the empty slot after the last
/// center action, while there is room.
enum OverlayCardSlot: Hashable {
    case corner(OverlayCardCorner)
    case center(Int)
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
    /// Actions that are not on the card. Derived by `normalized()`; stored
    /// only because saved layouts carry it.
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

    func action(in slot: OverlayCardSlot) -> OverlayCardAction? {
        switch slot {
        case .corner(let corner): action(at: corner)
        case .center(let index): center.indices.contains(index) ? center[index] : nil
        }
    }

    /// Where `action` sits on the card, or nil when it isn't on it.
    func slot(of action: OverlayCardAction) -> OverlayCardSlot? {
        for corner in OverlayCardCorner.allCases where self.action(at: corner) == action {
            return .corner(corner)
        }
        return center.firstIndex(of: action).map { .center($0) }
    }

    var hasRoomInCenter: Bool { center.count < Self.centerCapacity }

    // MARK: - Mutations

    mutating func setCorner(_ corner: OverlayCardCorner, _ action: OverlayCardAction?) {
        switch corner {
        case .topLeading: topLeading = action
        case .topTrailing: topTrailing = action
        case .bottomLeading: bottomLeading = action
        case .bottomTrailing: bottomTrailing = action
        }
    }

    /// Puts `action` in `slot`. If the action was already on the card, the
    /// slot's previous action takes its old place, so the two swap; if it
    /// wasn't, the previous action comes off the card.
    mutating func assign(_ action: OverlayCardAction, to slot: OverlayCardSlot) {
        // Work on the center as fixed positions, so moving an action out of
        // it never shifts the index of the slot it's moving to.
        var slots: [OverlayCardAction?] = center
        if case .center(let index) = slot, index >= slots.count {
            slots.append(nil)
        }

        func get(_ slot: OverlayCardSlot) -> OverlayCardAction? {
            switch slot {
            case .corner(let corner): self.action(at: corner)
            case .center(let index): slots.indices.contains(index) ? slots[index] : nil
            }
        }

        func put(_ slot: OverlayCardSlot, _ value: OverlayCardAction?) {
            switch slot {
            case .corner(let corner): setCorner(corner, value)
            case .center(let index): if slots.indices.contains(index) { slots[index] = value }
            }
        }

        let previous = get(slot)
        if let origin = self.slot(of: action) {
            guard origin != slot else { return }
            put(origin, previous)
        }
        put(slot, action)
        center = slots.compactMap { $0 }
        self = normalized()
    }

    /// Takes whatever is in `slot` off the card.
    mutating func clear(_ slot: OverlayCardSlot) {
        switch slot {
        case .corner(let corner): setCorner(corner, nil)
        case .center(let index): if center.indices.contains(index) { center.remove(at: index) }
        }
        self = normalized()
    }

    /// Puts `action` in the center column at `index`, counted among the
    /// other center actions (so for an action already in the center, this
    /// reorders it). Does nothing when the column is full and the action
    /// isn't already in it.
    mutating func insertIntoCenter(_ action: OverlayCardAction, at index: Int) {
        switch slot(of: action) {
        case .center(let current):
            center.remove(at: current)
        case .corner(let corner):
            guard hasRoomInCenter else { return }
            setCorner(corner, nil)
        case nil:
            guard hasRoomInCenter else { return }
        }
        center.insert(action, at: min(max(index, 0), center.count))
        self = normalized()
    }

    /// Takes `action` off the card, wherever it is.
    mutating func takeOff(_ action: OverlayCardAction) {
        if let slot = slot(of: action) { clear(slot) }
    }

    /// Moves a center action up (`-1`) or down (`1`) the column.
    mutating func moveCenter(at index: Int, by offset: Int) {
        let target = index + offset
        guard center.indices.contains(index), center.indices.contains(target) else { return }
        center.swapAt(index, target)
    }

    /// Ensures every action appears at most once on the card and the center
    /// holds no more than `centerCapacity`; everything else, including
    /// actions added in a newer build, is off the card.
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
        result.center = Array(center.filter { seen.insert($0).inserted }.prefix(Self.centerCapacity))
        let placed = Set(
            [result.topLeading, result.topTrailing, result.bottomLeading, result.bottomTrailing]
                .compactMap { $0 } + result.center
        )
        result.hidden = OverlayCardAction.allCases.filter { !placed.contains($0) }
        return result
    }
}
