import Foundation
import Testing
@testable import SagoDrop

@Test func comparesReleaseVersions() {
    #expect(AutoUpdateVersion("0.8.0") < AutoUpdateVersion("0.9.0"))
    #expect(AutoUpdateVersion("v1.9.0") < AutoUpdateVersion("1.10.0"))
    #expect(AutoUpdateVersion("1.0.0-beta.2") < AutoUpdateVersion("1.0.0-beta.11"))
    #expect(AutoUpdateVersion("1.0.0-beta.11") < AutoUpdateVersion("1.0.0"))
    #expect(AutoUpdateVersion("v1.2.0") == AutoUpdateVersion("1.2.0"))
}

@Test func extractsUpdateChecksumFromCask() {
    let cask = """
    cask "sago-drop" do
      version "0.9.0"
      sha256 "ABCDEF1234"
    end
    """

    #expect(AutoUpdateCaskParser.extractSHA256(from: cask) == "abcdef1234")
}

@Test func describesAutoUpdateMenuStates() {
    let candidate = AutoUpdateCandidate(
        version: "0.9.0",
        archiveURL: URL(string: "https://example.com/Sago-Drop-0.9.0.zip")!,
        expectedSHA256: "abc123"
    )

    #expect(AutoUpdateStatus.idle.menuTitle == "Check for Updates…")
    #expect(AutoUpdateStatus.updateAvailable(candidate).menuTitle == "Update Available")
    #expect(!AutoUpdateStatus.downloading(candidate).canActivate)
}

@Test func pinsAutoUpdatesToSagoDropSigningIdentity() {
    #expect(GitHubReleaseUpdateClient.codeSigningRequirement.contains("dev.hsichen.SagoDrop"))
    #expect(GitHubReleaseUpdateClient.codeSigningRequirement.contains("D925G8G7CS"))
}
