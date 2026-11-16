import CryptoKit
import Foundation

struct PendingUpload: Codable, Sendable {
    let id: String
    let fileURL: URL
    let filename: String
    let sha256: String
    let baseURL: URL
    let createdAt: Date
}

struct PendingUploadStore: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
#if DEBUG
        if let path = ProcessInfo.processInfo.environment["SAGO_MEDIA_SMOKE_PENDING"] {
            self.directory = URL(fileURLWithPath: path)
            return
        }
#endif
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Sago Drop/Pending Uploads", directoryHint: .isDirectory)
    }

    func stage(_ source: URL, filename: String, baseURL: URL) throws -> PendingUpload {
        let id = UUID().uuidString.lowercased()
        let folder = directory.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let fileURL = folder.appending(path: source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
            let pending = PendingUpload(id: id, fileURL: fileURL, filename: filename,
                sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), baseURL: baseURL, createdAt: Date())
            try JSONEncoder().encode(pending).write(to: folder.appending(path: "job.json"), options: .atomic)
            return pending
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func all() throws -> [PendingUpload] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { folder in
                let manifest = folder.appending(path: "job.json")
                guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
                return try JSONDecoder().decode(PendingUpload.self, from: Data(contentsOf: manifest))
            }.sorted { $0.createdAt < $1.createdAt }
    }

    func remove(_ upload: PendingUpload) throws {
        try FileManager.default.removeItem(at: directory.appending(path: upload.id))
    }
}

struct UploadJob: Decodable {
    let id: String
    let status: String
    let result: UploadResult?
    let error: String?
}
