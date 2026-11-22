//
//  OverlayCardEditor.swift
//  Screendrop
//
//  Settings → Capture Cards → Card Actions. A capture card at its real size
//  over a sample screenshot, drawn with the card's own chips. Every button
//  on it is a menu: click one to swap it for another action,
//  move it, or take it off the card. Empty corners, and the spare middle slot
//  while there's room, show a dashed "+" to add one. Edits go straight to
//  `OverlayCardLayoutStore`, which the live cards read.
//

import AppKit
import SwiftUI

struct OverlayCardEditor: View {
    @State private var store = OverlayCardLayoutStore.shared
    @State private var cloud = CloudCredentialStore.shared
    @State private var kind: PreviewMediaKind = .image

    private var layout: OverlayCardLayout { store.layout }

    var body: some View {
        VStack(spacing: Space.xl) {
            SettingsSegmented(
                options: [PreviewMediaKind.image, .video],
                selection: $kind,
                title: { $0 == .image ? "Screenshot" : "Recording" }
            )

            card

            HStack(alignment: .center, spacing: Space.l) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                SettingsButton("Restore Defaults") {
                    withAnimation(.morphIfAllowed) { store.reset() }
                }
                .disabled(store.isDefault)
            }
        }
        .padding(.vertical, Space.m)
    }

    private var caption: String {
        var lines = ["Click a button to change it. Every action is also in a card's right-click menu."]
        if kind == .video {
            lines.append("Pin and Compress only appear on screenshots.")
        }
        if !cloud.isConfigured {
            lines.append("Upload appears once Cloud is set up.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Card

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: CaptureShelfMetrics.cardRadius, style: .continuous)

        return ZStack {
            SampleCapture()

            ForEach(OverlayCardCorner.allCases) { corner in
                slotButton(.corner(corner))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                    .padding(CaptureShelfMetrics.controlInset)
            }

            VStack(spacing: CaptureShelfMetrics.centerButtonSpacing) {
                ForEach(layout.center.indices, id: \.self) { index in
                    slotButton(.center(index))
                }
                if layout.hasRoomInCenter {
                    slotButton(.center(layout.center.count))
                }
            }
        }
        .frame(width: CaptureShelfMetrics.cardSize.width, height: CaptureShelfMetrics.cardSize.height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Palette.strongHairline, lineWidth: 1) }
        .motion(.morphQuick, value: layout)
        .motion(.morphQuick, value: kind)
    }

    private func slotButton(_ slot: OverlayCardSlot) -> some View {
        CardSlotMenu(
            slot: slot,
            action: layout.action(in: slot),
            kind: kind,
            isAvailable: layout.action(in: slot).map(isAvailable) ?? true
        ) {
            menuItems(for: slot)
        }
    }

    /// Mirrors the live card, which leaves out actions that can't apply.
    private func isAvailable(_ action: OverlayCardAction) -> Bool {
        switch action {
        case .pin, .compress: kind == .image
        case .upload: cloud.isConfigured
        default: true
        }
    }

    // MARK: - Menus

    @ViewBuilder
    private func menuItems(for slot: OverlayCardSlot) -> some View {
        let current = layout.action(in: slot)
        let offCard = OverlayCardAction.allCases.filter { layout.slot(of: $0) == nil }
        let elsewhere = OverlayCardAction.allCases.filter {
            guard let other = layout.slot(of: $0) else { return false }
            return other != slot
        }

        if !offCard.isEmpty {
            Section(current == nil ? "Add" : "Replace With") {
                ForEach(offCard) { item($0, into: slot) }
            }
        }

        if !elsewhere.isEmpty {
            Section(current == nil ? "Move Here" : "Swap With") {
                ForEach(elsewhere) { item($0, into: slot) }
            }
        }

        if current != nil {
            if case .center(let index) = slot, layout.center.count > 1 {
                Divider()
                Button("Move Up") { edit { $0.moveCenter(at: index, by: -1) } }
                    .disabled(index == 0)
                Button("Move Down") { edit { $0.moveCenter(at: index, by: 1) } }
                    .disabled(index == layout.center.count - 1)
            }
            Divider()
            Button("Remove from Card") { edit { $0.clear(slot) } }
        }
    }

    private func item(_ action: OverlayCardAction, into slot: OverlayCardSlot) -> some View {
        Button {
            edit { $0.assign(action, to: slot) }
        } label: {
            Label(action.label(for: kind), systemImage: action.symbol(for: kind))
        }
    }

    private func edit(_ change: (inout OverlayCardLayout) -> Void) {
        withAnimation(.morphIfAllowed) { change(&store.layout) }
    }
}

// MARK: - Slot

/// One place on the preview card: the action's chip, or a dashed "+" when
/// the place is empty. Clicking it opens `menu`.
private struct CardSlotMenu<MenuItems: View>: View {
    let slot: OverlayCardSlot
    let action: OverlayCardAction?
    let kind: PreviewMediaKind
    let isAvailable: Bool
    @ViewBuilder let menu: () -> MenuItems

    @State private var isHovered = false

    private var isCorner: Bool {
        if case .corner = slot { return true }
        return false
    }

    private var width: CGFloat {
        isCorner ? CaptureShelfMetrics.cornerButtonSize : CaptureShelfMetrics.centerButtonWidth
    }

    var body: some View {
        Menu {
            menu()
        } label: {
            face
                .overlay {
                    // A focus-style ring while the pointer is over it. Capsules
                    // stay concentric at any inset.
                    Capsule()
                        .strokeBorder(Palette.accent, lineWidth: 2)
                        .padding(-3)
                        .opacity(isHovered ? 1 : 0)
                }
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .motion(.hover, value: isHovered)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var face: some View {
        if let action {
            ShelfChip(width: width, isEnabled: isAvailable) {
                if isCorner {
                    Image(systemName: action.symbol(for: kind))
                        .font(.system(size: 10.5, weight: .bold))
                } else {
                    Text(action.label(for: kind))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        } else {
            let height: CGFloat = isCorner ? width : 26
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: width, height: height)
                .overlay {
                    Capsule()
                        .strokeBorder(.white.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
        }
    }

    private var place: String {
        switch slot {
        case .corner(let corner): "\(corner.title) corner"
        case .center: "Middle"
        }
    }

    private var help: String {
        guard let action else { return "Add an action" }
        return isAvailable ? action.detail : "\(action.label(for: kind)) doesn't appear here"
    }

    private var accessibilityLabel: String {
        "\(place): \(action?.label(for: kind) ?? "empty")"
    }
}

// MARK: - Sample capture

/// A made-up screenshot of an app window, frosted and dimmed the way the live
/// card treats the real one under its buttons.
private struct SampleCapture: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.97, green: 0.97, blue: 0.98)
            HStack(spacing: 0) {
                Color(red: 0.86, green: 0.89, blue: 0.95)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 8) {
                    bar(width: 70, opacity: 0.5)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.55, green: 0.7, blue: 1.0))
                        .frame(height: 40)
                    bar(width: 90, opacity: 0.35)
                    bar(width: 60, opacity: 0.35)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // One opaque layer first, so the opaque blur samples a filled image
        // edge to edge rather than the gaps between shapes.
        .drawingGroup()
        .blur(radius: 6, opaque: true)
        .overlay(Color.black.opacity(0.16))
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat, opacity: Double) -> some View {
        Capsule()
            .fill(Color.black.opacity(opacity))
            .frame(width: width, height: 5)
    }
}

private extension OverlayCardCorner {
    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}
