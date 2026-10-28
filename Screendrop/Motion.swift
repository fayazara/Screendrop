//
//  Motion.swift
//  Screendrop
//
//  The app's motion vocabulary. Everything that appears, parts, or changes
//  shape uses one bouncy spring; small feedback (presses, detents, swaps of a
//  label) uses a tighter one. Content that changes meaning blurs across
//  instead of cross-fading, and glass shapes are born out of, and melt back
//  into, their neighbours through `GlassEffectContainer`.
//

import AppKit
import SwiftUI

extension Animation {
    /// Shared spring for things that appear, part, morph and settle: quick,
    /// with a little overshoot.
    static let morph = Animation.bouncy(duration: 0.45, extraBounce: 0.08)
    /// A tighter spring for small feedback such as presses, tab switches and
    /// label swaps.
    static let morphQuick = Animation.snappy(duration: 0.25, extraBounce: 0.12)

    /// Folding a list section open or closed: smooth, with no overshoot. A
    /// bounce on a panel's height reads as the whole list wobbling.
    static let fold = Animation.smooth(duration: 0.26)

    /// The editor's image moving to a new frame (entering, applying or
    /// cancelling a crop): `morph`'s timing with a tenth of its bounce. A
    /// spring's overshoot grows with the distance travelled, so a full
    /// bounce on a zoomed-in crop whips.
    static let canvasMove = Animation.spring(duration: 0.45, bounce: 0.04)

    /// `morph`, or no animation when Reduce Motion is on. For use outside views.
    static var morphIfAllowed: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .morph
    }

    /// `canvasMove`, or no animation when Reduce Motion is on.
    static var canvasMoveIfAllowed: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .canvasMove
    }

    /// `morphQuick`, or no animation when Reduce Motion is on.
    static var morphQuickIfAllowed: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .morphQuick
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Animates changes to `value` with the shared spring, respecting Reduce Motion.
    func motion<Value: Equatable>(_ animation: Animation = .morph, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

extension AnyTransition {
    /// Pops in from a smaller size, for controls revealed by an action.
    static var pop: AnyTransition {
        .scale(scale: 0.6).combined(with: .opacity)
    }

    /// A glyph or chip focusing in from a blur as it grows, the way a new
    /// control emerges out of the one that was there before.
    static var blurPop: AnyTransition {
        AnyTransition(.blurReplace).combined(with: .scale(scale: 0.7))
    }

    /// Floating chrome entering from just below its resting place, focusing
    /// in from a blur.
    static var rise: AnyTransition {
        AnyTransition(.blurReplace)
            .combined(with: .scale(scale: 0.92, anchor: .bottom))
            .combined(with: .offset(y: 10))
    }
}
