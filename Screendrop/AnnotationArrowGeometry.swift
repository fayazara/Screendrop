//
//  AnnotationArrowGeometry.swift
//  Screendrop
//

import CoreGraphics

struct AnnotationArrowGeometry {
    let tip: CGPoint
    let shaftControl: CGPoint
    let firstWing: CGPoint
    let secondWing: CGPoint

    init?(start: CGPoint, control: CGPoint, end: CGPoint, lineWidth: CGFloat) {
        let curveLength = Self.approximateCurveLength(start: start, control: control, end: end)
        guard curveLength > 0.5 else { return nil }

        let tangent = Self.tangent(start: start, control: control, end: end)
        let tangentLength = hypot(tangent.x, tangent.y)
        guard tangentLength > 0.5 else { return nil }

        let direction = CGPoint(x: tangent.x / tangentLength, y: tangent.y / tangentLength)
        let backwardDirection = CGPoint(x: -direction.x, y: -direction.y)
        let headLength = min(max(13, lineWidth * 4.4), curveLength * 0.34)
        let headAngle = CGFloat.pi * 0.2
        let firstDirection = Self.rotate(backwardDirection, by: headAngle)
        let secondDirection = Self.rotate(backwardDirection, by: -headAngle)

        tip = end
        shaftControl = control
        firstWing = CGPoint(
            x: end.x + firstDirection.x * headLength,
            y: end.y + firstDirection.y * headLength
        )
        secondWing = CGPoint(
            x: end.x + secondDirection.x * headLength,
            y: end.y + secondDirection.y * headLength
        )
    }

    private static func approximateCurveLength(start: CGPoint, control: CGPoint, end: CGPoint) -> CGFloat {
        var length: CGFloat = 0
        var previous = start

        for step in 1...24 {
            let point = quadraticPoint(start: start, control: control, end: end, t: CGFloat(step) / 24)
            length += hypot(point.x - previous.x, point.y - previous.y)
            previous = point
        }

        return length
    }

    private static func quadraticPoint(start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
        let first = lerp(start, control, t)
        let second = lerp(control, end, t)
        return lerp(first, second, t)
    }

    private static func tangent(start: CGPoint, control: CGPoint, end: CGPoint) -> CGPoint {
        let tangent = CGPoint(
            x: 2 * (end.x - control.x),
            y: 2 * (end.y - control.y)
        )

        if hypot(tangent.x, tangent.y) > 0.5 {
            return tangent
        }

        return CGPoint(
            x: end.x - start.x,
            y: end.y - start.y
        )
    }

    private static func rotate(_ point: CGPoint, by angle: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x * cos(angle) - point.y * sin(angle),
            y: point.x * sin(angle) + point.y * cos(angle)
        )
    }

    private static func lerp(_ lhs: CGPoint, _ rhs: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(
            x: lhs.x + (rhs.x - lhs.x) * t,
            y: lhs.y + (rhs.y - lhs.y) * t
        )
    }
}
