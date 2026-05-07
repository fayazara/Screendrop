//
//  VideoTrimSelection.swift
//  OpenShot
//

import Foundation

struct VideoTrimSelection: Equatable, Sendable {
    static let minimumDuration: Double = 0.25

    var start: Double
    var end: Double

    var duration: Double {
        max(0, end - start)
    }

    func clamped(to mediaDuration: Double) -> VideoTrimSelection {
        guard mediaDuration > 0 else {
            return VideoTrimSelection(start: 0, end: 0)
        }

        let safeStart = min(max(start, 0), mediaDuration)
        let minimumEnd = min(mediaDuration, safeStart + Self.minimumDuration)
        let safeEnd = min(max(end, minimumEnd), mediaDuration)
        return VideoTrimSelection(start: safeStart, end: safeEnd)
    }
}
