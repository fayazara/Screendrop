//
//  PreviewPlacementStore.swift
//  Screendrop
//  Contributed by Rochak Agrawal (Screenshot X).
//
//  Remembers how far the floating preview was moved from its natural place.
//  The natural place is the captured region itself — for an area capture the
//  preview starts exactly on the selection, at the selection's size — so a
//  drag is remembered relative to the area rather than as a fixed screen
//  corner. That keeps "put it back where I left it" working without throwing
//  away the connection to what was captured.
//

import AppKit

enum PreviewPlacementStore {
    /// Two doubles: the x and y offset in points from the natural origin.
    private static let key = "previewDragOffset"
    /// The old absolute anchor written before placement was region-relative.
    private static let legacyKey = "previewFloatingAnchor"

    static func load() -> CGSize? {
        guard let values = UserDefaults.standard.array(forKey: key) as? [Double], values.count == 2 else {
            return nil
        }
        return CGSize(width: values[0], height: values[1])
    }

    static func save(_ offset: CGSize) {
        UserDefaults.standard.set([Double(offset.width), Double(offset.height)], forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
}
