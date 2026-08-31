import AppKit
import CryptoKit
import Foundation

struct AutoUpdateVersion: Comparable, Equatable, Sendable {
    let normalized: String
    private let core: [Int]
    private let prerelease: [String]

    init(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let unprefixed = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let version = String(unprefixed.split(separator: "+", maxSplits: 1).first ?? "")
        let parts = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        normalized = version
        core = (parts.first ?? "").split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.core.count, rhs.core.count) {
            let left = index < lhs.core.count ? lhs.core[index] : 0
            let right = index < rhs.core.count ? rhs.core[index] : 0
            if left != right { return left < right }
        }

        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }

        for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
            guard index < lhs.prerelease.count else { return true }
            guard index < rhs.prerelease.count else { return false }
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            switch (Int(left), Int(right)) {
            case let (.some(leftNumber), .some(rightNumber)) where leftNumber != rightNumber:
                return leftNumber < rightNumber
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none) where left != right:
                return left < right
            default:
                continue
            }
        }
        return false
    }
}

struct AutoUpdateCandidate: Equatable, Sendable {
    let version: String
    let archiveURL: URL
    let expectedSHA256: String
}

struct StagedAutoUpdate: Sendable {
    let appURL: URL
    let stagingDirectory: URL
}

enum AutoUpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case updateAvailable(AutoUpdateCandidate)
    case downloading(AutoUpdateCandidate)
    case installing(AutoUpdateCandidate)

    var menuTitle: String {
        switch self {
        case .idle: "Check for Updates…"
        case .checking: "Checking for Updates…"
        case .upToDate: "Sago Drop Is Up to Date"
        case .updateAvailable: "Update Available"
        case .downloading: "Downloading Update…"
        case .installing: "Installing Update…"
        }
    }

    var canActivate: Bool {
        switch self {
        case .checking, .downloading, .installing: false
        case .idle, .upToDate, .updateAvailable: true
        }
    }

    var shouldShowInMenu: Bool {
        switch self {
        case .updateAvailable, .downloading, .installing: true
        case .idle, .checking, .upToDate: false
        }
    }
}

enum AutoUpdateCaskParser {
    static func extractSHA256(from cask: String) -> String? {
        for line in cask.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("sha256 ") else { continue }
            let value = trimmed.dropFirst("sha256 ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
        }
        return nil
    }
}

enum AutoUpdateError: LocalizedError, Sendable {
    case requestFailed(Int)
    case archiveMissing(String)
    case checksumMissing
    case checksumMismatch
    case appMissing
    case invalidBundleIdentifier(String?)
    case invalidVersion(expected: String, actual: String?)
    case signatureInvalid
    case commandFailed(String)
    case appBundleUnavailable
    case installLocationNotWritable(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let status):
            "GitHub rejected the update request with HTTP \(status)."
        case .archiveMissing(let version):
            "Release \(version) does not include Sago-Drop-\(version).zip."
        case .checksumMissing:
            "The release does not include a checksum for its app archive."
        case .checksumMismatch:
            "The downloaded update did not match its published checksum."
        case .appMissing:
            "The downloaded archive did not contain Sago Drop.app."
        case .invalidBundleIdentifier:
            "The downloaded update is not a Sago Drop app bundle."
        case .invalidVersion(let expected, let actual):
            "The downloaded app is version \(actual ?? "unknown"), not \(expected)."
        case .signatureInvalid:
            "The downloaded update was not signed by Sago Drop."
        case .commandFailed(let message):
            message
        case .appBundleUnavailable:
            "Install Sago Drop in Applications before using automatic updates."
        case .installLocationNotWritable(let path):
            "Sago Drop cannot replace the app at \(path). Check its permissions or install the update manually."
        }
    }
}

actor GitHubReleaseUpdateClient {
    private static let appName = "Sago Drop.app"
    private static let bundleIdentifier = "dev.hsichen.SagoDrop"
    private static let teamIdentifier = "D925G8G7CS"
    static let codeSigningRequirement = "=anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/sago-cream/sago-drop/releases/latest"
    )!

    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func fetchAvailableUpdate(currentVersion: String) async throws -> AutoUpdateCandidate? {
        let (data, response) = try await session.data(for: request(for: Self.latestReleaseURL))
        try Self.validate(response)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)
        let latest = AutoUpdateVersion(release.tagName)
        guard latest > AutoUpdateVersion(currentVersion) else { return nil }

        let archiveName = "Sago-Drop-\(latest.normalized).zip"
        guard let archive = release.assets.first(where: { $0.name == archiveName }) else {
            throw AutoUpdateError.archiveMissing(latest.normalized)
        }
        guard let cask = release.assets.first(where: { $0.name == "sago-drop.rb" }) else {
            throw AutoUpdateError.checksumMissing
        }
        let (caskData, caskResponse) = try await session.data(for: request(for: cask.browserDownloadUrl))
        try Self.validate(caskResponse)
        guard let caskText = String(data: caskData, encoding: .utf8),
              let checksum = AutoUpdateCaskParser.extractSHA256(from: caskText) else {
            throw AutoUpdateError.checksumMissing
        }

        return AutoUpdateCandidate(
            version: latest.normalized,
            archiveURL: archive.browserDownloadUrl,
            expectedSHA256: checksum
        )
    }

    func downloadAndStage(_ candidate: AutoUpdateCandidate) async throws -> StagedAutoUpdate {
        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("sago-drop-update-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = stagingDirectory.appendingPathComponent("Sago-Drop-\(candidate.version).zip")
        let extractionDirectory = stagingDirectory.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        do {
            let (downloadURL, response) = try await session.download(for: request(for: candidate.archiveURL))
            try Self.validate(response)
            try fileManager.moveItem(at: downloadURL, to: archiveURL)

            guard try Self.sha256(for: archiveURL) == candidate.expectedSHA256.lowercased() else {
                throw AutoUpdateError.checksumMismatch
            }
            try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", archiveURL.path, extractionDirectory.path])

            let appURL = extractionDirectory.appendingPathComponent(Self.appName, isDirectory: true)
            try Self.validateApp(at: appURL, expectedVersion: candidate.version)
            return StagedAutoUpdate(appURL: appURL, stagingDirectory: stagingDirectory)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    func scheduleReplacement(with update: StagedAutoUpdate) throws {
        let currentAppURL = Bundle.main.bundleURL
        guard currentAppURL.pathExtension == "app" else {
            throw AutoUpdateError.appBundleUnavailable
        }
        try verifyInstallLocation(currentAppURL)

        let scriptURL = update.stagingDirectory.appendingPathComponent("install-sago-drop-update.sh")
        let script = Self.replacementScript(
            currentAppURL: currentAppURL,
            newAppURL: update.appURL,
            stagingDirectory: update.stagingDirectory,
            processID: ProcessInfo.processInfo.processIdentifier
        )
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        try process.run()
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SagoDrop/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func verifyInstallLocation(_ appURL: URL) throws {
        let parent = appURL.deletingLastPathComponent()
        let probe = parent.appendingPathComponent(".sago-drop-update-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .withoutOverwriting)
            try fileManager.removeItem(at: probe)
        } catch {
            throw AutoUpdateError.installLocationNotWritable(appURL.path)
        }
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw AutoUpdateError.requestFailed(http.statusCode)
        }
    }

    private static func sha256(for url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func validateApp(at appURL: URL, expectedVersion: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let bundle = Bundle(url: appURL) else {
            throw AutoUpdateError.appMissing
        }
        guard bundle.bundleIdentifier == bundleIdentifier else {
            throw AutoUpdateError.invalidBundleIdentifier(bundle.bundleIdentifier)
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version == expectedVersion else {
            throw AutoUpdateError.invalidVersion(expected: expectedVersion, actual: version)
        }

        do {
            try run(
                "/usr/bin/codesign",
                ["--verify", "--deep", "--strict", "--requirements", codeSigningRequirement, appURL.path]
            )
            try run("/usr/sbin/spctl", ["--assess", "--type", "execute", appURL.path])
        } catch {
            throw AutoUpdateError.signatureInvalid
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AutoUpdateError.commandFailed(output?.isEmpty == false ? output! : "Update verification failed.")
        }
    }

    private static func replacementScript(
        currentAppURL: URL,
        newAppURL: URL,
        stagingDirectory: URL,
        processID: Int32
    ) -> String {
        let app = shellQuoted(currentAppURL.path)
        let newApp = shellQuoted(newAppURL.path)
        let staging = shellQuoted(stagingDirectory.path)
        return """
        #!/bin/zsh
        set -euo pipefail

        app_path=\(app)
        new_app_path=\(newApp)
        staging_dir=\(staging)
        old_pid=\(processID)
        backup_path="${app_path}.previous-sago-drop-update"

        for _ in {1..120}; do
            if ! /bin/kill -0 "$old_pid" >/dev/null 2>&1; then
                break
            fi
            /bin/sleep 0.25
        done

        if /bin/kill -0 "$old_pid" >/dev/null 2>&1; then
            exit 1
        fi

        /bin/rm -rf "$backup_path"
        if [[ -d "$app_path" ]]; then
            /bin/mv "$app_path" "$backup_path"
        fi

        if /usr/bin/ditto "$new_app_path" "$app_path" && /usr/bin/open "$app_path"; then
            /bin/rm -rf "$backup_path"
            /bin/rm -rf "$staging_dir"
            exit 0
        fi

        /bin/rm -rf "$app_path"
        if [[ -d "$backup_path" ]]; then
            /bin/mv "$backup_path" "$app_path"
            /usr/bin/open "$app_path" >/dev/null 2>&1 || true
        fi
        exit 1
        """
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }
    }
}

@MainActor
final class AutoUpdateStore {
    private static let lastCheckKey = "lastAutoUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private(set) var status = AutoUpdateStatus.idle
    var onError: ((String) -> Void)?

    private let client: GitHubReleaseUpdateClient
    private let defaults: UserDefaults
    private var automaticCheckTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?

    init(client: GitHubReleaseUpdateClient = GitHubReleaseUpdateClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
    }

    deinit {
        automaticCheckTask?.cancel()
        resetTask?.cancel()
    }

    func startAutomaticChecks() {
        guard automaticCheckTask == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        automaticCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if shouldCheckAutomatically {
                    await checkForUpdates(isUserInitiated: false)
                }
                do {
                    try await Task.sleep(for: .seconds(60 * 60))
                } catch {
                    return
                }
            }
        }
    }

    func activatePrimaryAction() async {
        switch status {
        case .updateAvailable:
            await installAvailableUpdate()
        case .idle, .upToDate:
            await checkForUpdates(isUserInitiated: true)
        case .checking, .downloading, .installing:
            break
        }
    }

    private func checkForUpdates(isUserInitiated: Bool) async {
        guard status.canActivate else { return }
        resetTask?.cancel()
        status = .checking
        do {
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            let candidate = try await client.fetchAvailableUpdate(currentVersion: current)
            defaults.set(Date(), forKey: Self.lastCheckKey)
            if let candidate {
                status = .updateAvailable(candidate)
            } else if isUserInitiated {
                status = .upToDate
                resetTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, self?.status == .upToDate else { return }
                    self?.status = .idle
                }
            } else {
                status = .idle
            }
        } catch {
            status = .idle
            if isUserInitiated { onError?(Self.message(for: error)) }
        }
    }

    private func installAvailableUpdate() async {
        guard case .updateAvailable(let candidate) = status else { return }
        var staged: StagedAutoUpdate?
        status = .downloading(candidate)
        do {
            let update = try await client.downloadAndStage(candidate)
            staged = update
            status = .installing(candidate)
            try await client.scheduleReplacement(with: update)
            NSApp.terminate(nil)
        } catch {
            if let staged { try? FileManager.default.removeItem(at: staged.stagingDirectory) }
            status = .updateAvailable(candidate)
            onError?(Self.message(for: error))
        }
    }

    private var shouldCheckAutomatically: Bool {
        guard let date = defaults.object(forKey: Self.lastCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(date) >= Self.checkInterval
    }

    private static func message(for error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription.isEmpty ? "Sago Drop could not complete the update." : error.localizedDescription
    }
}
