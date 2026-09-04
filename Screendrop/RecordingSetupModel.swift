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

@MainActor
@Observable
final class RecordingSetupModel {

    /// The active aspect-ratio constraint.  `.freeform` means unconstrained.
    var aspect: CropAspectRatio = .freeform

    /// The committed selection rectangle in overlay-panel-local coordinates.
    /// `nil` until the user draws a region; the Start button stays disabled
    /// until this is set.
    var selection: CGRect?

    /// Point-to-pixel scale for the target display (used to show pixel dimensions).
    let pixelScale: CGSize

    /// Live pixel dimensions of the current selection, or `nil` when none.
    var pixelSize: CGSize? {
        guard let rect = selection else { return nil }
        return CGSize(
            width:  (rect.width  * pixelScale.width).rounded(),
            height: (rect.height * pixelScale.height).rounded()
        )
    }

    init(pixelScale: CGSize) {
        self.pixelScale = pixelScale
    }
}
