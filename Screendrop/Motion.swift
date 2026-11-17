//
//  Motion.swift
//  Screendrop
//
//  The app's motion vocabulary. Motion here is quiet: things settle into
//  place, they do not bounce. Each token is a spring only so an animation
//  interrupted halfway keeps its velocity; none of them overshoots by more
//  than a fraction of a percent. Content that changes meaning blurs across
//  instead of cross-fading, and glass shapes are born out of, and melt back
//  into, their neighbours through `GlassEffectContainer`.
//
//  Pick a token by what moves:
//    morph       a control appears, leaves or changes shape
//    morphQuick  small feedback: a press, a label or glyph swap, a hover reveal
//    fold        a section's height
//    panel       a whole panel or card travelling: inspectors, the shelf
//    canvasMove  the editor's picture moving to a new frame
//    hover       a hover or selection tint
//    fade        anything that only changes opacity
//

import AppKit
import SwiftUI

extension Animation {
    /// Things that appear, part or change shape. A soft settle with no
    /// visible overshoot: the bouncy spring this replaced carried every
    /// shape about 8% past its mark, which read as the whole app wobbling.
    static let morph = Animation.spring(duration: 0.34, bounce: 0.12)
    /// A tighter one for small feedback such as presses, tab switches and
    /// label swaps.
    static let morphQuick = Animation.spring(duration: 0.22, bounce: 0.08)

    /// Folding a list section open or closed: smooth, with no overshoot. A
    /// bounce on a panel's height reads as the whole list wobbling.
    static let fold = Animation.smooth(duration: 0.26)

    /// A whole panel or card travelling across the window or through the
    /// screen edge. Overshoot grows with distance, so these have none.
    static let panel = Animation.smooth(duration: 0.32)

    /// The editor's image moving to a new frame (entering, applying or
    /// cancelling a crop). The longest move in the app, so it gets the most
    /// time and no bounce: any overshoot on a zoomed-in crop whips.
    static let canvasMove = Animation.smooth(duration: 0.4)

    /// A hover or selection tint. Short enough to keep up with a pointer
    /// crossing a row of controls, or arrow keys moving through a grid.
    static let hover = Animation.easeOut(duration: 0.12)

    /// Something that only fades: a hint, a badge, a dimmed layer.
    static let fade = Animation.easeOut(duration: 0.18)

    private static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `morph`, or no animation when Reduce Motion is on. For use outside views.
    static var morphIfAllowed: Animation? { reducesMotion ? nil : .morph }

    /// `morphQuick`, or no animation when Reduce Motion is on.
    static var morphQuickIfAllowed: Animation? { reducesMotion ? nil : .morphQuick }

    /// `panel`, or no animation when Reduce Motion is on.
    static var panelIfAllowed: Animation? { reducesMotion ? nil : .panel }

    /// `fold`, or no animation when Reduce Motion is on.
    static var foldIfAllowed: Animation? { reducesMotion ? nil : .fold }

    /// `canvasMove`, or no animation when Reduce Motion is on.
    static var canvasMoveIfAllowed: Animation? { reducesMotion ? nil : .canvasMove }
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
    /// Animates changes to `value` with `morph` unless told otherwise, respecting Reduce Motion.
    func motion<Value: Equatable>(_ animation: Animation = .morph, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

extension AnyTransition {
    /// Pops in from a slightly smaller size, for controls revealed by an
    /// action. Nothing in the app grows from far below its size: a control
    /// arriving from 60% reads as a jump, not an arrival.
    static var pop: AnyTransition {
        .scale(scale: 0.9).combined(with: .opacity)
    }

    /// A glyph or chip focusing in from a blur as it grows, the way a new
    /// control emerges out of the one that was there before.
    static var blurPop: AnyTransition {
        AnyTransition(.blurReplace).combined(with: .scale(scale: 0.88))
    }

    /// Floating chrome entering from just below its resting place, focusing
    /// in from a blur.
    static var rise: AnyTransition {
        AnyTransition(.blurReplace)
            .combined(with: .scale(scale: 0.96, anchor: .bottom))
            .combined(with: .offset(y: 6))
    }
}
