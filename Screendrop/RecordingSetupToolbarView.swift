//
//  RecordingSetupToolbarView.swift
//  Screendrop
//
//  Floating toolbar for the recording setup HUD.  Dark HUD appearance so it
//  reads clearly against the dimmed overlay; Start is a vivid red pill that
//  activates the moment a valid region exists.
//

import SwiftUI

struct RecordingSetupToolbarView: View {

    @Bindable var model: RecordingSetupModel

    var onStart:        () -> Void
    var onCancel:       () -> Void
    var onAspectChange: (CropAspectRatio) -> Void
    var onModeChange:   (RecordingSetupMode) -> Void

    private let aspects: [(aspect: CropAspectRatio, label: String)] = [
        (.freeform,    "Freeform"),
        (.sixteenNine, "16:9"),
        (.nineSixteen, "9:16"),
        (.square,      "1:1"),
        (.fourThree,   "4:3"),
    ]

    var body: some View {
        HStack(spacing: 10) {

            // ── Mode picker ────────────────────────────────────────────────
            Picker("", selection: $model.mode) {
                ForEach(RecordingSetupMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: model.mode) { _, newMode in onModeChange(newMode) }

            // ── Aspect chips + size (Area only) ───────────────────────────
            if model.mode == .area {
                separator

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
            }

            separator

            // ── Cancel ─────────────────────────────────────────────────────
            Button("Cancel", action: onCancel)
                .foregroundStyle(.white.opacity(0.7))

            // ── Start ──────────────────────────────────────────────────────
            Button(action: onStart) {
                Label("Start", systemImage: "record.circle.fill")
            }
            .buttonStyle(HUDStartButtonStyle())
            .disabled(!model.canStart)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.78))
        )
        .shadow(color: .black.opacity(0.5), radius: 16, y: 5)
        .padding(10)
        .environment(\.colorScheme, .dark)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 1, height: 20)
    }
}

// MARK: - Button styles

private struct HUDAspectChipStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isActive ? Color.black : Color.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isActive ? Color.white : Color.white.opacity(0.12))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

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
