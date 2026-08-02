//
//  RecordingBarChrome.swift
//  Screendrop
//
//  Shared chrome for the floating recording bar — its geometry, its tooltip
//  system and the control styles both of its modes are built from. The
//  pre-record picker and the in-session controls are the same bar with
//  different contents, not two bars that resemble each other, which is what
//  lets one morph into the other.
//

import SwiftUI

enum BarMetrics {
    static let height: CGFloat = 66
    static let cornerRadius: CGFloat = 16
    static let itemSpacing: CGFloat = 6
    static let horizontalPadding: CGFloat = 12

    /// Transparent slack below the bar so its drop shadow isn't clipped by
    /// the panel edge. The panel is positioned lower by exactly this much so
    /// the bar itself doesn't move.
    static let shadowSlack: CGFloat = 28

    /// The panel is a fixed size that both modes sit centred inside, so
    /// morphing between them never resizes the window — only the bar's own
    /// rounded rect animates. Wide enough for the widest mode plus the room a
    /// tooltip needs beyond the end controls.
    static let panelWidth: CGFloat = 820
    static var panelHeight: CGFloat { BarTooltip.reservedHeight + height + shadowSlack }

    static let fill = Color(white: 0.14).opacity(0.97)
    static let stroke = Color.white.opacity(0.14)
    /// A control that's off is dimmed, never shrunk — the target stays the
    /// same size whichever state it's in.
    static let inactiveTint = Color.white.opacity(0.35)

    /// The morph between modes. Enough travel to read as one bar changing
    /// shape rather than two bars swapping.
    static let modeChange = Animation.spring(response: 0.34, dampingFraction: 0.86)
}

// MARK: - Tooltips

/// Geometry and timing for the bar's own tooltips. macOS' native `.help()`
/// tooltip takes about a second to appear, which is far too slow for a bar
/// you're meant to scan and dismiss; these show in a fraction of that and,
/// once one has appeared, follow the pointer across the bar instantly.
enum BarTooltip {
    static let coordinateSpace = "recordingBar"
    static let pillHeight: CGFloat = 24
    /// Space between the top of the bar and the bottom of the pill.
    static let gap: CGFloat = 8
    /// Transparent slack the panel reserves above the bar for the pill and
    /// its shadow.
    static let reservedHeight: CGFloat = gap + pillHeight + 16

    static let showDelay = Duration.milliseconds(160)
    /// How long after leaving a control the bar stays "warm" — hover another
    /// control inside this window and its tooltip appears with no delay.
    static let warmWindow = Duration.milliseconds(500)
}

/// Stable identity per control, so the pill can glide between controls
/// instead of cross-fading in place.
enum BarTooltipID: String {
    case display
    case window
    case area
    case camera
    case microphone
    case systemAudio
    case teleprompter
    case timer
    case close

    case pauseResume
    case restart
    case stop
    case discard
}

struct BarTooltipTarget {
    var id: BarTooltipID
    var text: String
    var frame: CGRect
}

@Observable
final class BarTooltipModel {
    private(set) var visible: BarTooltipTarget?

    private var hovered: BarTooltipID?
    private var isWarm = false
    private var showTask: Task<Void, Never>?
    private var coolTask: Task<Void, Never>?

    func hover(id: BarTooltipID, text: String, frame: CGRect) {
        hovered = id
        showTask?.cancel()
        coolTask?.cancel()

        guard !isWarm else {
            visible = BarTooltipTarget(id: id, text: text, frame: frame)
            return
        }
        showTask = Task {
            try? await Task.sleep(for: BarTooltip.showDelay)
            guard !Task.isCancelled, hovered == id else { return }
            visible = BarTooltipTarget(id: id, text: text, frame: frame)
            isWarm = true
        }
    }

    /// Guarded on the item that's leaving: SwiftUI can deliver the new
    /// control's `onHover(true)` before the old one's `onHover(false)`, and
    /// an unguarded hide would blank the tooltip that just took over.
    func endHover(id: BarTooltipID) {
        guard hovered == id else { return }
        hovered = nil
        showTask?.cancel()
        visible = nil
        coolTask = Task {
            try? await Task.sleep(for: BarTooltip.warmWindow)
            guard !Task.isCancelled, hovered == nil else { return }
            isWarm = false
        }
    }

    /// Clicking a control means the user is done reading about it. Cut
    /// without a fade: the click already happened, and a pill dissolving
    /// after the fact reads as lag.
    func dismiss() {
        hovered = nil
        showTask?.cancel()
        withTransaction(Transaction(animation: nil)) {
            visible = nil
        }
    }
}

struct BarTooltipPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: BarTooltip.pillHeight)
            .background(Color(white: 0.16).opacity(0.98))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            // Fainter than the bar's own border: at pill scale that weight
            // reads as a hard outline rather than an edge highlight.
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            .transition(.opacity)
    }
}

private struct BarTooltipModifier: ViewModifier {
    let id: BarTooltipID
    let text: String
    let accessibility: String
    let model: BarTooltipModel

    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(BarTooltip.coordinateSpace))
            } action: {
                frame = $0
            }
            .onHover { isInside in
                if isInside {
                    model.hover(id: id, text: text, frame: frame)
                } else {
                    model.endHover(id: id)
                }
            }
            .accessibilityLabel(accessibility)
    }
}

extension View {
    /// `text` is what the pill shows — keep it short. `accessibility` carries
    /// the longer description for VoiceOver, where length costs nothing.
    func barTooltip(
        _ id: BarTooltipID,
        _ text: String,
        accessibility: String? = nil,
        model: BarTooltipModel
    ) -> some View {
        modifier(
            BarTooltipModifier(
                id: id,
                text: text,
                accessibility: accessibility ?? text,
                model: model
            )
        )
    }
}

// MARK: - Controls

/// The bar's primary control shape: icon over label, sized for a comfortable
/// pointer target rather than for the icon. Used bare as a `Menu` label and
/// wrapped by `BarActionButton` everywhere else.
struct BarActionLabel: View {
    let title: String
    let systemImage: String
    var tint: Color = .white

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .frame(height: 22)
            Text(title)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.3))
        .frame(width: 56, height: 46)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct BarActionButton: View {
    let id: BarTooltipID
    let title: String
    let systemImage: String
    var tint: Color = .white
    let tooltip: String
    var accessibility: String?
    let model: BarTooltipModel
    let action: () -> Void

    var body: some View {
        Button {
            model.dismiss()
            action()
        } label: {
            BarActionLabel(title: title, systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.plain)
        .barTooltip(id, tooltip, accessibility: accessibility, model: model)
    }
}

struct BarDivider: View {
    var body: some View {
        Rectangle()
            .fill(BarMetrics.stroke)
            .frame(width: 1, height: 34)
            .padding(.horizontal, 4)
    }
}
