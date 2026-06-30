//
//  ScreendropApplicationPaths.swift
//  Screendrop
//

import Foundation

nonisolated enum ScreendropApplicationPaths {
    static var applicationSupportDirectory: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL.appendingPathComponent("Screendrop", isDirectory: true)
    }

    static var historyDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("History", isDirectory: true)
    }

    static var historyThumbnailsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
    }
}
