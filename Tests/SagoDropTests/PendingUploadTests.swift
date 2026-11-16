import CryptoKit
import Foundation
import Testing
@testable import SagoDrop

@Test func preservesPreparedBytesAndUploadIdentityAcrossRestarts() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appending(path: "recording.mp4")
    let data = Data("prepared video".utf8)
    try data.write(to: source)
    let directory = folder.appending(path: "pending")
    let store = PendingUploadStore(directory: directory)
    let pending = try store.stage(source, filename: "Original.mov", baseURL: URL(string: "https://media.example.test")!)
    try FileManager.default.removeItem(at: source)

    let restored = try #require(PendingUploadStore(directory: directory).all().first)
    #expect(restored.id == pending.id)
    #expect(restored.filename == "Original.mov")
    #expect(try Data(contentsOf: restored.fileURL) == data)
    #expect(restored.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    try store.remove(restored)
    #expect(try store.all().isEmpty)
}

@Test func failedStagingDoesNotLeaveAPendingJob() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PendingUploadStore(directory: directory)
    #expect(throws: (any Error).self) {
        try store.stage(directory.appending(path: "missing.png"), filename: "missing.png", baseURL: URL(string: "https://media.example.test")!)
    }
    #expect(try store.all().isEmpty)
}
