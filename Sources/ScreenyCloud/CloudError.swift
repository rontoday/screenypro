import Foundation

/// Errors of the cloud uploader. Cancellation is reported as `CancellationError`, not as a `CloudError`.
public enum CloudError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidEndpoint(String)
    case invalidSecret
    case keychain(OSStatus)
    case unauthorized
    case fileMissing(URL)
    case fileTooLarge(bytes: Int64, limit: Int64)
    case invalidVideo(String)
    case network(String)
    case server(status: Int, message: String?)
    case invalidResponse(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Cloud sharing is not set up. Add the server address and the upload secret in Settings."
        case .invalidEndpoint(let value):
            return "The server address \"\(value)\" is not valid. Use an https:// address."
        case .invalidSecret:
            return "The upload secret is empty."
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Could not access the Keychain: \(text)."
        case .unauthorized:
            return "The server rejected the upload secret. Check the secret in Settings."
        case .fileMissing(let url):
            return "The file \"\(url.lastPathComponent)\" does not exist anymore."
        case .fileTooLarge(let bytes, let limit):
            let f = ByteCountFormatter()
            return "The video is too large (\(f.string(fromByteCount: bytes))). The limit is \(f.string(fromByteCount: limit))."
        case .invalidVideo(let reason):
            return "The file cannot be shared: \(reason)"
        case .network(let reason):
            return "Network problem: \(reason)"
        case .server(let status, let message):
            if let message, !message.isEmpty { return "The server returned an error (\(status)): \(message)" }
            return "The server returned an error (HTTP \(status))."
        case .invalidResponse(let reason):
            return "The server sent an unexpected response: \(reason)"
        case .notFound:
            return "This video does not exist on the server or was already deleted."
        }
    }
}
