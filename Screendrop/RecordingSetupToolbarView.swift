//
//  RecordingSetupToolbarView.swift
//  Screendrop
//
//  Floating toolbar shown during area-recording setup.  Uses a dark HUD
//  appearance so it reads clearly against the dimmed screen overlay, avoiding
//  the flat rendering that .regularMaterial produces in non-activating panels.
//  Start is a vivid red pill (obvious primary action); Cancel is a muted text
//  label that stays accessible without competing with Start.
//

import SwiftUI

struct RecordingSetupToolbarView: View {

    @Bindable var model: RecordingSetupModel

    var onStart:        () -> Void
    var onCancel:       () -> Void
    var onAspectChange: (CropAspectRatio) -> Void
    /// Called when a future mode control changes mode (wired in PR 3).
    var onModeChange:   (Any) -> Void

    private let aspects: [(aspect: CropAspectRatio, label: String)] = [
        (.freeform,    "Freeform"),
        (.sixteenNine, "16:9"),
        (.nineSixteen, "9:16"),
        (.square,      "1:1"),
        (.fourThree,   "4:3"),
    ]

    var body: some View {
        HStack(spacing: 10) {

            // ── Aspect-ratio chips ─────────────────────────────────────────
            HStack(spacing: 4) {
                ForEach(aspects, id: \.aspect.id) { item in
                    Button(item.label) {
                        model.aspect = item.aspect
                        onAspectChange(item.aspect)
                    }
                    .buttonStyle(HUDAspectChipStyle(isActive: model.aspect == item.aspect))
                }
            }

            separator

            // ── Live pixel size ────────────────────────────────────────────
            Group {
                if let size = model.pixelSize {
                    Text("\(Int(size.width)) × \(Int(size.height))")
                        .foregroundStyle(.white)
                } else {
                    Text("W × H")
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .frame(minWidth: 76, alignment: .leading)

            separator

            // ── Cancel ─────────────────────────────────────────────────────
            Button("Cancel", action: onCancel)
                .foregroundStyle(.white.opacity(0.7))

            // ── Start ──────────────────────────────────────────────────────
            Button(action: onStart) {
                Label("Start", systemImage: "record.circle.fill")
            }
            .buttonStyle(HUDStartButtonStyle())
            .disabled(model.selection == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
        // Dark HUD: clear and readable on any dimmed overlay; avoids the
        // flat appearance of .regularMaterial in non-activating panels.
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.78))
        )
        .shadow(color: .black.opacity(0.5), radius: 16, y: 5)
        .padding(10)
        // Force dark scheme so the system controls inside render correctly
        // on the dark background.
        .environment(\.colorScheme, .dark)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 1, height: 20)
    }
}

// MARK: - Button styles

/// Aspect-ratio chip on the dark HUD toolbar.
/// Active state: white fill + black text.  Inactive: subtle ghost pill.
private struct HUDAspectChipStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isActive ? Color.black : Color.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isActive
                    ? Color.white
                    : Color.white.opacity(0.12)
            )
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Primary Start button.  Red when enabled, invisible-ish when disabled;
/// animates between states so the moment a selection is drawn is felt.
private struct HUDStartButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isEnabled ? Color.red : Color.white.opacity(0.15))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeInOut(duration: 0.18), value: isEnabled)
    }
}
