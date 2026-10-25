//
//  DesignSystem.swift
//  Screendrop
//
//  The tokens every surface is built from: Settings, the Library, both
//  editors and the floating chrome. Screendrop is Liquid Glass in the Mac's
//  own colors: neutral label ink for text and glyphs, and the system accent
//  (whatever the user picked in System Settings) for selection, switches and
//  the one prominent action. Captures, annotation colors and wallpapers
//  bring the rest of the color. Red means recording, or that something will
//  be removed.
//
//  Components live beside this file: GlassControls.swift for floating and
//  toolbar chrome, AnnotationInspectorStyle.swift for inspector controls,
//  Motion.swift for the springs.
//

import AppKit
import SwiftUI

// MARK: - Ink

extension Color {
    /// Pure black in light mode, pure white in dark. `.primary` inside a
    /// button in a non-key panel resolves dimmed, and `.labelColor` is
    /// slightly translucent, so solid marks use this instead.
    static let ink = Color(nsColor: NSColor(name: "screendrop.ink") { $0.isDarkAppearance ? .white : .black })
    /// The opposite of `ink`: text and glyphs drawn on a solid ink fill.
    static let inkInverse = Color(nsColor: NSColor(name: "screendrop.inkInverse") { $0.isDarkAppearance ? .black : .white })
}

extension NSAppearance {
    var isDarkAppearance: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Semantic colors. Views ask for a role, never a literal color, so the whole
/// app can be retuned here.
enum Palette {
    /// Selection, the "on" state and the one prominent action on a surface:
    /// the system accent, so the app matches the rest of the Mac.
    static let accent = Color.accentColor
    /// Marks drawn on an `accent` fill, white as on the system's own
    /// prominent controls.
    static let onAccent = Color.white
    /// Marks drawn over content rather than chrome: timeline cues, the
    /// playhead, a canvas marquee, the screen a recording will capture, the
    /// word being spoken. The same system accent today, kept as its own role
    /// so marks over pixels can be retuned apart from chrome.
    static let highlight = Color.accentColor
    /// Camera layout cues on the timeline, apart from the accent zooms they
    /// sit under. Not yellow: that is the timeline's selection frame.
    static let layoutCue = Color(nsColor: .systemGreen)
    /// Text on the timeline, apart from the cues that move the camera.
    static let textCue = Color(nsColor: .systemPurple)
    /// Recording, and actions that remove something.
    static let record = Color(nsColor: .systemRed)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)

    /// Glyphs and labels at rest, and dimmed when disabled.
    static let label = Color.ink.opacity(0.88)
    static let secondaryLabel = Color.ink.opacity(0.55)
    static let tertiaryLabel = Color.ink.opacity(0.32)
    static let disabledLabel = Color.ink.opacity(0.28)

    /// Quiet fills, tuned against an opaque panel. They wash out over
    /// vibrancy, so surfaces hosting them paint `panel` first.
    static let fill = Color.primary.opacity(0.055)
    static let hoverFill = Color.primary.opacity(0.07)
    static let pressedFill = Color.primary.opacity(0.12)
    static let selectedFill = Color.primary.opacity(0.10)
    static let hairline = Color.primary.opacity(0.10)
    static let strongHairline = Color.primary.opacity(0.18)

    /// The opaque background of inspectors and side panels.
    static let panel = Color(nsColor: NSColor(name: "screendrop.panel") {
        $0.isDarkAppearance ? .windowBackgroundColor : .white
    })

    /// The neutral, slightly recessed ground editors place their canvas on.
    /// A flat desaturated gray: system materials pick up a blue cast from the
    /// accent color and whatever sits behind the window.
    static let workspace = Color(nsColor: NSColor(name: "screendrop.workspace") {
        $0.isDarkAppearance ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
    })
}

// MARK: - Geometry

/// Corner radii. Nested shapes follow `outer = inner + padding`, never equal
/// radii, so concentric corners stay parallel.
enum Radius {
    /// Swatches, tool cells, wallpaper tiles.
    static let tile: CGFloat = 6
    /// Fields, sliders and segmented tracks inside an inspector.
    static let field: CGFloat = 8
    /// Thumbnails inside a card.
    static let thumbnail: CGFloat = 10
    /// Cards, popovers and grouped lists.
    static let card: CGFloat = 16
    /// Floating HUDs and overlay panels.
    static let hud: CGFloat = 22

    static func nested(inner: CGFloat, padding: CGFloat) -> CGFloat { inner + padding }
}

/// The spacing rhythm. Surfaces separate groups with whitespace, not rules.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let xxxl: CGFloat = 28
}

// MARK: - Typography

extension Font {
    /// A page or hero title, e.g. the About pane's app name.
    static let dsDisplay = Font.system(size: 22, weight: .bold)
    /// The name of the thing in front of you: a selected capture, a HUD title.
    static let dsTitle = Font.system(size: 15, weight: .semibold)
    /// Row titles in lists and settings.
    static let dsHeadline = Font.system(size: 13, weight: .semibold)
    static let dsBody = Font.system(size: 13)
    /// Button labels.
    static let dsControl = Font.system(size: 12, weight: .semibold)
    /// Supporting copy under a title.
    static let dsCallout = Font.system(size: 12)
    static let dsCaption = Font.system(size: 11)
    /// Small labels on badges and key caps.
    static let dsMicro = Font.system(size: 10, weight: .semibold)
    static let dsNumeric = Font.system(size: 12, weight: .medium).monospacedDigit()
}

// MARK: - Surfaces

extension View {
    /// A quiet rounded surface for grouped content inside a panel.
    func surface(selected: Bool = false, radius: CGFloat = Radius.card) -> some View {
        background(
            selected ? Palette.selectedFill : Palette.fill,
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
    }

    /// A hairline edge, drawn inside the shape so it never changes layout.
    func hairline(radius: CGFloat, opacity: Double = 0.10) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(opacity), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}
