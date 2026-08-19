//
//  AnnotationShadowStyle.swift
//  Screendrop
//
//  Created by Codex on 02/08/26.
//

import CoreGraphics
import Foundation
import SwiftUI

/// The shape of the card shadow, ported from Framekit. Each style rescales the
/// same base drop: how far it spreads, how far it falls, and how dark it lands.
enum AnnotationShadowStyle: String, CaseIterable, Identifiable, Codable {
    case soft
    case long
    case glow
    case crisp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .soft: "Soft"
        case .long: "Long"
        case .glow: "Glow"
        case .crisp: "Crisp"
        }
    }

    var radiusScale: CGFloat {
        switch self {
        case .soft: 1
        case .long: 1.2
        case .glow: 1.6
        case .crisp: 0.8
        }
    }

    var yOffsetScale: CGFloat {
        switch self {
        case .soft: 0.3
        case .long: 0.9
        case .glow: 0
        case .crisp: 0.2
        }
    }

    var opacityScale: CGFloat {
        switch self {
        case .soft: 1
        case .long: 0.85
        case .glow: 0.7
        case .crisp: 1.1
        }
    }

    /// The slider mostly grows the drop rather than darkening it: opacity
    /// reaches its ceiling early and stays there, which is what keeps a large
    /// shadow from turning into a black smear.
    func layer(strength: CGFloat, referenceEdge: CGFloat) -> AnnotationShadowLayer? {
        let strength = min(max(strength, 0), 1)
        guard strength > 0, referenceEdge > 0 else { return nil }

        let radius = referenceEdge * 0.17 * strength * radiusScale
        let alpha = min(0.5, min(0.35, 0.08 + strength * 1.35) * opacityScale)
        return AnnotationShadowLayer(
            yOffset: radius * yOffsetScale,
            radius: radius,
            alpha: alpha
        )
    }
}

/// A resolved card shadow.
struct AnnotationShadowLayer {
    /// Downward drop, in the same units as `radius`.
    var yOffset: CGFloat
    /// SwiftUI blur radius. Core Graphics wants roughly twice this.
    var radius: CGFloat
    var alpha: CGFloat

    var coreGraphicsBlur: CGFloat { radius * 2 }

    /// Space that must remain around the card for the complete blur kernel.
    /// Core Graphics uses roughly twice SwiftUI's radius, so this shared
    /// extent keeps both renderers inside the final canvas without making the
    /// preview and export use different layout math.
    var renderOutsets: AnnotationShadowOutsets {
        let blurExtent = coreGraphicsBlur
        return AnnotationShadowOutsets(
            top: max(0, blurExtent - yOffset),
            leading: blurExtent,
            bottom: blurExtent + yOffset,
            trailing: blurExtent
        )
    }
}

struct AnnotationShadowOutsets {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    static let zero = AnnotationShadowOutsets(
        top: 0,
        leading: 0,
        bottom: 0,
        trailing: 0
    )
}

/// Casts the shadow and nothing else. `shadowOnly` avoids the former solid
/// black caster plus `destinationOut` knockout, whose two antialiased edges
/// left a dark one-pixel fringe around rounded borders.
struct AnnotationCardShadowBackdrop: View {
    var cornerRadii: RectangleCornerRadii
    var size: CGSize
    var strength: CGFloat
    var style: AnnotationShadowStyle

    @ViewBuilder
    var body: some View {
        if let layer = style.layer(
            strength: strength,
            referenceEdge: min(size.width, size.height)
        ) {
            let outsets = layer.renderOutsets
            let canvasSize = CGSize(
                width: size.width + outsets.leading + outsets.trailing,
                height: size.height + outsets.top + outsets.bottom
            )
            Canvas { context, _ in
                let cardRect = CGRect(
                    x: outsets.leading,
                    y: outsets.top,
                    width: size.width,
                    height: size.height
                )
                let path = UnevenRoundedRectangle(
                    cornerRadii: cornerRadii,
                    style: .continuous
                ).path(in: cardRect)
                context.addFilter(.shadow(
                    color: .black.opacity(Double(layer.alpha)),
                    radius: layer.radius,
                    x: 0,
                    y: layer.yOffset,
                    options: .shadowOnly
                ))
                context.fill(path, with: .color(.black))
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            // Keep the original card centered at the position supplied by the
            // caller even though a downward shadow has asymmetric outsets.
            .offset(
                x: (outsets.trailing - outsets.leading) / 2,
                y: (outsets.bottom - outsets.top) / 2
            )
        }
    }
}
