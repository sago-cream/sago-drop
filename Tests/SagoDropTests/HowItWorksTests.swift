import Foundation
import Testing
@testable import SagoDrop

@Test func showsHowItWorksOnlyUntilItHasBeenSeen() throws {
    let suiteName = "SagoDropTests-HowItWorks-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(HowItWorksPresentation.shouldShow(in: defaults))
    HowItWorksPresentation.markShown(in: defaults)
    #expect(!HowItWorksPresentation.shouldShow(in: defaults))
}
