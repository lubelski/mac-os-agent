import Foundation
import MacOSAgentCore
import Sparkle

/// Keeps the app up to date with Sparkle.
///
/// Only a release build updates itself. `scripts/release.sh` writes the feed address and the
/// public signing key into Info.plist. A build without them, such as one from
/// `scripts/bundle.sh` alone, has no updater, so a development copy is never replaced.
@MainActor
final class AppUpdater {
    /// Whether this build can update itself.
    let isAvailable: Bool

    /// The title of every Check for Updates item: the menu bar menu's, the panel menu's, and
    /// the button in Settings, General.
    static let checkTitle = "Check for Updates…"

    private let controller: SPUStandardUpdaterController?
    private let delegate: Delegate

    /// `info` is the bundle's Info.plist. `activity` says what the app is doing, to decide
    /// whether it may quit and relaunch now.
    init(
        info: [String: Any]? = Bundle.main.infoDictionary,
        activity: @escaping @MainActor () -> AppUpdates.Activity
    ) {
        delegate = Delegate(activity: activity)
        guard AppUpdates.hasFeed(info) else {
            isAvailable = false
            controller = nil
            return
        }
        isAvailable = true
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil
        )
    }

    /// A build with no feed, for previews and tests.
    static func unavailable() -> AppUpdater {
        AppUpdater(info: nil, activity: { .init() })
    }

    /// False while a check is already running.
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// Whether Sparkle looks for, downloads, and installs updates without asking.
    var updatesAutomatically: Bool {
        get {
            guard let updater = controller?.updater else { return false }
            return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Checks now and shows Sparkle's own windows with the result.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Installs an update that was held back because the app could not relaunch then.
    /// Call this whenever a task ends or the incognito window changes.
    func installPendingUpdate() {
        delegate.installPendingUpdate()
    }

    private final class Delegate: NSObject, SPUUpdaterDelegate {
        private let activity: @MainActor () -> AppUpdates.Activity
        private var pendingInstall: (() -> Void)?
        /// Looks again now and then while an update waits, for changes that call nothing,
        /// such as the owner removing the last queued message.
        private var retry: Timer?

        init(activity: @escaping @MainActor () -> AppUpdates.Activity) {
            self.activity = activity
        }

        /// Sparkle normally installs a downloaded update when the app quits. A menu bar app
        /// stays open for weeks, so install and relaunch as soon as the update is ready. A
        /// relaunch would cut off a task, a go-ahead, the message queue, and the incognito
        /// conversation, which live only in memory, so while any of them is there the install
        /// waits until it is gone.
        func updater(
            _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
            immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
        ) -> Bool {
            // Sparkle calls its delegate on the main thread.
            MainActor.assumeIsolated {
                if AppUpdates.mayRelaunch(activity()) {
                    immediateInstallHandler()
                } else {
                    log.notice("An update is ready and waits: \(String(describing: AppUpdates.wait(for: self.activity())), privacy: .public)")
                    pendingInstall = immediateInstallHandler
                    scheduleRetry()
                }
            }
            return true
        }

        @MainActor
        func installPendingUpdate() {
            guard let install = pendingInstall, AppUpdates.mayRelaunch(activity()) else { return }
            pendingInstall = nil
            retry?.invalidate()
            retry = nil
            install()
        }

        @MainActor
        private func scheduleRetry() {
            guard retry == nil else { return }
            retry = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.installPendingUpdate() }
            }
        }
    }
}
