//
//  OverlayCardLayoutStore.swift
//  Screendrop
//
//  Observable, UserDefaults-backed store for the preview card layout. Both the
//  live overlay (`PreviewCardView`) and the settings editor read/write the same
//  shared instance, so edits apply to the floating card immediately.
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

    func reset() {
        layout = .default
    }

    // MARK: - Persistence

    private static func load() -> OverlayCardLayout {
        guard
            let data = UserDefaults.standard.data(forKey: ScreendropPreferences.overlayCardLayoutKey),
            let decoded = try? JSONDecoder().decode(OverlayCardLayout.self, from: data)
        else {
            return .default
        }

        // Surface Basket for users who still have the previous untouched
        // default. Never rearrange a layout the user has customized.
        if isLegacyDefault(decoded) {
            return .default
        }

        return decoded.normalized()
    }

    private static func isLegacyDefault(_ layout: OverlayCardLayout) -> Bool {
        layout.topLeading == .delete
            && layout.topTrailing == .close
            && layout.bottomLeading == .annotate
            && layout.bottomTrailing == .upload
            && layout.center == [.copy, .save, .pin]
            && layout.hidden == [.view, .compress]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: ScreendropPreferences.overlayCardLayoutKey)
    }
}
