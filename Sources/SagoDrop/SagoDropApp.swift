import AppKit
import Security
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
func smokeLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["SAGO_MEDIA_SMOKE_LOG"] == "1" else { return }
    FileHandle.standardError.write(Data("SMOKE \(message)\n".utf8))
}
#endif

@main
struct SagoDropApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: SagoDropAppDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class SagoDropAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = AppResources.appIcon
        MediaPreparation.cleanUpDiscordCache()
        let model = UploadModel()
        menuBarController = MenuBarController(model: model)
        model.resumePendingUploads()
#if DEBUG
        if let testFile = ProcessInfo.processInfo.environment["SAGO_MEDIA_SMOKE_FILE"] {
            model.onSmokeTestComplete = { succeeded in
                smokeLog("complete success=\(succeeded)")
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    NSApplication.shared.terminate(nil)
                }
            }
            Task { @MainActor in model.upload([URL(fileURLWithPath: testFile)]) }
        }
#endif
    }
}

struct UploadResult: Identifiable, Decodable {
    let id = UUID()
    let url: String
    let markdown: String
    let previewUrl: String?

    enum CodingKeys: String, CodingKey { case url, markdown, previewUrl }
}

struct StatusNotice: Equatable {
    let text: String
    let canBeSuppressed: Bool

    static func completion(_ text: String) -> Self {
        Self(text: text, canBeSuppressed: true)
    }

    static func attention(_ text: String) -> Self {
        Self(text: text, canBeSuppressed: false)
    }
}

enum PublicUploadDisclosure {
    private static let acceptedKey = "acceptedPublicUploadDisclosure"

    static func isAccepted(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: acceptedKey)
    }

    static func accept(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: acceptedKey)
    }
}

enum UploadProgressUpdate {
    case transferring(Double)
    case processing
}

@MainActor
final class UploadModel {
    private static let discordUploadLimitKey = "discordUploadLimit"

    var isUploading = false
    var message = ""
    var recent: [UploadResult] = []
    var onMenuBarStateChange: ((MenuBarState) -> Void)?
    var onStatus: ((StatusNotice) -> Void)?
    var onPublicUploadDisclosure: ((Int) -> Bool)?
    var isSignedIn: Bool { (try? Keychain.load()) != nil }
    var discordUploadLimit: DiscordUploadLimit {
        get {
            let stored = UserDefaults.standard.object(forKey: Self.discordUploadLimitKey) as? NSNumber
            return stored.flatMap { DiscordUploadLimit(rawValue: $0.int64Value) } ?? .free
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.discordUploadLimitKey) }
    }
    var onUploadProgressChange: ((UploadProgressUpdate?) -> Void)?
#if DEBUG
    var onSmokeTestComplete: ((Bool) -> Void)?
#endif
    private let api = MediaAPI()
    private let pendingUploads = PendingUploadStore()
    var hasPendingUploads: Bool { ((try? pendingUploads.all()) ?? []).isEmpty == false }
    var onUpdateRequired: (() -> Void)?
    private let supportedExtensions = Set(["gif", "jpeg", "jpg", "mov", "mp4", "png", "webp"])
    private var processingStartedAt: Date?

    func accepts(_ urls: [URL]) -> Bool {
        !isUploading && !urls.isEmpty && urls.allSatisfy {
            $0.isFileURL && supportedExtensions.contains($0.pathExtension.lowercased())
        }
    }

    func chooseFiles() {
        guard !isUploading else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose images or videos to share"
        panel.prompt = "Share"
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    func uploadCopiedFiles() {
        guard !isUploading else { return }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL])?
            .map { $0 as URL } ?? []
        guard !urls.isEmpty else {
            reportAttention("Copy a supported file first")
            NSSound.beep()
            return
        }
        upload(urls)
    }

    func downloadClipboard() {
        guard !isUploading else { return }
        do {
            guard let url = try ClipboardFile.create() else {
                reportAttention("Clipboard is empty or unsupported")
                NSSound.beep()
                return
            }
            report("Saved \(url.lastPathComponent) to Downloads")
        } catch {
            reportAttention("Couldn’t save to Downloads")
            NSSound.beep()
        }
    }

    func upload(_ urls: [URL]) {
        let urls = urls.filter { $0.isFileURL && supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !isUploading else { return }
        guard !urls.isEmpty else {
            reportAttention("Choose PNG, JPEG, GIF, WebP, MOV, or MP4 files")
            NSSound.beep()
            return
        }
        isUploading = true
        var bypassDiscordRouting = false
#if DEBUG
        bypassDiscordRouting = ProcessInfo.processInfo.environment["SAGO_MEDIA_SMOKE_FILE"] != nil
#endif
        message = bypassDiscordRouting || urls.count > 1
            ? (urls.count == 1 ? "Uploading \(urls[0].lastPathComponent)…" : "Uploading \(urls.count) files…")
            : "Checking \(urls[0].lastPathComponent)…"
        Task {
            if !bypassDiscordRouting, urls.count > 1,
               !confirmPublicUpload(fileCount: urls.count) {
                cancelUpload()
                return
            }
            if !bypassDiscordRouting, urls.count == 1 {
                let sourceURL = urls[0]
                MediaPreparation.cleanUpDiscordCache()
                if MediaPreparation.isVideo(sourceURL) {
                    message = "Preparing \(sourceURL.lastPathComponent) for Discord…"
                    onMenuBarStateChange?(.converting)
                }
                if let prepared = try? await MediaPreparation.prepareForDiscord(
                    sourceURL,
                    maximumBytes: discordUploadLimit.rawValue
                ) {
                    do {
                        try copyFile(prepared.url)
                        isUploading = false
                        let status = prepared.wasCompressed
                            ? "Compressed and copied \(sourceURL.lastPathComponent) for Discord"
                            : "Copied \(sourceURL.lastPathComponent) for Discord"
                        report(status)
                        onMenuBarStateChange?(.success)
#if DEBUG
                        onSmokeTestComplete?(true)
#endif
                        return
                    } catch {
                        isUploading = false
                        reportAttention(error.localizedDescription)
                        onMenuBarStateChange?(.failure)
                        NSSound.beep()
#if DEBUG
                        onSmokeTestComplete?(false)
#endif
                        return
                    }
                }
                guard confirmPublicUpload(fileCount: 1) else {
                    cancelUpload()
                    return
                }
                message = "Uploading \(sourceURL.lastPathComponent) as a link…"
            }

            var failed = false
            var needsUpdate = false
            var completionStatus = message
            var failureStatus: String?
            for url in urls {
                do {
                    let isVideo = MediaPreparation.isVideo(url)
                    message = isVideo ? "Preparing \(url.lastPathComponent)…" : "Uploading \(url.lastPathComponent)…"
                    onMenuBarStateChange?(isVideo ? .converting : .uploading)
                    let prepared = try await MediaPreparation.prepare(url)
                    defer { prepared.cleanUp() }
                    if prepared.isTemporary { message = "Uploading converted MP4…" }
                    onMenuBarStateChange?(.uploading)
                    processingStartedAt = nil
                    onUploadProgressChange?(.transferring(0))
                    let pending = try pendingUploads.stage(prepared.url, filename: url.lastPathComponent, baseURL: api.baseURL)
                    let result = try await finishPending(pending) { [weak self] progress in
                        guard let self else { return }
                        let percentage = Int((progress * 100).rounded())
                        message = progress < 1
                            ? "Uploading \(url.lastPathComponent)… \(percentage)%"
                            : "Finishing \(url.lastPathComponent)…"
                        if progress < 1 {
                            onUploadProgressChange?(.transferring(progress))
                        } else {
                            processingStartedAt = processingStartedAt ?? Date()
                            onUploadProgressChange?(.processing)
                        }
                    }
                    let processingStart = processingStartedAt ?? Date()
                    processingStartedAt = processingStart
                    onUploadProgressChange?(.processing)
                    let remainingFeedback = 0.45 - Date().timeIntervalSince(processingStart)
                    if remainingFeedback > 0 {
                        try? await Task.sleep(for: .seconds(remainingFeedback))
                    }
                    onUploadProgressChange?(.transferring(1))
                    try? await Task.sleep(for: .milliseconds(150))
                    onUploadProgressChange?(nil)
                    processingStartedAt = nil
                    guard copy(result.url) else { throw MediaError.message("Couldn’t copy the link. Choose Retry Pending Uploads.") }
                    try pendingUploads.remove(pending)
                    recent.insert(result, at: 0)
#if DEBUG
                    smokeLog("clipboard=\(NSPasteboard.general.string(forType: .string) ?? "")")
#endif
                    completionStatus = "Copied \(url.lastPathComponent)"
                    message = completionStatus
                } catch {
                    failed = true
                    processingStartedAt = nil
                    onUploadProgressChange?(nil)
                    failureStatus = error.localizedDescription
                    message = error.localizedDescription
                    if case MediaError.updateRequired = error { needsUpdate = true }
                    NSSound.beep()
                }
            }
            isUploading = false
            if needsUpdate { onUpdateRequired?() }
            else if let failureStatus {
                reportAttention(failureStatus)
            } else {
                report(completionStatus)
            }
            onMenuBarStateChange?(failed ? .failure : .success)
#if DEBUG
            onSmokeTestComplete?(!failed)
#endif
        }
    }

    func login() {
        guard !isUploading else { return }
        isUploading = true
        message = "Starting secure login…"
        Task {
            do {
                let device = try await api.startLogin()
                message = "Approve code \(device.userCode) in your browser"
                NSWorkspace.shared.open(device.verificationUri)
                reportAttention(message)
                _ = try await api.waitForApproval(device)
                report("Signed in")
            } catch {
                reportAttention(error.localizedDescription)
                NSSound.beep()
            }
            isUploading = false
        }
    }

    func logout() {
        guard !isUploading else { return }
        do {
            try Keychain.delete()
            report("Signed out")
        } catch {
            reportAttention(error.localizedDescription)
            NSSound.beep()
        }
    }

    func report(_ status: String) {
        message = status
        onStatus?(.completion(status))
    }

    func reportAttention(_ status: String) {
        message = status
        onStatus?(.attention(status))
    }

    @discardableResult
    func copy(_ value: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
    }

    private func finishPending(_ pending: PendingUpload, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> UploadResult {
        do { return try await api.finish(pending, onProgress: onProgress) }
        catch let error as MediaError {
            if case .jobFailed = error { try pendingUploads.remove(pending) }
            throw error
        }
    }

    func resumePendingUploads() {
        guard !isUploading else { return }
        let pending: [PendingUpload]
        do { pending = try pendingUploads.all() }
        catch { reportAttention("Couldn’t restore pending uploads"); return }
        guard !pending.isEmpty else { return }
        isUploading = true
        onMenuBarStateChange?(.uploading)
        Task {
            var failed = false
            for upload in pending {
                do {
                    message = "Finishing \(upload.filename)…"
                    onUploadProgressChange?(.processing)
                    let result = try await finishPending(upload) { [weak self] _ in self?.onUploadProgressChange?(.processing) }
                    guard copy(result.url) else { throw MediaError.message("Couldn’t copy the link. Choose Retry Pending Uploads.") }
                    try pendingUploads.remove(upload)
                    recent.insert(result, at: 0)
                    report("Copied \(upload.filename)")
                } catch {
                    failed = true
                    if case MediaError.updateRequired = error { onUpdateRequired?() }
                    else { reportAttention(error.localizedDescription) }
                }
            }
            isUploading = false
            onUploadProgressChange?(nil)
#if DEBUG
            smokeLog("clipboard=\(NSPasteboard.general.string(forType: .string) ?? "")")
#endif
            onMenuBarStateChange?(failed ? .failure : .success)
#if DEBUG
            onSmokeTestComplete?(!failed)
#endif
        }
    }

    private func copyFile(_ url: URL) throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([url as NSURL]) else {
            throw MediaError.message("Couldn’t copy the prepared file")
        }
    }

    private func confirmPublicUpload(fileCount: Int) -> Bool {
        guard isSignedIn, !PublicUploadDisclosure.isAccepted() else { return true }
        guard onPublicUploadDisclosure?(fileCount) == true else { return false }
        PublicUploadDisclosure.accept()
        return true
    }

    private func cancelUpload() {
        isUploading = false
        message = "Sharing cancelled"
        onMenuBarStateChange?(.idle)
    }
}

enum Keychain {
    private static let service = "dev.hsichen.SagoDrop"
    private static let account = "upload-token"

    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var value = query
        value[kSecValueData as String] = Data(token.utf8)
        guard SecItemAdd(value as CFDictionary, nil) == errSecSuccess else { throw MediaError.message("Could not save credentials in Keychain") }
    }

    static func load() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw MediaError.message("Could not read credentials from Keychain") }
        return token
    }

    static func delete() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MediaError.message("Could not remove credentials from Keychain") }
    }
}
