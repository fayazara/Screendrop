//
//  AnnotationCropOverlay.swift
//  Screendrop
//
//  Crop mode's drawing: the dimmed outside, the box, its handles and, while
//  dragging, a rule-of-thirds grid. It takes no input; the canvas routes
//  presses to the model, which hit-tests the same geometry
//  (AnnotationEditorCrop.swift).
//
//  The handles sit inside the box, so a box edge at the viewport's edge
//  still shows its corner and stays grabbable when zoomed in. Every layer is
//  an animatable shape over the same rects, so the box moves as one piece
//  with the image.
//

import SwiftUI

/// Shared coordinate-space name for the canvas's viewport points.
enum AnnotationCanvasCoordinateSpace {
    static let name = "AnnotationCanvasSpace"
}

struct AnnotationCropOverlay: View {
    let model: AnnotationEditorModel
    /// The on-screen rect (viewport points) the image occupies.
    let imageFrame: CGRect
    /// The part of the viewport not covered by floating chrome. Edge handles
    /// sit in the middle of the part of their edge that is in it.
    let visibleRect: CGRect

    var body: some View {
        let box = model.cropViewRect(in: imageFrame)

        ZStack(alignment: .topLeading) {
            CropDimShape(imageFrame: imageFrame, cropFrame: box)
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

            CropGridShape(cropFrame: box)
                .stroke(Color.white.opacity(0.45), lineWidth: 0.75)
                .animation(.easeOut(duration: 0.18)) { $0.opacity(model.isCropDragging ? 1 : 0) }

            CropBorderShape(cropFrame: box)
                .stroke(Color.white.opacity(0.95), lineWidth: 1)
                .shadow(color: .black.opacity(0.35), radius: 1)

            CropHandlesShape(cropFrame: box, visibleRect: visibleRect)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// The image with the crop box cut out, in viewport points.
private struct CropDimShape: Shape {
    var imageFrame: CGRect
    var cropFrame: CGRect

    var animatableData: AnimatablePair<CGRect.AnimatableData, CGRect.AnimatableData> {
        get { AnimatablePair(imageFrame.animatableData, cropFrame.animatableData) }
        set {
            imageFrame.animatableData = newValue.first
            cropFrame.animatableData = newValue.second
        }
    }

    func path(in _: CGRect) -> Path {
        var path = Path()
        path.addRect(imageFrame)
        path.addRect(cropFrame)
        return path
    }
}

/// Rule-of-thirds lines across the crop box.
private struct CropGridShape: Shape {
    var cropFrame: CGRect

    var animatableData: CGRect.AnimatableData {
        get { cropFrame.animatableData }
        set { cropFrame.animatableData = newValue }
    }

    func path(in _: CGRect) -> Path {
        var path = Path()
        let rect = cropFrame
        for index in 1...2 {
            let x = rect.minX + rect.width * CGFloat(index) / 3
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))

            let y = rect.minY + rect.height * CGFloat(index) / 3
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

/// The box's outline, drawn just inside its edge.
private struct CropBorderShape: Shape {
    var cropFrame: CGRect

    var animatableData: CGRect.AnimatableData {
        get { cropFrame.animatableData }
        set { cropFrame.animatableData = newValue }
    }

    func path(in _: CGRect) -> Path {
        Path(cropFrame.insetBy(dx: 0.5, dy: 0.5))
    }
}

/// Corner brackets and mid-edge bars, all inside the box.
private struct CropHandlesShape: Shape {
    var cropFrame: CGRect
    let visibleRect: CGRect

    static let thickness: CGFloat = 3
    static let armLength: CGFloat = 20
    static let barLength: CGFloat = 24

    var animatableData: CGRect.AnimatableData {
        get { cropFrame.animatableData }
        set { cropFrame.animatableData = newValue }
    }

    func path(in _: CGRect) -> Path {
        let box = cropFrame.standardized
        guard box.width > 0, box.height > 0 else { return Path() }
        let thickness = min(Self.thickness, box.width / 4, box.height / 4)
        // Arms shrink on a small box so the brackets never meet.
        let arm = min(Self.armLength, box.width / 3, box.height / 3)

        var path = Path()
        for handle in CropHandle.allCases where handle.isCorner {
            let x = handle.xDirection < 0 ? box.minX : box.maxX
            let y = handle.yDirection < 0 ? box.minY : box.maxY
            let inwardX: CGFloat = handle.xDirection < 0 ? 1 : -1
            let inwardY: CGFloat = handle.yDirection < 0 ? 1 : -1
            path.addRect(CGRect(x: x, y: y, width: arm * inwardX, height: thickness * inwardY).standardized)
            path.addRect(CGRect(x: x, y: y, width: thickness * inwardX, height: arm * inwardY).standardized)
        }

        // A bar needs room clear of both brackets on the visible stretch.
        let clearance = Self.barLength + 2 * (arm + 8)
        for handle in CropHandle.allCases where !handle.isCorner {
            if handle.yDirection != 0 {
                let y = handle.yDirection < 0 ? box.minY : box.maxY
                let lower = max(box.minX, visibleRect.minX)
                let upper = min(box.maxX, visibleRect.maxX)
                guard (visibleRect.minY...visibleRect.maxY).contains(y), upper - lower >= clearance else { continue }
                let inward: CGFloat = handle.yDirection < 0 ? 1 : -1
                path.addRoundedRect(
                    in: CGRect(x: (lower + upper - Self.barLength) / 2, y: y, width: Self.barLength, height: thickness * inward)
                        .standardized,
                    cornerSize: CGSize(width: thickness / 2, height: thickness / 2)
                )
            } else {
                let x = handle.xDirection < 0 ? box.minX : box.maxX
                let lower = max(box.minY, visibleRect.minY)
                let upper = min(box.maxY, visibleRect.maxY)
                guard (visibleRect.minX...visibleRect.maxX).contains(x), upper - lower >= clearance else { continue }
                let inward: CGFloat = handle.xDirection < 0 ? 1 : -1
                path.addRoundedRect(
                    in: CGRect(x: x, y: (lower + upper - Self.barLength) / 2, width: thickness * inward, height: Self.barLength)
                        .standardized,
                    cornerSize: CGSize(width: thickness / 2, height: thickness / 2)
                )
            }
        }
        return path
    }
}
