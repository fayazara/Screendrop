//
//  UpdaterManager.swift
//  Screendrop
//

import AppKit
import Combine
import Foundation
import Sparkle

/// Manages Sparkle auto-update lifecycle.
///
/// Sparkle's `SPUStandardUpdaterController` must be created early, before
/// `applicationDidFinishLaunching` returns, so the automatic update check
/// schedule starts correctly.
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    private let controller: SPUStandardUpdaterController
    private let availability = UpdateAvailabilityDelegate()
    private var lastInformationCheck: Date?

    @Published var canCheckForUpdates = false
    /// The version of a newer release that hasn't been downloaded yet. The
    /// Library shows a download button while this is set.
    @Published private(set) var availableUpdateVersion: String?

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    private override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: availability,
            userDriverDelegate: nil
        )
        super.init()
        availability.onChange = { [weak self] version in self?.availableUpdateVersion = version }

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func start() {
        #if DEBUG
        return
        #else
        controller.startUpdater()
        checkForUpdateInformation()
        #endif
    }

    /// Looks for a newer release without showing any Sparkle UI, so the
    /// Library can offer it. At most once an hour.
    func checkForUpdateInformation() {
        #if DEBUG
        return
        #else
        if let lastInformationCheck, Date().timeIntervalSince(lastInformationCheck) < 3600 { return }
        guard !controller.updater.sessionInProgress else { return }
        lastInformationCheck = Date()
        controller.updater.checkForUpdateInformation()
        #endif
    }

    func checkForUpdates() {
        #if DEBUG
        return
        #else
        NSApp.setActivationPolicy(AppActivationPolicy.windowPolicy)
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
        #endif
    }
}

/// Tracks whether a newer release is waiting: set when Sparkle finds one,
/// cleared when none is found or once it has been downloaded.
private final class UpdateAvailabilityDelegate: NSObject, SPUUpdaterDelegate {
    @MainActor var onChange: ((String?) -> Void)?

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { onChange?(version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { onChange?(nil) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { onChange?(nil) }
    }
}
