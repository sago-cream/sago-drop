import Foundation

struct DeviceRequest: Decodable {
    let deviceCode: String
    let deviceSecret: String
    let userCode: String
    let verificationUri: URL
    let expiresIn: Int
    let interval: Int
}

private struct DeviceStatus: Decodable {
    let status: String
    let token: String?
    let scope: String?
}

enum MediaError: LocalizedError {
    case message(String)
    case jobFailed(String)
    case updateRequired(String)

    var errorDescription: String? {
        switch self { case .message(let message), .jobFailed(let message), .updateRequired(let message): message }
    }
}

struct MediaAPI {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: ProcessInfo.processInfo.environment["MEDIA_URL"] ?? "https://media.sagocream.com")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component), isDirectory: false)
        }
    }

    func startLogin() async throws -> DeviceRequest {
        var request = URLRequest(url: endpoint("v1/auth/device"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceName": Host.current().localizedName ?? "Mac"])
        return try await send(request, as: DeviceRequest.self)
    }

    func waitForApproval(_ device: DeviceRequest) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(device.interval))
            var request = URLRequest(url: endpoint("v1/auth/device/\(device.deviceCode)"))
            request.setValue("Device \(device.deviceSecret)", forHTTPHeaderField: "Authorization")
            let status = try await send(request, as: DeviceStatus.self, acceptedStatuses: 200...499)
            if status.status == "approved", let token = status.token {
                try Keychain.save(token)
                return status.scope ?? "upload"
            }
            if status.status == "denied" { throw MediaError.message("Access was denied") }
        }
        throw MediaError.message("The access request expired")
    }

    func finish(_ pending: PendingUpload, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> UploadResult {
        guard pending.baseURL == baseURL else { throw MediaError.message("This upload belongs to a different media server") }
        guard let token = try uploadToken() else { throw MediaError.message("Connect to GitHub to finish your upload") }
        let statusURL = endpoint("v1/upload-jobs/\(pending.id)")
        let deadline = Date().addingTimeInterval(20 * 60)
        var lastError: Error?
        var isFinishing = false
        var transientFailures = 0
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                var statusRequest = URLRequest(url: statusURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                statusRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await session.data(for: statusRequest)
                var job: UploadJob
                if (response as? HTTPURLResponse)?.statusCode == 404 {
                    var request = URLRequest(url: endpoint("v1/upload-jobs"), timeoutInterval: 60)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    request.setValue(pending.fileURL.lastPathComponent, forHTTPHeaderField: "X-Media-Filename")
                    request.setValue(pending.sha256, forHTTPHeaderField: "X-Media-SHA256")
                    request.setValue(pending.id, forHTTPHeaderField: "Idempotency-Key")
                    let delegate = UploadProgressDelegate(onProgress: onProgress)
                    let (body, result) = try await session.upload(for: request, fromFile: pending.fileURL, delegate: delegate)
                    job = try decode(body, response: result, as: UploadJob.self)
                } else {
                    job = try decode(data, response: response, as: UploadJob.self)
                }
                guard job.id == pending.id else { throw MediaError.message("The upload response did not match this file") }
                if !isFinishing { await onProgress(1); isFinishing = true }
                switch job.status {
                case "ready":
                    guard let result = job.result, let url = URL(string: result.url),
                          ["http", "https"].contains(url.scheme ?? "") else {
                        throw MediaError.message("Sago Media returned an invalid link")
                    }
                    var check = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                    check.httpMethod = "HEAD"
                    let (_, response) = try await session.data(for: check)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        throw URLError(.resourceUnavailable)
                    }
                    return result
                case "failed": throw MediaError.jobFailed(job.error ?? "The upload failed. Please share the file again.")
                case "receiving", "queued", "processing": break
                default: throw MediaError.message("Sago Media returned an unknown upload status")
                }
                lastError = nil
                transientFailures = 0
            } catch let error as URLError {
                lastError = error
                transientFailures += 1
                if transientFailures >= 5 {
                    throw MediaError.message("Your upload is saved for retry. Choose Retry Pending Uploads when the connection is available.")
                }
            }
            try await Task.sleep(for: .seconds(lastError == nil ? 1 : 3))
        }
        throw MediaError.message("Your upload is saved for retry. Choose Retry Pending Uploads when the connection is available.")
    }

    private func uploadToken() throws -> String? {
#if DEBUG
        if let smokeToken = ProcessInfo.processInfo.environment["SAGO_MEDIA_SMOKE_TOKEN"] {
            return smokeToken
        }
#endif
        return try Keychain.load()
    }

    private func send<Value: Decodable>(_ request: URLRequest, as type: Value.Type, acceptedStatuses: ClosedRange<Int> = 200...299) async throws -> Value {
        let (data, response) = try await session.data(for: request)
        return try decode(data, response: response, as: type, acceptedStatuses: acceptedStatuses)
    }

    private func decode<Value: Decodable>(_ data: Data, response: URLResponse, as type: Value.Type, acceptedStatuses: ClosedRange<Int> = 200...299) throws -> Value {
        if let http = response as? HTTPURLResponse,
           (http.statusCode >= 500 || http.statusCode == 408 || (http.statusCode == 429 && (Int(http.value(forHTTPHeaderField: "Retry-After") ?? "5") ?? 5) <= 60)) {
            throw URLError(.badServerResponse)
        }
        if (response as? HTTPURLResponse)?.statusCode == 426 {
            throw MediaError.updateRequired("Update Sago Drop to continue sharing public links.")
        }
        guard let http = response as? HTTPURLResponse, acceptedStatuses.contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MediaError.message(detail?.isEmpty == false ? detail! : "Sago Drop request failed")
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw MediaError.message("Sago Drop returned an invalid response") }
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @MainActor @Sendable (Double) -> Void

    init(onProgress: @escaping @MainActor @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        Task { @MainActor [onProgress] in onProgress(progress) }
    }
}
