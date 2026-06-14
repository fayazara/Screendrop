//
//  AnnotationRedactionPreview.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct RedactionPreview: View {
    let image: NSImage
    let item: AnnotationItem
    let originalImageSize: CGSize
    let imageFrame: CGRect
    let viewBounds: CGRect
    let allowsCaching: Bool

    var body: some View {
        if let redactedImage = RedactionImageProcessor.previewImage(
            source: image,
            tool: item.tool,
            density: item.redactionDensity,
            normalizedBounds: item.bounds,
            originalImageSize: originalImageSize,
            allowsCaching: allowsCaching
        ) {
            Image(nsImage: redactedImage)
                .interpolation(item.tool == .pixelate ? .none : .medium)
                .resizable()
                .frame(width: max(viewBounds.width, 1), height: max(viewBounds.height, 1))
                .position(x: viewBounds.midX, y: viewBounds.midY)
        }
    }
}
