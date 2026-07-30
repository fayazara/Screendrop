//
//  CloudUploadOptions.swift
//  Screendrop
//
//  The title + "allow comments & likes" choice offered right before a
//  manual cloud upload. Auto-upload (after-capture, no user interaction)
//  skips this entirely and just uses the remembered default toggle.
//

import SwiftUI

struct CloudUploadOptions: Sendable {
    var title: String
    var socialEnabled: Bool

    /// `nil` title means "let the worker fall back to the filename (or,
    /// for recordings, the auto-generated 'Screen Recording — …' title)".
    var trimmedTitleOrNil: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Remembers the last-chosen "allow comments & likes" toggle across
/// uploads (including background auto-uploads, which never show the
/// popover) so the common case doesn't require re-deciding every time.
enum CloudUploadPreferences {
    private static let socialEnabledKey = "cloudUploadDefaultSocialEnabled"

    static var lastSocialEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: socialEnabledKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: socialEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: socialEnabledKey) }
    }
}

/// Small popover form shown from an upload/share button: a title field
/// (prefilled with a suggested default, editable) and a single toggle
/// that turns comments + likes on or off for this upload. Confirming
/// remembers the toggle choice as the default for next time.
struct CloudUploadOptionsPopover: View {
    let suggestedTitle: String
    let onConfirm: (CloudUploadOptions) -> Void

    @State private var title: String
    @State private var socialEnabled = CloudUploadPreferences.lastSocialEnabled
    @Environment(\.dismiss) private var dismiss

    init(suggestedTitle: String = "", onConfirm: @escaping (CloudUploadOptions) -> Void) {
        self.suggestedTitle = suggestedTitle
        self.onConfirm = onConfirm
        _title = State(initialValue: suggestedTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share Options")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Title", text: $title, prompt: Text("Untitled"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
            }

            HStack {
                Text("Allow comments & likes")
                Spacer()
                Toggle("Allow comments & likes", isOn: $socialEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Upload") {
                    CloudUploadPreferences.lastSocialEnabled = socialEnabled
                    let options = CloudUploadOptions(title: title, socialEnabled: socialEnabled)
                    dismiss()
                    onConfirm(options)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// Wraps any trigger content in a button that opens `CloudUploadOptionsPopover`
/// before firing `onUpload`. Drop-in replacement for a plain
/// `Button(action: onUpload) { ... }` at a manual upload/share call site.
struct CloudUploadButton<Label: View>: View {
    let suggestedTitle: String
    let onUpload: (CloudUploadOptions) -> Void
    @ViewBuilder let label: () -> Label

    @State private var showingOptions = false

    var body: some View {
        Button {
            showingOptions = true
        } label: {
            label()
        }
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            CloudUploadOptionsPopover(suggestedTitle: suggestedTitle, onConfirm: onUpload)
        }
    }
}
