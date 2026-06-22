//
//  RecordingSetupToolbarView.swift
//  Screendrop
//
//  Floating toolbar shown during recording setup.  Hosts a mode picker
//  (Full Screen / Area / Window), aspect-ratio chips (Area only), a live
//  pixel-size readout, and Start / Cancel actions.
//  Hosted in a borderless NSPanel by RecordingSetupPresenter.
//

import SwiftUI

struct RecordingSetupToolbarView: View {

    @Bindable var model: RecordingSetupModel

    var onStart:        () -> Void
    var onCancel:       () -> Void
    /// Aspect chip tapped — lets the AppKit overlay apply the constraint synchronously.
    var onAspectChange: (CropAspectRatio) -> Void
    /// Mode chip tapped — lets the AppKit overlay reset state for the new mode.
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

            // ── Mode picker ───────────────────────────────────────────────
            Picker("", selection: $model.mode) {
                ForEach(RecordingSetupMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: model.mode) { _, newMode in
                onModeChange(newMode)
            }

            // ── Aspect chips (Area only) ───────────────────────────────────
            if model.mode == .area {
                toolbarDivider

                HStack(spacing: 4) {
                    ForEach(aspects, id: \.aspect.id) { item in
                        Button(item.label) {
                            model.aspect = item.aspect
                            onAspectChange(item.aspect)
                        }
                        .buttonStyle(AspectChipStyle(isActive: model.aspect == item.aspect))
                    }
                }

                toolbarDivider

                // Live pixel size
                Group {
                    if let size = model.pixelSize {
                        Text("\(Int(size.width)) × \(Int(size.height))")
                    } else {
                        Text("W × H").foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(minWidth: 76, alignment: .leading)
            }

            toolbarDivider

            // ── Cancel / Start ─────────────────────────────────────────────
            Button("Cancel", action: onCancel)
                .foregroundStyle(.secondary)

            Button(action: onStart) {
                Label("Start", systemImage: "record.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!model.canStart)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .padding(10)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 20)
    }
}

// MARK: - Chip button style

private struct AspectChipStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isActive
                    ? Color.accentColor
                    : Color(nsColor: .controlColor).opacity(0.7)
            )
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
