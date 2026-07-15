//
//  RecordingSetupModel.swift
//  Screendrop
//
//  Shared state between the area-selection overlay and the recording setup
//  toolbar. Both surfaces read and write through this model; the presenter
//  is the single owner that keeps them in sync.
//

import CoreGraphics
import Observation
// MARK: - Mode

/// Capture modes available in the recording setup HUD.
enum RecordingSetupMode: String, CaseIterable, Identifiable {
    case fullscreen
    case area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullscreen: "Full Screen"
        case .area:       "Area"
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class RecordingSetupModel {

    // MARK: Mode

    /// The active capture mode.  The toolbar mode picker writes this; the
    /// overlay adapts its interaction accordingly.
    var mode: RecordingSetupMode = .area

    // MARK: Area

    /// Committed selection rect (panel-local coordinates) for Area mode.
    /// `nil` until the user completes a draw; drives the Start button.
    var selection: CGRect?

    /// Active aspect-ratio constraint for Area mode.
    var aspect: CropAspectRatio = .freeform

    // MARK: Display

    /// Point-to-pixel scale for the target display (used to show W×H).
    let pixelScale: CGSize

    // MARK: Derived

    /// Live pixel dimensions of the current area selection, or `nil` when none.
    var pixelSize: CGSize? {
        guard let rect = selection else { return nil }
        return CGSize(
            width:  (rect.width  * pixelScale.width).rounded(),
            height: (rect.height * pixelScale.height).rounded()
        )
    }

    /// Whether the Start button should be enabled for the current mode.
    var canStart: Bool {
        switch mode {
        case .fullscreen: return true
        case .area:       return selection != nil
        }
    }

    init(pixelScale: CGSize) {
        self.pixelScale = pixelScale
    }
}
