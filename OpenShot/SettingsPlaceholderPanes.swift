//
//  SettingsPlaceholderPanes.swift
//  OpenShot
//

import SwiftUI

struct VideoSettingsPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text("Video Recording")
                .font(.title3.weight(.medium))

            Text("Video recording settings will appear here.\nConfigure frame rate, resolution, and output format.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OverlaySettingsPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text("Overlay")
                .font(.title3.weight(.medium))

            Text("Configure the preview card that appears\nafter taking a screenshot.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
