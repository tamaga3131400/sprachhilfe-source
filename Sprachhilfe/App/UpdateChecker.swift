@preconcurrency import Sparkle

@MainActor
struct UpdateChecker {
    let canCheckForUpdates: () -> Bool
    let checkForUpdates: () -> Void

    static func sparkle(_ updater: SPUUpdater) -> UpdateChecker {
        return UpdateChecker(
            canCheckForUpdates: { updater.canCheckForUpdates },
            checkForUpdates: { updater.checkForUpdates() }
        )
    }

    static var shared: UpdateChecker?
}
