import Foundation
import ScreenyCore

/// Uploads recordings to the ScreenyPro web service (`web/`) and returns a share link.
///
/// Flow: `POST /api/videos` (bearer secret) → presigned direct-to-storage uploads of the poster and the video →
/// `POST /api/videos/<id>/complete` writes the video's metadata; only then is `/v/<id>` watchable.
/// On cancellation or failure after step 1 it calls `DELETE /api/videos/<id>` so nothing stays behind.
public final class CloudUploader: CloudUploading, @unchecked Sendable {
    public static let defaultKeychainService = "cz.comakers.screenypro.cloud"
    public static let maxVideoBytes: Int64 = 5 * 1024 * 1024 * 1024

    private let store: CloudCredentialStore
    private let session: URLSession
    private let lock = NSLock()
    /// Cached so `configuration` never blocks on the Keychain after the first read.
    private var cachedSecret: String??

    /// The app's uploader: standard UserDefaults, Keychain service `cz.comakers.screenypro.cloud`.
    public convenience init() {
        self.init(defaults: .standard, keychainService: Self.defaultKeychainService)
    }

    /// Injectable storage, for tools and tests that must not touch the app's settings.
    public init(defaults: UserDefaults, keychainService: String) {
        store = CloudCredentialStore(defaults: defaults, service: keychainService)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120 // idle timeout per request
        config.timeoutIntervalForResource = 24 * 3600
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    // MARK: - Configuration

    private func secret() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedSecret { return cachedSecret }
        let value = try? store.readSecret()
        cachedSecret = .some(value)
        return value
    }

    public var configuration: CloudConfiguration? {
        guard let endpoint = store.endpoint, secret() != nil else { return nil }
        return CloudConfiguration(endpoint: endpoint)
    }

    public func configure(endpoint: URL, secret rawSecret: String) throws {
        let normalized = try Self.normalize(endpoint)
        let secret = rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw CloudError.invalidSecret }
        lock.lock()
        defer { lock.unlock() }
        try store.writeSecret(secret)
        cachedSecret = .some(secret)
        store.endpoint = normalized
    }

    public func clearConfiguration() {
        lock.lock()
        defer { lock.unlock() }
        store.deleteSecret()
        store.endpoint = nil
        cachedSecret = .some(nil)
    }

    static func normalize(_ endpoint: URL) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty
        else { throw CloudError.invalidEndpoint(endpoint.absoluteString) }
        let isLocal = host == "localhost" || host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && isLocal) else {
            throw CloudError.invalidEndpoint(endpoint.absoluteString)
        }
        components.scheme = scheme
        components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw CloudError.invalidEndpoint(endpoint.absoluteString) }
        return url
    }

    private func credentials() throws -> (endpoint: URL, secret: String) {
        guard let endpoint = store.endpoint, let secret = secret() else { throw CloudError.notConfigured }
        return (endpoint, secret)
    }

    // MARK: - API calls

    private func apiRequest(_ endpoint: URL, _ path: String, method: String, secret: String, json: Any? = nil) throws -> URLRequest {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    private func call(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            return try HTTP.check(data, response)
        } catch {
            throw HTTP.mapTransport(error)
        }
    }

    // MARK: - Upload

    public func upload(_ request: CloudUploadRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudShare {
        let (endpoint, secret) = try credentials()
        let file = request.fileURL

        // Local checks before anything reaches the server.
        let size: Int64
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let bytes = values.fileSize else { throw CloudError.fileMissing(file) }
            size = Int64(bytes)
        } catch let error as CloudError {
            throw error
        } catch {
            throw CloudError.fileMissing(file)
        }
        guard size > 0 else { throw CloudError.invalidVideo("the file is empty.") }
        guard size <= Self.maxVideoBytes else { throw CloudError.fileTooLarge(bytes: size, limit: Self.maxVideoBytes) }

        progress(0)
        let facts = try await VideoInspector.facts(of: file)
        let poster = await VideoInspector.posterJPEG(of: file, durationSeconds: facts.durationSeconds)
        try Task.checkCancellation()

        // Step 1: reserve an id and get presigned upload URLs.
        var body: [String: Any] = ["videoBytes": size, "videoContentType": "video/mp4"]
        if let poster {
            body["posterBytes"] = poster.count
            body["posterContentType"] = "image/jpeg"
        }
        let createRequest = try apiRequest(endpoint, "api/videos", method: "POST", secret: secret, json: body)
        let created = try HTTP.decode(CreateUploadResponse.self, from: try await HTTP.withRetry { try await self.call(createRequest) })
        guard Self.isValidId(created.id) else { throw CloudError.invalidResponse("bad video id") }

        do {
            let share = try await transferAndComplete(
                created: created, file: file, size: size, poster: poster, facts: facts,
                title: request.title, endpoint: endpoint, secret: secret, progress: progress
            )
            progress(1)
            return share
        } catch {
            // Cancelled or failed: remove whatever reached storage. Runs detached so it is not cancelled itself.
            let id = created.id
            await Task.detached { [self] in try? await self.deleteRemote(id: id, endpoint: endpoint, secret: secret) }.value
            throw error
        }
    }

    private func transferAndComplete(
        created: CreateUploadResponse, file: URL, size: Int64, poster: Data?, facts: VideoFacts,
        title: String, endpoint: URL, secret: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudShare {
        let posterBytes = Int64(poster?.count ?? 0)
        let tracker = TransferProgress(totalBytes: size + posterBytes, report: progress)
        let uploader = BlobUploader(session: session, headers: created.uploadHeaders)

        if let poster, let target = created.poster {
            try await uploader.putWhole(target: target, data: poster, size: posterBytes, slot: 0, progress: tracker)
        }
        try Task.checkCancellation()
        if size > created.multipartThresholdBytes {
            let partSize = max(created.partSizeBytes, 5 * 1024 * 1024)
            try await uploader.putMultipart(
                target: created.video, file: file, size: size, partSize: partSize, firstSlot: 1, progress: tracker
            )
        } else {
            try await uploader.putWhole(target: created.video, file: file, size: size, slot: 1, progress: tracker)
        }
        try Task.checkCancellation()

        // Step 2: register. Only now does the link work.
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let completeBody: [String: Any] = [
            "title": cleanTitle.isEmpty ? file.deletingPathExtension().lastPathComponent : cleanTitle,
            "durationSeconds": facts.durationSeconds,
            "width": facts.width,
            "height": facts.height,
        ]
        let completeRequest = try apiRequest(
            endpoint, "api/videos/\(created.id)/complete", method: "POST", secret: secret, json: completeBody
        )
        let data = try await HTTP.withRetry { try await self.call(completeRequest) }
        let completed = try HTTP.decode(CompleteUploadResponse.self, from: data)
        guard let expiresAt = Self.parseDate(completed.expiresAt) else {
            throw CloudError.invalidResponse("bad expiry date")
        }
        return CloudShare(id: completed.id, shareURL: completed.shareUrl, expiresAt: expiresAt)
    }

    // MARK: - Delete

    public func delete(id: String) async throws {
        let (endpoint, secret) = try credentials()
        guard Self.isValidId(id) else { throw CloudError.notFound }
        try await deleteRemote(id: id, endpoint: endpoint, secret: secret)
    }

    private func deleteRemote(id: String, endpoint: URL, secret: String) async throws {
        let request = try apiRequest(endpoint, "api/videos/\(id)", method: "DELETE", secret: secret)
        do {
            _ = try await HTTP.withRetry { try await self.call(request) }
        } catch CloudError.server(let status, _) where status == 404 {
            throw CloudError.notFound
        }
    }

    // MARK: - Helpers

    static func isValidId(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{20,64}$", options: .regularExpression) != nil
    }

    static func parseDate(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
