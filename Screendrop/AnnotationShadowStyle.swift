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
        case .soft: String(localized: "Soft")
        case .long: String(localized: "Long")
        case .glow: String(localized: "Glow")
        case .crisp: String(localized: "Crisp")
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
}

/// Casts the shadow and nothing else. The caster is drawn `shadowOnly`, so no
/// solid black ever reaches the screen, then the card interior is cleared with
/// the same shape. Knocking a solid black caster out left a dark antialiased
/// fringe around rounded borders; clearing only the soft shadow can't.
///
/// The canvas overflows the card by the shadow's reach without taking part in
/// layout, so the card never moves when the shadow changes.
struct AnnotationCardShadowBackdrop: View {
    var cornerRadii: RectangleCornerRadii
    var size: CGSize
    var strength: CGFloat
    var style: AnnotationShadowStyle

    var body: some View {
        let layer = style.layer(
            strength: strength,
            referenceEdge: min(size.width, size.height)
        )
        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay {
                if let layer {
                    shadowCanvas(layer)
                }
            }
            .allowsHitTesting(false)
    }

    private func shadowCanvas(_ layer: AnnotationShadowLayer) -> some View {
        let reach = ceil(layer.radius * 3 + abs(layer.yOffset)) + 2
        let cardRect = CGRect(origin: CGPoint(x: reach, y: reach), size: size)
        let path = UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
            .path(in: cardRect)

        return Canvas { context, _ in
            context.drawLayer { shadowContext in
                shadowContext.addFilter(.shadow(
                    color: .black.opacity(Double(layer.alpha)),
                    radius: layer.radius,
                    x: 0,
                    y: layer.yOffset,
                    options: .shadowOnly
                ))
                shadowContext.fill(path, with: .color(.black))
            }
            context.blendMode = .destinationOut
            context.fill(path, with: .color(.black))
        }
        .frame(width: size.width + reach * 2, height: size.height + reach * 2)
    }
}
