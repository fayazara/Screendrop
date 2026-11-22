//
//  OverlayCardLayoutStore.swift
//  Screendrop
//
//  Observable, UserDefaults-backed store for the capture card layout. The live
//  cards (`CaptureShelfCard`) and the Settings editor share this instance, so
//  edits apply to cards on screen immediately.
//

import Foundation
import Observation

@MainActor
@Observable
final class OverlayCardLayoutStore {
    static let shared = OverlayCardLayoutStore()

    var layout: OverlayCardLayout {
        didSet { persist() }
    }

    private init() {
        layout = Self.load()
    }

    var isDefault: Bool { layout == OverlayCardLayout.default.normalized() }

    func reset() {
        layout = OverlayCardLayout.default.normalized()
    }

    // MARK: - Persistence

    private static func load() -> OverlayCardLayout {
        guard
            let data = UserDefaults.standard.data(forKey: ScreendropPreferences.overlayCardLayoutKey),
            let decoded = try? JSONDecoder().decode(OverlayCardLayout.self, from: data)
        else {
            return .default
        }
        return decoded.normalized()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: ScreendropPreferences.overlayCardLayoutKey)
    }
}
