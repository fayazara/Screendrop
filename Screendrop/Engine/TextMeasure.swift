import AppKit
import CoreGraphics
import CoreText
import Foundation

/// The three system faces annotations can be set in. Screendrop used to expose every installed
/// family; the SF faces are the only ones that look right over a macOS screenshot and the only ones
/// guaranteed to be present, so the picker is limited to them.
enum AnnoFontFamily: String, CaseIterable, Codable, Identifiable {
    case pro
    case compact
    case rounded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pro: "SF Pro"
        case .compact: "SF Compact"
        case .rounded: "SF Rounded"
        }
    }
}

/// Lays a text shape out and turns it into glyph outlines.
///
/// Ported from the drawing-app's `Text/TextMeasure.swift`. Two properties matter here:
///
/// 1. One layout engine. Measuring, the editing text view and the drawn glyphs all go through the
///    same `NSLayoutManager` stack, so what you type is where it lands.
/// 2. One layout, at one size. Text is laid out in page (image pixel) space and converted to
///    outlines once; the canvas draws that path through the camera transform and the exporter draws
///    it at 1:1. Preview and export are then identical by construction, and typing costs one cached
///    layout rather than a re-measure per frame.
enum TextMeasure {
    /// Layout runs on the main actor for the canvas and on a detached task for exports, so both the
    /// caches and the TextKit objects they hold are serialized behind this.
    private static let lock = NSLock()

    /// A finite-but-huge width. `.greatestFiniteMagnitude` breaks the layout manager's arithmetic
    /// and `usedRect` comes back empty.
    private static let unbounded: CGFloat = 1_000_000

    /// The narrowest a wrapped text box may get.
    static let minWidth: Double = 16

    /// The line box as a multiple of the font size, matching the drawing app's theme.
    ///
    /// A multiple rather than the font's natural leading: natural metrics give a box tight enough
    /// that ascenders and descenders clip against a pinned `maximumLineHeight`.
    static let lineHeightMultiple: Double = 1.35

    static func font(_ props: TextProps, opticalSize: Double? = nil) -> NSFont {
        let size = Swift.max(1, CGFloat(props.fontSize))
        let weight: NSFont.Weight = props.isBold ? .bold : .regular
        let base = NSFont.systemFont(ofSize: size, weight: weight)

        var descriptor = base.fontDescriptor
        switch props.fontFamily {
        case .pro:
            break
        case .rounded:
            if let rounded = descriptor.withDesign(.rounded) { descriptor = rounded }
        case .compact:
            // SF Compact is a separate family rather than a system *design*, so it has to be
            // resolved by name. Falls back to SF Pro where it isn't installed.
            if let compact = NSFont(name: "SFCompactText-Regular", size: size)
                ?? NSFont(name: "SF Compact Text", size: size) {
                descriptor = compact.fontDescriptor
            }
        }
        if props.isItalic {
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic))
        }
        descriptor = descriptor.addingAttributes([
            // Pin the optical size so the face doesn't change with the point size. Without this the
            // caret (laid out at view scale) and the committed glyphs (laid out at page scale) can
            // resolve to different SF designs, and the text jumps size on commit.
            kCTFontOpticalSizeAttribute as NSFontDescriptor.AttributeName:
                Swift.max(1, opticalSize ?? props.fontSize),
            // Re-assert the weight. SF is a variable font, and a descriptor round trip through a
            // design or an optical size can re-resolve it from the family and drop the `wght`
            // variation that `systemFont(ofSize:weight:)` applied - silently leaving Regular.
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// The line box height. Pinned so a line is the same height whether it was measured, typed
    /// into or drawn.
    static func lineHeight(_ props: TextProps) -> CGFloat {
        CGFloat(Swift.max(1, props.fontSize) * lineHeightMultiple)
    }

    /// How far the outline reaches past the glyph edge, as a fraction of the font size.
    ///
    /// Tied to the type size rather than a fixed pixel width so the edge keeps the same weight
    /// relative to the letters whether the label is a caption or a headline.
    static let outlineWidthMultiple: Double = 0.06

    /// The visible outline width for `props`, in the same units as its font size. Zero when the
    /// text has no outline.
    static func outlineWidth(_ props: TextProps) -> CGFloat {
        guard props.outline != .none else { return 0 }
        return CGFloat(Swift.max(1, props.fontSize) * outlineWidthMultiple)
    }

    /// The line width to stroke the glyph path with. A stroke is centred on the glyph edge, so it
    /// is drawn at twice the visible width and the fill that follows covers the inner half - which
    /// keeps the letters at their proper weight instead of eating into their stems.
    static func outlineStrokeWidth(_ props: TextProps) -> CGFloat {
        outlineWidth(props) * 2
    }

    /// The paragraph style every consumer shares.
    static func paragraphStyle(_ props: TextProps) -> NSParagraphStyle {
        let height = lineHeight(props)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = props.align.nsTextAlignment
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        paragraph.lineBreakMode = props.autoSize ? .byClipping : .byWordWrapping
        return paragraph
    }

    static func attributes(_ props: TextProps, color: NSColor? = nil) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(props),
            .foregroundColor: color ?? props.swatch.nsColor,
            .paragraphStyle: paragraphStyle(props),
        ]
        if props.isUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    static func attributedString(_ props: TextProps, color: NSColor? = nil) -> NSAttributedString {
        NSAttributedString(string: props.text, attributes: attributes(props, color: color))
    }

    // MARK: - Layout

    /// A layout stack with an explicit container width.
    ///
    /// The storage has to outlive the measurement: a layout manager doesn't retain its text
    /// storage, so letting it go releases the layout and `usedRect` comes back empty.
    private static func layout(
        _ props: TextProps,
        containerWidth: CGFloat
    ) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(attributedString: attributedString(props, color: .black))
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: containerWidth, height: unbounded))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        // Forces layout; `usedRect` is only meaningful afterwards.
        _ = layoutManager.glyphRange(for: container)
        return (storage, layoutManager, container)
    }

    /// The width the box lays out into: the fixed wrap width, or the natural width of the widest
    /// line when the box grows with its content.
    ///
    /// Growing text still needs a *finite* container. Alignment positions each line inside its line
    /// fragment, so laying centred text out in a nominally unbounded container would centre it half
    /// a million points away. Measure it left-aligned and unbounded first, then lay it out for real
    /// inside exactly that width.
    private static func lockedContainerWidth(_ props: TextProps) -> CGFloat {
        guard props.autoSize else { return CGFloat(Swift.max(minWidth, floor(props.w))) }
        if let cached = widthCache[props] { return cached }

        var probe = props
        probe.align = .start
        let (storage, layoutManager, container) = layout(probe, containerWidth: unbounded)
        let width = withExtendedLifetime(storage) {
            // Measurement floors fractional widths, so growing text gets a pixel back to keep the
            // last word from wrapping.
            Swift.max(CGFloat(minWidth), ceil(layoutManager.usedRect(for: container).width) + 1)
        }

        if widthCache.count > 512 { widthCache.removeAll(keepingCapacity: true) }
        widthCache[props] = width
        return width
    }

    // MARK: - Measurement

    private static var widthCache: [TextProps: CGFloat] = [:]
    private static var sizeCache: [TextProps: CGSize] = [:]
    private static var pathCache: [TextProps: CGPath] = [:]

    /// The box the text occupies: as wide as the text when growing, otherwise the fixed width with
    /// the text wrapped into it.
    static func measure(_ props: TextProps) -> CGSize {
        lock.lock()
        defer { lock.unlock() }
        if let cached = sizeCache[props] { return cached }

        let size = computeSize(props)
        // Text changes a character at a time while typing, so the cache would grow without bound.
        if sizeCache.count > 512 { sizeCache.removeAll(keepingCapacity: true) }
        sizeCache[props] = size
        return size
    }

    private static func computeSize(_ props: TextProps) -> CGSize {
        let height = lineHeight(props)
        let width = lockedContainerWidth(props)

        guard !props.text.isEmpty else {
            return CGSize(width: width, height: height)
        }

        let (storage, layoutManager, container) = layout(props, containerWidth: width)
        return withExtendedLifetime(storage) {
            let used = layoutManager.usedRect(for: container)
            return CGSize(width: width, height: Swift.max(height, ceil(used.height)))
        }
    }

    // MARK: - Glyph outlines

    /// The text's glyph outlines, origin at the top left of its box, y down.
    ///
    /// Outlines rather than drawn text because they are the same on both render paths, cache
    /// cleanly, and survive the canvas's rotation transform without re-laying anything out.
    static func glyphPath(_ props: TextProps) -> CGPath {
        lock.lock()
        defer { lock.unlock() }
        if let cached = pathCache[props] { return cached }

        let path = buildGlyphPath(props)
        if pathCache.count > 256 { pathCache.removeAll(keepingCapacity: true) }
        pathCache[props] = path
        return path
    }

    private static func buildGlyphPath(_ props: TextProps) -> CGPath {
        guard !props.text.isEmpty else { return CGMutablePath() }

        let (storage, layoutManager, container) = layout(props, containerWidth: lockedContainerWidth(props))
        defer { withExtendedLifetime(storage) {} }
        return glyphPath(in: layoutManager, storage: storage, container: container, underline: props.isUnderline)
    }

    /// Traces the glyphs of a laid-out container, origin at the container's top left, y down.
    ///
    /// Shared with the editing overlay, which traces its own `NSTextView` layout so the outline it
    /// draws under the caret sits exactly where the committed glyphs will.
    static func glyphPath(
        in layoutManager: NSLayoutManager,
        storage: NSTextStorage,
        container: NSTextContainer,
        underline: Bool
    ) -> CGPath {
        trace(layoutManager, storage: storage, container: container, glyphs: true, underline: underline)
    }

    /// Just the underline rules of a laid-out container, in the same space as `glyphPath`.
    ///
    /// The editing overlay fills these itself when text is outlined: AppKit's own rule sits a few
    /// points off the one the committed glyph path carries, and an outline traced around one and
    /// a fill drawn on the other read as two separate lines.
    static func underlinePath(
        in layoutManager: NSLayoutManager,
        storage: NSTextStorage,
        container: NSTextContainer
    ) -> CGPath {
        trace(layoutManager, storage: storage, container: container, glyphs: false, underline: true)
    }

    private static func trace(
        _ layoutManager: NSLayoutManager,
        storage: NSTextStorage,
        container: NSTextContainer,
        glyphs: Bool,
        underline: Bool
    ) -> CGPath {
        let result = CGMutablePath()
        let glyphRange = layoutManager.glyphRange(for: container)
        guard glyphRange.length > 0 else { return result }

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineRange, _ in
            var lineFont: NSFont?
            var baseline: CGFloat?

            for glyphIndex in lineRange.location..<(lineRange.location + lineRange.length) {
                // Skip the glyphs that stand for control characters, which have no outline.
                let property = layoutManager.propertyForGlyph(at: glyphIndex)
                guard !property.contains(.null), !property.contains(.controlCharacter) else { continue }

                let glyph = layoutManager.cgGlyph(at: glyphIndex)
                guard glyph != 0 else { continue }

                let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
                guard charIndex < storage.length,
                      let font = storage.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont
                else { continue }

                // `location` is the glyph's origin on the baseline, relative to its line fragment.
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                let location = layoutManager.location(forGlyphAt: glyphIndex)
                lineFont = font
                baseline = fragment.origin.y + location.y

                guard glyphs, let outline = CTFontCreatePathForGlyph(font as CTFont, glyph, nil) else { continue }

                // Outlines are y-up from the baseline; the box's space is y-down from the top.
                let transform = CGAffineTransform(
                    a: 1, b: 0, c: 0, d: -1,
                    tx: fragment.origin.x + location.x,
                    ty: fragment.origin.y + location.y
                )
                result.addPath(outline, transform: transform)
            }

            // Underline isn't part of a glyph outline, so lay a rule under each line by hand, using
            // the font's own position and thickness. The used rect counts the container's line
            // fragment padding on both sides; the rule should span the glyphs alone.
            let padding = container.lineFragmentPadding
            if underline, let lineFont, let baseline, usedRect.width > padding * 2 {
                let thickness = Swift.max(1, lineFont.underlineThickness)
                result.addRect(CGRect(
                    x: usedRect.minX + padding,
                    y: baseline - lineFont.underlinePosition - thickness / 2,
                    width: usedRect.width - padding * 2,
                    height: thickness
                ))
            }
        }
        return result
    }
}
