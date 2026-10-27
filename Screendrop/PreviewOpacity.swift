//
//  PreviewOpacity.swift
//  Screendrop
//  Contributed by Rochak Agrawal (Screenshot X).
//
//  Translates a scroll wheel or trackpad gesture into a window opacity, so a
//  floating preview or a pinned screenshot can be faded out of the way while
//  still being readable. Both surfaces share the same steps.
//

import AppKit

enum PreviewOpacity {
    static let minimum: CGFloat = 0.15

    /// One scroll event's worth of change. Trackpad deltas are in points and
    /// arrive many times a second; wheel deltas are whole lines.
    static func alpha(_ alpha: CGFloat, after event: NSEvent) -> CGFloat {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return alpha }
        let step = event.hasPreciseScrollingDeltas ? delta * 0.002 : delta * 0.03
        return min(1, max(minimum, alpha + step))
    }
}
