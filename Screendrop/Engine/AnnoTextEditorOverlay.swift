import AppKit
import Foundation

/// A text view laid over the canvas while a text shape is being edited.
///
/// The canvas skips drawing the shape while this is up, so what you see is the live text view.
/// Using a real `NSTextView` means selection, arrow keys, IME and system text services all work,
/// rather than reimplementing them against a hand-rolled caret.
///
/// Ported from the drawing-app's `UI/TextEditorOverlay.swift`.
@MainActor
final class AnnoTextEditorOverlay: NSTextView {
    private weak var editor: AnnoEditor?
    private var shapeId: AnnoShapeID?

    /// Which shape this caret belongs to, so the canvas can tell a retarget from a no-op.
    var editedShapeId: AnnoShapeID? { shapeId }

    /// The layout manager built in `init(editor:shapeId:)`, which draws the outline.
    private var outlineLayoutManager: AnnoTextEditorLayoutManager? {
        layoutManager as? AnnoTextEditorLayoutManager
    }

    /// `NSTextView.init(frame:)` is a convenience initializer that builds the text network and then
    /// routes through this designated one, so a subclass has to implement it - otherwise the
    /// runtime traps on an unimplemented initializer.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    convenience init(editor: AnnoEditor, shapeId: AnnoShapeID) {
        // Build the text network by hand rather than going through `init(frame:)`, which Swift no
        // longer inherits now that the designated initializer above is overridden.
        let storage = NSTextStorage()
        let layoutManager = AnnoTextEditorLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)

        self.init(frame: .zero, textContainer: container)
        self.editor = editor
        self.shapeId = shapeId
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = true
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        // The shape owns wrapping: it measures the text and sets the frame, so the container must
        // not impose a width of its own.
        textContainer?.widthTracksTextView = false
        allowsUndo = false
        focusRingType = .none
        delegate = self
    }

    /// Style and position the overlay to sit exactly where the shape is drawn.
    func sync() {
        guard let editor, let shapeId,
              let shape = editor.document.shape(shapeId),
              let props = shape.textProps else { return }

        let zoom = editor.viewport.scale
        // The overlay lays out in view points, so scale the shape's page-space type up by the
        // camera before styling.
        var viewProps = props
        viewProps.fontSize = Swift.max(1, props.fontSize * zoom)
        viewProps.w = props.w * zoom
        // The outline width is stored in page pixels like the font size; scale it by the camera
        // too, so the container padding and the layout manager's stroke below - all derived from
        // `viewProps` - come out in view points.
        viewProps.outline?.width *= zoom

        let fontSize = CGFloat(viewProps.fontSize)
        let font = TextMeasure.font(viewProps, opticalSize: props.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = props.align.nsTextAlignment
        paragraph.minimumLineHeight = TextMeasure.lineHeight(viewProps)
        paragraph.maximumLineHeight = TextMeasure.lineHeight(viewProps)
        paragraph.lineBreakMode = .byWordWrapping

        // Outlined text draws its own underline (see `AnnoTextEditorLayoutManager`), so AppKit's
        // rule is only asked for when there is no outline to keep it in step with.
        let outlineColor = props.activeOutline?.swatch.nsColor
        let drawsOwnUnderline = props.isUnderline && outlineColor != nil

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: props.swatch.nsColor,
        ]
        if props.isUnderline, !drawsOwnUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        typingAttributes = attributes
        defaultParagraphStyle = paragraph
        self.font = font
        textColor = props.swatch.nsColor
        alignment = paragraph.alignment
        insertionPointColor = props.swatch.nsColor
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }

        if let outlineLayoutManager {
            outlineLayoutManager.outlineColor = outlineColor
            outlineLayoutManager.outlineStrokeWidth = TextMeasure.outlineStrokeWidth(viewProps)
            outlineLayoutManager.outlinesUnderline = props.isUnderline
            outlineLayoutManager.underlineColor = drawsOwnUnderline ? props.swatch.nsColor : nil
        }
        // The outline reaches past the glyphs on every side, and the text view clips its text to
        // the container, so pad the container by the visible width: line fragment padding at the
        // sides, the container inset above and below. Whole points, because AppKit floors the
        // inset when it places the container and the frame offset below has to match it exactly
        // or the text lands a fraction off where it commits.
        let outlinePad = ceil(TextMeasure.outlineWidth(viewProps))
        textContainerInset = NSSize(width: 0, height: outlinePad)
        textContainer?.lineFragmentPadding = outlinePad

        // The shape's box in view space. The glyphs' origin - the frame origin plus the padding,
        // turned through the shape's rotation - lands on the shape's local origin, which is what
        // `frameRotation` turns about.
        let bounds = editor.document.geometry(shape).bounds
        let origin = editor.pageToScreen(Vec(shape.x, shape.y))
        let cosine = cos(shape.rotation)
        let sine = sin(shape.rotation)
        let frameOrigin = CGPoint(
            x: origin.x - (outlinePad * cosine - outlinePad * sine),
            y: origin.y - (outlinePad * sine + outlinePad * cosine)
        )
        var width = Swift.max(bounds.w * zoom, Double(fontSize) * 0.6) + outlinePad * 2
        var height = Swift.max(bounds.h * zoom, Double(TextMeasure.lineHeight(viewProps))) + outlinePad * 2

        if props.autoSize, let container = textContainer, let layoutManager {
            // Auto-sizing text must never wrap. Sizing the container from the shape's measured
            // width wraps the moment a keystroke outgrows it - the shape only re-measures *after*
            // the text view has already laid out. Worse, the shape is measured at the page font
            // size while the overlay lays out at `fontSize * zoom`, and those don't scale exactly.
            //
            // So: lay out unconstrained to find the text's natural width, then set the container to
            // exactly that. Nothing can wrap, and alignment still has a real width to work in.
            container.size = CGSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
            // The used rect already counts the line fragment padding on both sides.
            let used = layoutManager.usedRect(for: container)
            let natural = ceil(used.width)
            container.size = CGSize(width: natural + 2, height: CGFloat.greatestFiniteMagnitude)
            // Leave room for the caret past the last glyph.
            width = Swift.max(width, Double(natural + fontSize * 0.5))
            height = Swift.max(height, Double(ceil(used.height)) + outlinePad * 2)
        } else {
            // Padded the same way, so the text still wraps at the shape's width.
            textContainer?.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }

        frameRotation = 0
        frame = CGRect(x: frameOrigin.x, y: frameOrigin.y, width: width, height: height)
        // The canvas is flipped, so a positive rotation reads clockwise on screen - the same
        // direction a positive `shape.rotation` turns the drawn shape.
        frameRotation = shape.rotation * 180 / .pi
        // The text view only invalidates the glyphs that changed; the outline around them reaches
        // a little further, so repaint the whole (small) view rather than leave slivers behind.
        needsDisplay = true
    }

    func loadText() {
        guard let editor, let shapeId,
              let props = editor.document.shape(shapeId)?.textProps else { return }
        string = props.text
        sync()
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
    }

    /// Draw the caret's text the way the canvas draws committed text: plain antialiasing, no font
    /// smoothing. AppKit stem-darkens light text on a dark background, which made type look
    /// noticeably heavier while editing than it did the moment it committed - and heavier than the
    /// exported PNG, which is the side that has to be right.
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        super.draw(dirtyRect)
    }

    override func cancelOperation(_ sender: Any?) {
        editor?.stopEditingText()
    }
}

/// Draws the outline under the caret's text the way the canvas will once it commits: the same
/// glyph tracing and the same width, scaled by the camera.
///
/// It lives in the layout manager rather than the view's `draw(_:)` so it can go down after the
/// selection highlight and before the glyphs - stroked from the view, it would sit under the
/// highlight and vanish for whatever is selected. Tracing this view's own layout rather than the
/// shape's keeps the edge on the glyphs the caret is actually moving through.
@MainActor
private final class AnnoTextEditorLayoutManager: NSLayoutManager {
    /// `nil` when the text has no outline.
    var outlineColor: NSColor?
    /// Already doubled, per `TextMeasure.outlineStrokeWidth`; view points.
    var outlineStrokeWidth: CGFloat = 0
    /// Whether the underline rule is traced into the outline as well.
    var outlinesUnderline = false
    /// When set, the underline is filled here over the glyphs instead of by AppKit, so the rule
    /// the outline was traced around is the rule that gets drawn.
    var underlineColor: NSColor?

    private var isOutlining: Bool {
        outlineColor != nil && outlineStrokeWidth > 0 && (textStorage?.length ?? 0) > 0
    }

    /// Stroke first, let AppKit fill the glyphs on top, then lay the rule over both. The text view
    /// clips all of this to the container, which is why `sync()` pads the container rather than
    /// just the frame.
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard isOutlining, let outlineColor, let storage = textStorage, let container = textContainers.first,
              let context = NSGraphicsContext.current?.cgContext else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        let glyphs = TextMeasure.glyphPath(in: self, storage: storage, container: container, underline: outlinesUnderline)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.addPath(glyphs)
        context.setStrokeColor(outlineColor.cgColor)
        context.setLineWidth(outlineStrokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()

        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)

        if let underlineColor {
            let rules = TextMeasure.underlinePath(in: self, storage: storage, container: container)
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y)
            context.addPath(rules)
            context.setFillColor(underlineColor.cgColor)
            context.fillPath()
            context.restoreGState()
        }
    }
}

extension AnnoTextEditorOverlay: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let shapeId else { return }
        editor?.updateEditingText(shapeId, to: string)
        // The shape may have grown or moved to keep its alignment anchor; follow it.
        sync()
    }
}
