import CoreGraphics
import Foundation

// Cloud sharing: upload a finished recording and get a link for the client.
// Implemented in ScreenyCloud. The UI depends only on this file.

public struct CloudUploadRequest: Sendable {
    public var fileURL: URL
    /// Shown on the viewer page. Defaults to the file name without extension.
    public var title: String

    public init(fileURL: URL, title: String) {
        self.fileURL = fileURL
        self.title = title
    }
}

public struct CloudShare: Codable, Hashable, Sendable {
    /// Server-side id of the video (the random code in the link).
    public var id: String
    /// The link to send to the client.
    public var shareURL: URL
    /// The server deletes the video at this time.
    public var expiresAt: Date

    public init(id: String, shareURL: URL, expiresAt: Date) {
        self.id = id
        self.shareURL = shareURL
        self.expiresAt = expiresAt
    }
}

public struct CloudConfiguration: Equatable, Sendable {
    /// Base URL of the ScreenyPro web service, e.g. `https://video.comakers.cz`.
    public var endpoint: URL

    public init(endpoint: URL) {
        self.endpoint = endpoint
    }
}

public protocol CloudUploading: AnyObject {
    /// `nil` when the endpoint or the upload secret is missing. Thread-safe.
    var configuration: CloudConfiguration? { get }
    /// Stores the endpoint (UserDefaults) and the secret (Keychain).
    func configure(endpoint: URL, secret: String) throws
    func clearConfiguration()
    /// Uploads the video (and a poster frame) directly to cloud storage and registers it.
    /// `progress` gets 0...1 on an arbitrary queue. Cancel with task cancellation; a cancelled or failed
    /// upload leaves nothing reachable on the server. Errors are `LocalizedError` with clear messages.
    func upload(_ request: CloudUploadRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudShare
    /// Deletes an uploaded video now, before it expires.
    func delete(id: String) async throws
}
