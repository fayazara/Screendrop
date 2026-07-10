//
//  AnnotationHighlightOverlay.swift
//  Screendrop
//

import SwiftUI

enum AnnotationHighlightMetrics {
    /// Dark enough to pull focus without making the surrounding screenshot
    /// unreadable or turning the effect into a hard crop.
    static let overlayOpacity: CGFloat = 0.48
}

/// One shared dimming layer with every highlight rectangle punched out of it.
/// A shared layer matters: stacking one reverse mask per annotation would make
/// multiple highlights darken each other instead of creating a union of holes.
struct AnnotationHighlightOverlay: View {
    let items: [AnnotationItem]
    let imageFrame: CGRect
    let cornerRadii: RectangleCornerRadii

    private var highlightItems: [AnnotationItem] {
        items.filter { item in
            item.tool == .highlight
                && item.bounds.width > 0
                && item.bounds.height > 0
        }
    }

    var body: some View {
        if !highlightItems.isEmpty, imageFrame.width > 0, imageFrame.height > 0 {
            ZStack(alignment: .topLeading) {
                Color.black.opacity(AnnotationHighlightMetrics.overlayOpacity)

                ForEach(highlightItems) { item in
                    let hole = localRect(for: item.bounds)

                    Rectangle()
                        .fill(Color.black)
                        .frame(width: hole.width, height: hole.height)
                        .position(x: hole.midX, y: hole.midY)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .frame(width: imageFrame.width, height: imageFrame.height)
            .clipShape(UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous))
            .position(x: imageFrame.midX, y: imageFrame.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func localRect(for normalizedRect: CGRect) -> CGRect {
        let clippedRect = normalizedRect.standardized.intersection(CropRectEditor.unit)
        guard !clippedRect.isNull else { return .zero }

        return CGRect(
            x: clippedRect.minX * imageFrame.width,
            y: clippedRect.minY * imageFrame.height,
            width: clippedRect.width * imageFrame.width,
            height: clippedRect.height * imageFrame.height
        )
    }
}
