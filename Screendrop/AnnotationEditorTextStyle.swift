//
//  AnnotationEditorTextStyle.swift
//  Screendrop
//

import AppKit
import CoreGraphics

/// The inspector's text controls. Each setter updates the style new text will use *and* whatever
/// text is selected; the engine re-measures the box from the same layout the glyphs come from, so
/// a font change reflows it without a round trip through a text view.
extension AnnotationEditorModel {
    private var selectedTextShape: AnnoShape? {
        guard engine.selectedIds.count == 1, let shape = engine.selectedShapes.first, shape.isText else {
            return nil
        }
        return shape
    }

    var isTextStyleAvailable: Bool {
        if !engine.selectedIds.isEmpty { return selectedTextShape != nil }
        return selectedTool == .text
    }

    var selectedTextFontSize: CGFloat {
        get { selectedTextShape?.textProps.map { CGFloat($0.fontSize) } ?? textFontSize }
        set { setTextFontSize(newValue) }
    }

    var selectedTextFontFamily: AnnoFontFamily {
        get { selectedTextShape?.textProps?.fontFamily ?? textFontFamily }
        set { setTextFontFamily(newValue) }
    }

    var selectedTextIsBold: Bool {
        get { selectedTextShape?.textProps?.isBold ?? textIsBold }
        set { setTextBold(newValue) }
    }

    var selectedTextIsItalic: Bool {
        get { selectedTextShape?.textProps?.isItalic ?? textIsItalic }
        set { setTextItalic(newValue) }
    }

    var selectedTextIsUnderline: Bool {
        get { selectedTextShape?.textProps?.isUnderline ?? textIsUnderline }
        set { setTextUnderline(newValue) }
    }

    var selectedTextAlignment: NSTextAlignment {
        get { selectedTextShape?.textProps?.align.nsTextAlignment ?? textAlignment }
        set { setTextAlignment(newValue) }
    }

    var selectedTextOutlineEnabled: Bool {
        get {
            // The engine isn't observable; reading `revision` is what re-runs the controls when
            // a tap lands on the selected shape (the stand-in `hasUnsavedChanges` documents).
            // Without it, enabling the outline mutates the shape but the swatch strip and width
            // slider only appear on the next selection change.
            _ = revision
            return selectedTextShape?.textProps.map { $0.activeOutline != nil } ?? textOutlineEnabled
        }
        set { setTextOutlineEnabled(newValue) }
    }

    var selectedTextOutlineSwatch: AnnotationSwatch {
        get {
            _ = revision
            return selectedTextShape?.textProps?.activeOutline?.swatch ?? textOutlineSwatch
        }
        set { setTextOutlineSwatch(newValue) }
    }

    var selectedTextOutlineWidth: CGFloat {
        get {
            _ = revision
            return selectedTextShape?.textProps?.activeOutline.map { CGFloat($0.width) } ?? textOutlineWidth
        }
        set { setTextOutlineWidth(newValue) }
    }

    func setTextFontSize(_ pointSize: CGFloat) {
        let clamped = max(pointSize, 4)
        textFontSize = clamped
        engine.currentTextFontSize = Double(clamped)
        saveAnnotationPreset()
        updateSelectedText { $0.fontSize = Double(clamped) }
    }

    func setTextFontFamily(_ family: AnnoFontFamily) {
        textFontFamily = family
        engine.currentFontFamily = family
        saveAnnotationPreset()
        updateSelectedText { $0.fontFamily = family }
    }

    func setTextBold(_ bold: Bool) {
        textIsBold = bold
        engine.currentTextIsBold = bold
        saveAnnotationPreset()
        updateSelectedText { $0.isBold = bold }
    }

    func setTextItalic(_ italic: Bool) {
        textIsItalic = italic
        engine.currentTextIsItalic = italic
        saveAnnotationPreset()
        updateSelectedText { $0.isItalic = italic }
    }

    func setTextUnderline(_ underline: Bool) {
        textIsUnderline = underline
        engine.currentTextIsUnderline = underline
        saveAnnotationPreset()
        updateSelectedText { $0.isUnderline = underline }
    }

    func setTextAlignment(_ alignment: NSTextAlignment) {
        textAlignment = alignment
        engine.currentTextAlign = TextAlign(alignment)
        saveAnnotationPreset()
        updateSelectedText { $0.align = TextAlign(alignment) }
    }

    func setTextOutlineEnabled(_ enabled: Bool) {
        adoptSelectedTextOutline()
        textOutlineEnabled = enabled
        if enabled, textOutlineWidth <= 0 {
            // First enable: seed the width from the type it will wrap. After that the remembered
            // pixel value wins, so toggling the outline off and back on round-trips.
            textOutlineWidth = CGFloat(TextOutline.defaultWidth(forFontSize: Double(selectedTextFontSize)))
        }
        applyTextOutline()
    }

    func setTextOutlineSwatch(_ swatch: AnnotationSwatch) {
        adoptSelectedTextOutline()
        textOutlineSwatch = swatch
        applyTextOutline()
    }

    func setTextOutlineWidth(_ width: CGFloat) {
        adoptSelectedTextOutline()
        // Whole pixels: the slider scrubs continuously but the value reads "N px", so store what
        // the field shows (the font size field commits the same way).
        let range = TextOutline.widthRange
        textOutlineWidth = min(max(width.rounded(), CGFloat(range.lowerBound)), CGFloat(range.upperBound))
        applyTextOutline()
    }

    /// The remembered fields can go stale against the selection: undo, redo and select-all change
    /// what is selected without running `syncStyleFromSelection`. Adopt the selected shape's
    /// outline before deriving a new one from the fields, so a swatch or width tap edits the
    /// outline the user is looking at instead of replacing - or, with a stale "off" - deleting it.
    private func adoptSelectedTextOutline() {
        guard let props = selectedTextShape?.textProps else { return }
        if let outline = props.activeOutline {
            textOutlineEnabled = true
            textOutlineSwatch = outline.swatch
            textOutlineWidth = CGFloat(outline.width)
        } else {
            textOutlineEnabled = false
        }
    }

    private func applyTextOutline() {
        let outline = textOutline
        // The new-text default and the selected document can disagree - undo reverts the shape
        // but not `engine.currentTextOutline` - so compare the two sides separately: a value the
        // shape already holds must not record a no-op undo step (the slider's whole-pixel
        // rounding collapses drag samples onto the same value), and a shape-side no-op must
        // still pull the default back in line. The preset saves on either change: the composed
        // `outline` is nil whenever the edge is off, so turning a selected shape's outline off
        // can leave the default at nil == nil while the remembered swatch and width - which the
        // preset alone persists - just changed.
        let defaultNeedsUpdate = engine.currentTextOutline != outline
        let selectionNeedsUpdate = selectedTextShape != nil
            && selectedTextShape?.textProps?.outline != outline
        if defaultNeedsUpdate {
            engine.currentTextOutline = outline
        }
        if defaultNeedsUpdate || selectionNeedsUpdate {
            saveAnnotationPreset()
        }
        guard selectionNeedsUpdate else { return }
        updateSelectedText { $0.outline = outline }
    }

    private func updateSelectedText(_ mutate: (inout TextProps) -> Void) {
        guard selectedTextShape != nil else { return }
        engine.applyStyleToSelection { shape in
            guard case var .text(props) = shape.kind else { return }
            mutate(&props)
            shape.kind = .text(props)
        }
    }
}
