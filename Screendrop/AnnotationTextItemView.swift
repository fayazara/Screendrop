//
//  AnnotationTextItemView.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct AnnotationTextItemView: View {
    let item: AnnotationItem
    let text: Binding<String>
    let viewBounds: CGRect
    let imageFrameHeight: CGFloat
    let isEditing: Bool
    let onCommit: () -> Void
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        AnnotationTextBoxView(
            text: text,
            font: item.resolvedFont(size: fontSize),
            textColor: item.swatch.nsColor,
            shadow: AnnotationTextMetrics.textShadow,
            isUnderline: item.isUnderline,
            alignment: item.textAlignment,
            isEditing: isEditing,
            onCommit: onCommit,
            onSizeChange: onSizeChange
        )
        .frame(width: max(viewBounds.width, 1), height: max(viewBounds.height, 1))
        .position(x: viewBounds.midX, y: viewBounds.midY)
    }

    private var fontSize: CGFloat {
        AnnotationTextMetrics.viewFontSize(lineHeight: item.textLineHeight, imageFrameHeight: imageFrameHeight)
    }
}

private struct AnnotationTextBoxView: NSViewRepresentable {
    @Binding var text: String

    let font: NSFont
    let textColor: NSColor
    let shadow: NSShadow
    let isUnderline: Bool
    let alignment: NSTextAlignment
    let isEditing: Bool
    let onCommit: () -> Void
    let onSizeChange: (CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onSizeChange: onSizeChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = isEditing
        textView.isSelectable = isEditing
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = CGSize(
            width: 1,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineBreakMode = .byClipping
        textView.autoresizingMask = [.width, .height]
        textView.insertionPointColor = NSColor.systemBlue
        textView.backgroundColor = .clear
        textView.string = text
        applyStyle(to: textView)

        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.autoresizesSubviews = true

        context.coordinator.textView = textView

        if isEditing {
            DispatchQueue.main.async {
                self.updateTextViewFrame(textView, in: scrollView)
                textView.window?.makeFirstResponder(textView)
                self.reportSize(textView)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        context.coordinator.onSizeChange = onSizeChange

        textView.isEditable = isEditing
        textView.isSelectable = isEditing
        updateTextViewFrame(textView, in: scrollView)

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }

        applyStyle(to: textView)

        if isEditing && textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        } else if !isEditing && textView.window?.firstResponder === textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(nil)
            }
        }

        DispatchQueue.main.async {
            self.reportSize(textView)
        }
    }

    private func reportSize(_ textView: NSTextView) {
        onSizeChange(Self.measuredTextSize(for: textView))
    }

    private func updateTextViewFrame(_ textView: NSTextView, in scrollView: NSScrollView) {
        let size = CGSize(
            width: max(scrollView.bounds.width, 1),
            height: max(scrollView.bounds.height, 1)
        )
        if textView.frame.size != size {
            textView.frame = CGRect(origin: .zero, size: size)
        }
        textView.textContainer?.containerSize = CGSize(
            width: size.width,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private static func measuredTextSize(for textView: NSTextView) -> CGSize {
        let font = textView.font ?? NSFont.systemFont(ofSize: AnnotationTextMetrics.minimumFontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let lineCount = CGFloat(AnnotationTextMetrics.lineCount(for: textView.string))
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byClipping

        var attributes = textView.typingAttributes
        attributes[.font] = font
        attributes[.paragraphStyle] = paragraphStyle

        let measuredString = textView.string.isEmpty ? " " : textView.string
        let rect = NSAttributedString(string: measuredString, attributes: attributes).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(
            width: ceil(rect.width) + 2,
            height: max(ceil(rect.height), lineHeight * lineCount)
        )
    }

    private func applyStyle(to textView: NSTextView) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byClipping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
            .shadow: shadow
        ]
        if isUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        textView.font = font
        textView.textColor = textColor
        textView.alignment = alignment
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = attributes
        textView.textContainer?.lineBreakMode = .byClipping

        guard textView.string.isEmpty == false else { return }

        let selectedRanges = textView.selectedRanges
        textView.textStorage?.setAttributes(
            attributes,
            range: NSRange(location: 0, length: (textView.string as NSString).length)
        )
        textView.selectedRanges = selectedRanges
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onCommit: () -> Void
        var onSizeChange: (CGSize) -> Void
        weak var textView: NSTextView?

        init(text: Binding<String>, onCommit: @escaping () -> Void, onSizeChange: @escaping (CGSize) -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onSizeChange = onSizeChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            reportSize(textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            onCommit()
        }

        private func reportSize(_ textView: NSTextView) {
            onSizeChange(AnnotationTextBoxView.measuredTextSize(for: textView))
        }
    }
}
