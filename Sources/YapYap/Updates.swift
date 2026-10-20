import Foundation
import Sparkle

/// Automatic updates with Sparkle, from the feed in Info.plist (`SUFeedURL`: yapyap.cc/appcast.xml).
/// Every update must be signed with the key whose public half is `SUPublicEDKey`; Sparkle refuses
/// anything else. Builds without a key (tests, the command line) never start the updater.
final class Updates {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?

    /// Whether this build can update itself; the menu items are hidden otherwise.
    var isAvailable: Bool { Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil }

    /// Called at launch. Sparkle then checks in the background once a day (after asking the user
    /// on the second launch, as it does for every app).
    func start() {
        guard isAvailable, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkNow() {
        controller?.checkForUpdates(nil)
    }
}
