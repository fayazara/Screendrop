//
//  RecordingPointerArtworkCapture.swift
//  Screendrop
//
//  Converts AppKit-provided cursor images into the recording sidecar format.
//  The sidecar always keeps what macOS showed; PointerShape stand-ins are
//  swapped in only when the Studio draws it.
//

import AppKit
import Foundation

@MainActor
enum PointerArtworkCapture {
    static func defaultArtwork() -> PointerArtwork? {
        capture(NSCursor.arrow, id: "pointer-default")
    }

    static func capture(_ cursor: NSCursor, id: String) -> PointerArtwork? {
        let image = cursor.image
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let imageData = bitmap.representation(using: .png, properties: [:]),
              !imageData.isEmpty else {
            return nil
        }

        let imageSize = image.size
        let width = imageSize.width.isFinite && imageSize.width > 0
            ? imageSize.width
            : CGFloat(bitmap.pixelsWide)
        let height = imageSize.height.isFinite && imageSize.height > 0
            ? imageSize.height
            : CGFloat(bitmap.pixelsHigh)
        guard width > 0, height > 0 else { return nil }

        let hotSpot = cursor.hotSpot
        return PointerArtwork(
            artworkID: id,
            imageData: imageData,
            anchorPoint: PointerArtwork.Point(
                x: min(max(hotSpot.x.isFinite ? hotSpot.x : 0, 0), width),
                y: min(max(hotSpot.y.isFinite ? hotSpot.y : 0, 0), height)
            ),
            referenceSize: PointerArtwork.Size(
                width: width,
                height: height
            )
        )
    }
}

extension PointerArtwork {
    /// What the Studio draws for this captured cursor: a circle for every
    /// cursor, or the chosen arrow in place of the macOS arrow and the vector
    /// hand for any pointing hand. Only the arrow leans as it moves.
    /// `inverted` turns a vector arrow, and the hand beside it, black inside
    /// a white outline; the macOS arrow stays as macOS drew it.
    @MainActor
    func styled(_ style: RecordingCursorStyle, inverted: Bool) -> PointerArtwork {
        if let shape = style.shape, shape.isCircle {
            return shape.artwork ?? self
        }
        let inverts = inverted && style.shape != nil
        if imageData == SystemPointer.arrow {
            var arrow = style.shape?.artwork(inverted: inverts) ?? self
            arrow.leans = true
            return arrow
        }
        if imageData == SystemPointer.pointingHand || SystemPointer.isBrowserHand(self) {
            return PointerShape.hand.artwork(inverted: inverts) ?? self
        }
        return self
    }
}

@MainActor
private enum SystemPointer {
    static let arrow = PointerArtworkCapture.capture(NSCursor.arrow, id: "")?.imageData
    static let pointingHand = PointerArtworkCapture.capture(NSCursor.pointingHand, id: "")?.imageData

    /// Browsers draw their own link hand, a pixel to the right of the macOS
    /// one. Its 32-point square and fingertip hot spot are distinct from
    /// every other system cursor (the open hand grabs at its center).
    static func isBrowserHand(_ artwork: PointerArtwork) -> Bool {
        artwork.referenceSize == PointerArtwork.Size(width: 32, height: 32)
            && artwork.anchorPoint == PointerArtwork.Point(x: 13, y: 8)
    }
}
