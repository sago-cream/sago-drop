import Foundation
import Testing
@testable import SagoDrop

@Test func showsSettingsOnlyUntilFirstRunHasBeenSeen() throws {
    let suiteName = "SagoDropTests-Settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(SettingsPresentation.shouldShow(in: defaults))
    SettingsPresentation.markShown(in: defaults)
    #expect(!SettingsPresentation.shouldShow(in: defaults))
}
