import Foundation
import Testing
@testable import SagoDrop

@Test func showsOnboardingOnlyUntilFirstRunHasBeenSeen() throws {
    let suiteName = "SagoDropTests-Onboarding-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(OnboardingPresentation.shouldShow(in: defaults))
    OnboardingPresentation.markShown(in: defaults)
    #expect(!OnboardingPresentation.shouldShow(in: defaults))
}
