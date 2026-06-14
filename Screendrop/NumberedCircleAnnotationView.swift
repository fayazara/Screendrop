//
//  NumberedCircleAnnotationView.swift
//  Screendrop
//

import SwiftUI

struct NumberedCircleAnnotationView: View {
    let item: AnnotationItem
    let viewBounds: CGRect

    var body: some View {
        let diameter = min(max(viewBounds.width, 1), max(viewBounds.height, 1))

        ZStack {
            Circle()
                .fill(item.swatch.color)
                .overlay {
                    Circle()
                        .stroke(
                            item.swatch.numberedCircleOutlineColor,
                            lineWidth: AnnotationNumberedCircleMetrics.outlineWidth(for: diameter)
                        )
                }

            Text(item.text)
                .font(.system(
                    size: AnnotationNumberedCircleMetrics.fontSize(for: diameter, text: item.text),
                    weight: .bold,
                    design: .rounded
                ))
                .foregroundStyle(item.swatch.numberedCircleTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .monospacedDigit()
        }
        .frame(width: max(viewBounds.width, 1), height: max(viewBounds.height, 1))
        .position(x: viewBounds.midX, y: viewBounds.midY)
    }
}
