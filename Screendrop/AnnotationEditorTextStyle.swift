//
//  AnnotationEditorTextStyle.swift
//  Screendrop
//

import AppKit
import CoreGraphics

extension AnnotationEditorModel {
    var selectedTextFontSize: CGFloat {
        get {
            guard let item = selectedTextItem else { return textFontSize }
            return AnnotationTextMetrics.renderedFontSize(
                lineHeight: item.textLineHeight,
                imagePixelHeight: imageSize.height
            ).rounded()
        }
        set {
            setTextFontSize(newValue)
        }
    }

    var selectedTextFontName: String {
        get { selectedTextItem?.fontName ?? textFontName }
        set { setTextFontName(newValue) }
    }

    var selectedTextIsBold: Bool {
        get { selectedTextItem?.isBold ?? textIsBold }
        set { setTextBold(newValue) }
    }

    var selectedTextIsItalic: Bool {
        get { selectedTextItem?.isItalic ?? textIsItalic }
        set { setTextItalic(newValue) }
    }

    var selectedTextIsUnderline: Bool {
        get { selectedTextItem?.isUnderline ?? textIsUnderline }
        set { setTextUnderline(newValue) }
    }

    var selectedTextAlignment: NSTextAlignment {
        get { selectedTextItem?.textAlignment ?? textAlignment }
        set { setTextAlignment(newValue) }
    }

    var isTextStyleAvailable: Bool {
        selectedTool == .text || selectedTextItem != nil
    }

    private var selectedTextItem: AnnotationItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID && $0.tool == .text }
    }

    func setTextFontSize(_ pointSize: CGFloat) {
        let clamped = max(pointSize, AnnotationTextMetrics.minimumFontSize)
        textFontSize = clamped
        saveAnnotationPreset()

        guard let selectedItemID, selectedTextItem != nil else { return }
        guard imageSize.height > 0 else { return }
        let newLineHeight = clamped / (imageSize.height * AnnotationTextMetrics.fontScale)
        registerItemEdit()
        updateItem(id: selectedItemID) { item in
            item.textLineHeight = newLineHeight
        }
    }

    func setTextFontName(_ name: String) {
        textFontName = name
        saveAnnotationPreset()
        guard let selectedItemID, selectedTextItem != nil else { return }
        registerItemEdit()
        updateItem(id: selectedItemID) { item in
            item.fontName = name
        }
    }

    func setTextBold(_ bold: Bool) {
        textIsBold = bold
        saveAnnotationPreset()
        guard let selectedItemID, selectedTextItem != nil else { return }
        registerItemEdit()
        updateItem(id: selectedItemID) { item in
            item.isBold = bold
        }
    }

    func setTextItalic(_ italic: Bool) {
        textIsItalic = italic
        saveAnnotationPreset()
        guard let selectedItemID, selectedTextItem != nil else { return }
        registerItemEdit()
        updateItem(id: selectedItemID) { item in
            item.isItalic = italic
        }
    }

    func setTextUnderline(_ underline: Bool) {
        textIsUnderline = underline
        saveAnnotationPreset()
        guard let selectedItemID, selectedTextItem != nil else { return }
        registerItemEdit()
        updateItem(id: selectedItemID) { item in
            item.isUnderline = underline
        }
    }

    func setTextAlignment(_ alignment: NSTextAlignment) {
        textAlignment = alignment
        saveAnnotationPreset()
        guard let selectedItemID, selectedTextItem != nil else { return }
        registerItemEdit()
        updateItem(id: selectedItemID) { item in
            item.textAlignment = alignment
        }
    }

    func commitTextEditing() {
        guard let editingTextItemID else { return }

        if let item = items.first(where: { $0.id == editingTextItemID }),
           item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.removeAll { $0.id == editingTextItemID }
            selectedItemIDs.remove(editingTextItemID)
        }

        self.editingTextItemID = nil
    }
}
