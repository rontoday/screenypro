import Foundation

// Direct-to-storage transfer with presigned URLs issued by the ScreenyPro web service.
//
// Protocol (Vercel Blob HTTP API, as spoken by @vercel/blob 2.9 with presigned URLs):
// - every request carries the `uploadHeaders` the server returned (x-api-version, x-vercel-blob-store-id,
//   x-vercel-blob-access) plus `x-content-type`;
// - small file: `PUT <putUrl>` with the whole body;
// - large file: `POST <multipartUrl>` with `x-mpu-action: create` → {key, uploadId};
//   then per part `x-mpu-action: upload`, `x-mpu-key` (URI-encoded key), `x-mpu-upload-id`,
//   `x-mpu-part-number` → {etag}; then `x-mpu-action: complete` with JSON [{etag, partNumber}].
// The presigned query signs pathname, content type, max size and TTL, so the client cannot change them.

struct CreateUploadResponse: Decodable, Sendable {
    struct Target: Decodable, Sendable {
        var contentType: String
        var putUrl: URL
        var multipartUrl: URL
    }
    var id: String
    var uploadHeaders: [String: String]
    var partSizeBytes: Int64
    var multipartThresholdBytes: Int64
    var video: Target
    var poster: Target?
}

struct CompleteUploadResponse: Decodable, Sendable {
    var id: String
    var shareUrl: URL
    var expiresAt: String
}

private struct ServerErrorBody: Decodable {
    struct Inner: Decodable { var code: String?; var message: String? }
    var error: Inner?
}

/// Thread-safe byte counter that turns per-request progress into one 0...1 value.
final class TransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private var done: Int64 = 0
    private var inFlight: [Int: Int64] = [:]
    private var lastReported: Double = -1
    private let report: @Sendable (Double) -> Void
    /// Share of the bar for the transfer; the rest is for registration at the end.
    private let span: Double

    init(totalBytes: Int64, span: Double = 0.99, report: @escaping @Sendable (Double) -> Void) {
        self.total = max(totalBytes, 1)
        self.span = span
        self.report = report
    }

    func update(slot: Int, sent: Int64) {
        lock.lock()
        inFlight[slot] = sent
        let value = fractionLocked()
        let shouldReport = value - lastReported >= 0.002
        if shouldReport { lastReported = value }
        lock.unlock()
        if shouldReport { report(value) }
    }

    func finish(slot: Int, bytes: Int64) {
        lock.lock()
        inFlight[slot] = nil
        done += bytes
        let value = fractionLocked()
        lastReported = value
        lock.unlock()
        report(value)
    }

    /// A failed attempt: forget what this slot had sent.
    func reset(slot: Int) {
        lock.lock()
        inFlight[slot] = nil
        lock.unlock()
    }

    private func fractionLocked() -> Double {
        let sent = done + inFlight.values.reduce(0, +)
        return min(Double(sent) / Double(total), 1) * span
    }
}

final class TaskProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onSent: @Sendable (Int64) -> Void
    init(onSent: @escaping @Sendable (Int64) -> Void) { self.onSent = onSent }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        onSent(totalBytesSent)
    }
}

enum HTTP {
    /// Retries on network errors, 408, 429 and 5xx: 3 tries, backoff 1 s, 2 s.
    static func withRetry<T: Sendable>(
        tries: Int = 3,
        onRetry: @Sendable () -> Void = {},
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch {
                try Task.checkCancellation()
                guard attempt < tries, isRetryable(error) else { throw error }
                onRetry()
                try await Task.sleep(nanoseconds: UInt64(1 << (attempt - 1)) * 1_000_000_000)
                attempt += 1
            }
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case CloudError.network: return true
        case CloudError.server(let status, _): return status == 408 || status == 429 || status >= 500
        default: return false
        }
    }

    /// Maps transport errors; turns a cancelled request into `CancellationError`.
    static func mapTransport(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return CloudError.network(urlError.localizedDescription)
        }
        return error
    }

    /// Checks the status; returns the body for 2xx.
    static func check(_ data: Data, _ response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw CloudError.invalidResponse("not HTTP") }
        if (200..<300).contains(http.statusCode) { return data }
        let body = try? JSONDecoder().decode(ServerErrorBody.self, from: data)
        // 401 "unauthorized" comes from our API (wrong upload secret). Storage 403s, e.g. an expired
        // presigned URL, stay server errors.
        if http.statusCode == 401, body?.error?.code == "unauthorized" { throw CloudError.unauthorized }
        let message = body?.error?.message
            ?? String(data: data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw CloudError.server(status: http.statusCode, message: message)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CloudError.invalidResponse("\(error)")
        }
    }
}

/// `encodeURIComponent` from JavaScript (the SDK encodes `x-mpu-key` this way).
func encodeURIComponent(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
    allowed.insert(charactersIn: "-_.!~*'()")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

struct BlobUploader: Sendable {
    let session: URLSession
    let headers: [String: String]

    private func request(_ url: URL, method: String, contentType: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(contentType, forHTTPHeaderField: "x-content-type")
        return request
    }

    private func send(_ request: URLRequest, body: Data? = nil, file: URL? = nil, onSent: (@Sendable (Int64) -> Void)? = nil) async throws -> Data {
        let delegate = onSent.map(TaskProgressDelegate.init(onSent:))
        do {
            let (data, response): (Data, URLResponse)
            if let file {
                (data, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
            } else if let body {
                (data, response) = try await session.upload(for: request, from: body, delegate: delegate)
            } else {
                (data, response) = try await session.data(for: request, delegate: delegate)
            }
            return try HTTP.check(data, response)
        } catch {
            throw HTTP.mapTransport(error)
        }
    }

    /// Small blobs (poster, short videos): one PUT, streamed from disk when `file` is given.
    func putWhole(target: CreateUploadResponse.Target, data: Data? = nil, file: URL? = nil, size: Int64, slot: Int, progress: TransferProgress) async throws {
        let request = request(target.putUrl, method: "PUT", contentType: target.contentType)
        try await HTTP.withRetry(onRetry: { progress.reset(slot: slot) }) {
            _ = try await send(request, body: data, file: file) { progress.update(slot: slot, sent: $0) }
        }
        progress.finish(slot: slot, bytes: size)
    }

    private struct MultipartCreated: Decodable { var key: String; var uploadId: String }
    private struct PartResult: Decodable { var etag: String }
    private struct CompletedPart: Codable, Sendable { var etag: String; var partNumber: Int }

    /// Large videos: multipart, parts read from disk one at a time (never the whole file), each retried up to 3 times.
    func putMultipart(
        target: CreateUploadResponse.Target, file: URL, size: Int64, partSize: Int64,
        concurrency: Int = 4, firstSlot: Int, progress: TransferProgress
    ) async throws {
        let createRequest: URLRequest = {
            var r = request(target.multipartUrl, method: "POST", contentType: target.contentType)
            r.setValue("create", forHTTPHeaderField: "x-mpu-action")
            return r
        }()
        let created = try await HTTP.withRetry {
            try HTTP.decode(MultipartCreated.self, from: try await send(createRequest))
        }

        let partCount = Int((size + partSize - 1) / partSize)
        guard partCount <= 10_000 else { throw CloudError.fileTooLarge(bytes: size, limit: partSize * 10_000) }
        let encodedKey = encodeURIComponent(created.key)

        func uploadPart(_ number: Int) async throws -> CompletedPart {
            let offset = Int64(number - 1) * partSize
            let length = min(partSize, size - offset)
            let data: Data
            do {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset))
                data = try handle.read(upToCount: Int(length)) ?? Data()
            } catch {
                throw CloudError.fileMissing(file)
            }
            guard Int64(data.count) == length else { throw CloudError.invalidVideo("the file changed during upload.") }
            var r = request(target.multipartUrl, method: "POST", contentType: target.contentType)
            r.setValue("upload", forHTTPHeaderField: "x-mpu-action")
            r.setValue(encodedKey, forHTTPHeaderField: "x-mpu-key")
            r.setValue(created.uploadId, forHTTPHeaderField: "x-mpu-upload-id")
            r.setValue(String(number), forHTTPHeaderField: "x-mpu-part-number")
            let slot = firstSlot + number
            let partRequest = r
            let result = try await HTTP.withRetry(onRetry: { progress.reset(slot: slot) }) {
                try HTTP.decode(PartResult.self, from: try await send(partRequest, body: data) { progress.update(slot: slot, sent: $0) })
            }
            progress.finish(slot: slot, bytes: length)
            return CompletedPart(etag: result.etag, partNumber: number)
        }

        var parts: [CompletedPart] = []
        parts.reserveCapacity(partCount)
        try await withThrowingTaskGroup(of: CompletedPart.self) { group in
            var next = 1
            while next <= min(concurrency, partCount) {
                let n = next
                group.addTask { try await uploadPart(n) }
                next += 1
            }
            while let part = try await group.next() {
                parts.append(part)
                if next <= partCount {
                    let n = next
                    group.addTask { try await uploadPart(n) }
                    next += 1
                }
            }
        }
        parts.sort { $0.partNumber < $1.partNumber }

        var completeRequest = request(target.multipartUrl, method: "POST", contentType: target.contentType)
        completeRequest.setValue("complete", forHTTPHeaderField: "x-mpu-action")
        completeRequest.setValue(encodedKey, forHTTPHeaderField: "x-mpu-key")
        completeRequest.setValue(created.uploadId, forHTTPHeaderField: "x-mpu-upload-id")
        completeRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        let body = try JSONEncoder().encode(parts)
        let finalRequest = completeRequest
        _ = try await HTTP.withRetry { try await send(finalRequest, body: body) }
    }
}
