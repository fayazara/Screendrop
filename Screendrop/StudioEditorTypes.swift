//
//  StudioEditorTypes.swift
//  Screendrop
//
//  Small values the Studio editor keeps beside its clips.
//

import Foundation

/// A flag dropped on the timeline with M. It sits on the source clock, so
/// it stays with its footage through cuts, and drops out of sight while
/// that footage is cut away.
nonisolated struct RecordingMarker: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var sourceTime: TimeInterval
    var note: String?
}

/// A word shown over the picture for a moment. Each one is new, so the
/// same word twice in a row still shows again.
struct StudioNotice: Identifiable, Equatable {
    let id = UUID()
    let text: String
}
