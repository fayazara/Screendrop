//
//  AnnotationSelectionViews.swift
//  Screendrop
//

import SwiftUI

struct SelectionFrame: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .stroke(AnnotationSelectionStyle.color, lineWidth: 2)

                SelectionHandle().position(x: 0, y: 0)
                SelectionHandle().position(x: proxy.size.width, y: 0)
                SelectionHandle().position(x: 0, y: proxy.size.height)
                SelectionHandle().position(x: proxy.size.width, y: proxy.size.height)
            }
        }
    }
}

struct TextSelectionFrame: View {
    var body: some View {
        Rectangle()
            .stroke(AnnotationSelectionStyle.color, lineWidth: 1.5)
    }
}

struct SelectionOutlineFrame: View {
    var body: some View {
        Rectangle()
            .stroke(AnnotationSelectionStyle.color, lineWidth: 1.5)
    }
}

struct SelectionHandle: View {
    var body: some View {
        Circle()
            .fill(AnnotationSelectionStyle.color)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
    }
}

struct CurveControlHandle: View {
    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(AnnotationSelectionStyle.color, lineWidth: 2))
            .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
    }
}

enum AnnotationSelectionStyle {
    static let color = Color.accentColor.opacity(0.5)
}
