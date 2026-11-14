import AppKit
import Foundation
import ScreenyCore

/// Cloud sharing state for the whole app: the upload queue (one upload at a time), the shares that exist,
/// the cloud configuration and the in-app notice when an upload ends while its card is closed.
///
/// Threading: all state lives on the main actor. Uploads run in detached tasks, so the network and any
/// synchronous work inside the uploader never touch the main thread. Progress arrives on arbitrary queues
/// and reaches the main actor through `ProgressThrottle` (at most ~10 updates per second).
@MainActor
final class CloudShareCenter: ObservableObject {
    /// What the UI shows for one recording file.
    enum Status: Equatable {
        case idle
        case queued
        case uploading(Double)
        case failed(String)
        case shared(CloudShare)
        case removing(CloudShare)
    }

    struct Job: Equatable {
        let path: String
        let url: URL
        let title: String
    }

    /// The "notification" banner in the main window for an upload that ended while its card was closed.
    struct Notice: Equatable, Identifiable {
        enum Kind: Equatable {
            case shared(CloudShare, copied: Bool)
            case failed(String)
        }
        let id = UUID()
        let kind: Kind
        let path: String
        let url: URL
        let title: String
    }

    // MARK: Published state

    @Published private(set) var configuration: CloudConfiguration?
    @Published private(set) var shares: [String: CloudShare] = [:]
    @Published private(set) var active: Job?
    /// 0...1 of `active`.
    @Published private(set) var progress: Double = 0
    @Published private(set) var queue: [Job] = []
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var removing: Set<String> = []
    @Published private(set) var removeErrors: [String: String] = [:]
    /// The file whose link was just copied; cleared after a short time ("Link copied" confirmation).
    @Published private(set) var copiedPath: String?
    @Published var notice: Notice?
    @Published var isSettingsShown = false
    @Published var isRecordingsShown = false
    /// Edited titles, by file path. Missing = the file name without extension.
    @Published private var titles: [String: String] = [:]

    // MARK: Hooks set by the app

    /// True while a recording session (countdown … finishing) runs: the clipboard is left alone then.
    var isCapturing: () -> Bool = { false }
    /// True while the main window is on screen.
    var isMainWindowShown: () -> Bool = { true }
    /// The finished card currently on screen shows this file.
    var visibleCardPath: String?

    // MARK: Private

    private let cloud: CloudUploading
    private let defaults: UserDefaults
    private var uploadTask: Task<Void, Never>?
    /// Bumped on every start and cancel, so results of a cancelled upload are recognized and ignored.
    private var generation = 0
    /// Cancelled uploads that may still be cleaning up (awaited briefly on quit).
    private var unwinding: [Int: Task<Void, Never>] = [:]
    private var copiedClear: Task<Void, Never>?
    /// "Set Up Cloud Sharing…" from an upload button: start this upload after a successful setup.
    private var pendingAfterSetup: (url: URL, title: String)?

    static let sharesKey = "ScreenyPro.cloudShares.v1"

    init(cloud: CloudUploading, defaults: UserDefaults = .standard) {
        self.cloud = cloud
        self.defaults = defaults
        configuration = cloud.configuration
        shares = Self.loadShares(from: defaults)
        pruneShares()
    }

    // MARK: - Queries

    /// Stable identity of a recording file. Symlinks are resolved: a folder listing returns resolved paths,
    /// the recorder may not (for example when ~/Movies is a symlink).
    static func key(_ url: URL) -> String {
        if let cached = keyCache[url] { return cached }
        let key = url.resolvingSymlinksInPath().standardizedFileURL.path
        if keyCache.count > 500 { keyCache.removeAll() }
        keyCache[url] = key
        return key
    }

    private static var keyCache: [URL: String] = [:]

    var isBusy: Bool { active != nil || !queue.isEmpty }

    func status(for url: URL) -> Status {
        let path = Self.key(url)
        if active?.path == path { return .uploading(progress) }
        if queue.contains(where: { $0.path == path }) { return .queued }
        if let share = shares[path], share.expiresAt > Date() {
            return removing.contains(path) ? .removing(share) : .shared(share)
        }
        if let message = failures[path] { return .failed(message) }
        return .idle
    }

    func title(for url: URL) -> String {
        titles[Self.key(url)] ?? Self.defaultTitle(for: url)
    }

    func setTitle(_ title: String, for url: URL) {
        titles[Self.key(url)] = title
    }

    static func defaultTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    func isCopied(_ url: URL) -> Bool { copiedPath == Self.key(url) }

    // MARK: - Upload queue

    /// "Upload & Copy Link". Without a configuration opens the settings and uploads after a successful setup.
    /// Repeated requests for the same file are ignored; a file that is already shared only copies its link.
    func upload(_ url: URL, title rawTitle: String? = nil) {
        let path = Self.key(url)
        let typed = (rawTitle ?? title(for: url)).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = typed.isEmpty ? Self.defaultTitle(for: url) : typed
        guard configuration != nil else {
            pendingAfterSetup = (url, title)
            isSettingsShown = true
            return
        }
        if active?.path == path || queue.contains(where: { $0.path == path }) { return }
        if case .shared(let share) = status(for: url) {
            copy(share, path: path)
            return
        }
        failures[path] = nil
        queue.append(Job(path: path, url: url, title: title))
        startNextIfIdle()
    }

    /// Cancels the running or a waiting upload of this file.
    func cancelUpload(for url: URL) {
        let path = Self.key(url)
        if active?.path == path {
            cancelActive()
            startNextIfIdle()
        } else {
            queue.removeAll { $0.path == path }
        }
    }

    private func cancelActive() {
        guard active != nil else { return }
        let task = uploadTask
        task?.cancel()
        let token = generation
        if let task {
            unwinding[token] = Task { [weak self] in
                await task.value
                self?.unwinding[token] = nil
            }
        }
        generation += 1
        uploadTask = nil
        active = nil
        progress = 0
    }

    private func startNextIfIdle() {
        guard active == nil, configuration != nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        generation += 1
        let token = generation
        active = job
        progress = 0
        let throttle = ProgressThrottle(interval: 0.1) { [weak self] value in
            self?.progressDidChange(value, token: token)
        }
        let cloud = self.cloud
        let request = CloudUploadRequest(fileURL: job.url, title: job.title)
        uploadTask = Task.detached(priority: .utility) { [weak self] in
            let result: Result<CloudShare, Error>
            do {
                let share = try await cloud.upload(request) { value in throttle.push(value) }
                result = .success(share)
            } catch {
                result = .failure(error)
            }
            await self?.uploadDidEnd(job, token: token, result: result)
        }
    }

    private func progressDidChange(_ value: Double, token: Int) {
        guard token == generation, active != nil else { return }
        let clamped = min(max(value.isFinite ? value : 0, 0), 1)
        // Monotonic within one upload, so part retries do not make the bar jump back and forth.
        if clamped > progress + 0.001 { progress = clamped }
    }

    private func uploadDidEnd(_ job: Job, token: Int, result: Result<CloudShare, Error>) {
        guard token == generation else {
            // Cancelled by the user. If the upload still completed, honor the cancel: remove it from the server.
            if case .success(let share) = result {
                let cloud = self.cloud
                Task.detached { try? await cloud.delete(id: share.id) }
            }
            return
        }
        uploadTask = nil
        active = nil
        progress = 0
        switch result {
        case .success(let share):
            shares[job.path] = share
            failures[job.path] = nil
            saveShares()
            deliver(share, for: job)
        case .failure(let error):
            if Self.isCancellation(error) {
                // Cancelled from outside (quit): leave no error behind.
                break
            }
            let message = Self.message(for: error)
            failures[job.path] = message
            if !isShownInline(job.path) {
                notice = Notice(kind: .failed(message), path: job.path, url: job.url, title: job.title)
                requestAttentionIfInactive()
            }
        }
        startNextIfIdle()
    }

    /// Copies the link (not during a recording session) and confirms inline or with the notice banner.
    private func deliver(_ share: CloudShare, for job: Job) {
        let copied = !isCapturing()
        if copied { copy(share, path: job.path) }
        if !isShownInline(job.path) {
            notice = Notice(kind: .shared(share, copied: copied), path: job.path, url: job.url, title: job.title)
            requestAttentionIfInactive()
        }
    }

    /// The finished card of this file or the recordings list is on screen and shows the result itself.
    private func isShownInline(_ path: String) -> Bool {
        guard isMainWindowShown() else { return false }
        return visibleCardPath == path || isRecordingsShown
    }

    private func requestAttentionIfInactive() {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    // MARK: - Links

    func copyLink(for url: URL) {
        guard case .shared(let share) = status(for: url) else { return }
        copy(share, path: Self.key(url))
    }

    func copy(_ share: CloudShare, path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(share.shareURL.absoluteString, forType: .string)
        pasteboard.setString(share.shareURL.absoluteString, forType: .URL)
        copiedPath = path
        copiedClear?.cancel()
        copiedClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.copiedPath = nil
        }
    }

    func open(_ share: CloudShare) {
        NSWorkspace.shared.open(share.shareURL)
    }

    /// "Remove from cloud": deletes the video on the server now.
    func removeFromCloud(_ url: URL) {
        let path = Self.key(url)
        guard let share = shares[path], !removing.contains(path) else { return }
        removing.insert(path)
        removeErrors[path] = nil
        let cloud = self.cloud
        Task.detached { [weak self] in
            var failure: String?
            do {
                try await cloud.delete(id: share.id)
            } catch {
                failure = Self.message(for: error)
            }
            await self?.removeDidEnd(path: path, shareID: share.id, failure: failure)
        }
    }

    private func removeDidEnd(path: String, shareID: String, failure: String?) {
        removing.remove(path)
        if let failure {
            removeErrors[path] = failure
            return
        }
        if shares[path]?.id == shareID {
            shares[path] = nil
            saveShares()
        }
        if notice?.path == path { notice = nil }
        if copiedPath == path { copiedPath = nil }
    }

    func removeError(for url: URL) -> String? { removeErrors[Self.key(url)] }

    /// The most recent share that is still valid (status item "Copy Last Link").
    var latestShare: (path: String, share: CloudShare)? {
        let now = Date()
        return shares.filter { $0.value.expiresAt > now }
            .max { $0.value.expiresAt < $1.value.expiresAt }
            .map { ($0.key, $0.value) }
    }

    // MARK: - Configuration

    func showSettings() {
        pendingAfterSetup = nil
        isSettingsShown = true
    }

    /// The settings sheet was closed without saving.
    func settingsDismissed() {
        pendingAfterSetup = nil
    }

    /// Saves endpoint and secret (Keychain work runs off the main thread). Starts a pending upload.
    func configure(endpoint: URL, secret: String) async throws {
        let cloud = self.cloud
        let box = UncheckedBox(cloud)
        let configuration = try await Task.detached(priority: .userInitiated) { () throws -> CloudConfiguration? in
            try box.value.configure(endpoint: endpoint, secret: secret)
            return box.value.configuration
        }.value
        self.configuration = configuration
        if configuration != nil, let pending = pendingAfterSetup {
            pendingAfterSetup = nil
            upload(pending.url, title: pending.title)
        }
        startNextIfIdle()
    }

    func disconnect() {
        let box = UncheckedBox(cloud)
        pendingAfterSetup = nil
        configuration = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            box.value.clearConfiguration()
            let configuration = box.value.configuration
            await self?.setConfiguration(configuration)
        }
    }

    /// Re-reads the configuration (off the main thread), e.g. when the app becomes active.
    func refreshConfiguration() {
        let box = UncheckedBox(cloud)
        Task.detached(priority: .utility) { [weak self] in
            let configuration = box.value.configuration
            await self?.setConfiguration(configuration)
        }
    }

    private func setConfiguration(_ configuration: CloudConfiguration?) {
        if self.configuration != configuration { self.configuration = configuration }
        startNextIfIdle()
    }

    // MARK: - Quit

    /// Cancels every upload and waits up to `timeout` for the uploader to clean up.
    func cancelAllForQuit(timeout: TimeInterval = 2) async {
        queue.removeAll()
        cancelActive()
        let tasks = Array(unwinding.values)
        guard !tasks.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for task in tasks { await task.value }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Persistence

    /// Drops shares that expired or whose file is gone.
    func pruneShares() {
        let now = Date()
        let fm = FileManager.default
        let kept = shares.filter { $0.value.expiresAt > now && fm.fileExists(atPath: $0.key) }
        if kept.count != shares.count {
            shares = kept
            saveShares()
        }
    }

    private func saveShares() {
        guard let data = try? JSONEncoder().encode(shares) else { return }
        defaults.set(data, forKey: Self.sharesKey)
    }

    private static func loadShares(from defaults: UserDefaults) -> [String: CloudShare] {
        guard let data = defaults.data(forKey: sharesKey),
              let shares = try? JSONDecoder().decode([String: CloudShare].self, from: data)
        else { return [:] }
        return shares
    }

    // MARK: - Errors

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    nonisolated static func message(for error: Error) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Unknown error." : text
    }
}

/// Delivers the latest value on the main actor at most once per `interval`. `push` is thread-safe.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Double = 0
    private var scheduled = false
    private let interval: TimeInterval
    private let deliver: @MainActor (Double) -> Void

    init(interval: TimeInterval, deliver: @escaping @MainActor (Double) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    func push(_ value: Double) {
        lock.lock()
        latest = value
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [self] in
            lock.lock()
            let value = latest
            scheduled = false
            lock.unlock()
            MainActor.assumeIsolated { deliver(value) }
        }
    }
}

/// Moves a value that is thread-safe by contract (`CloudUploading`) into a detached task.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

enum CloudFormat {
    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy 'at' HH:mm"
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    /// "Nov 27, 2026 at 12:32"
    static func expiry(_ date: Date) -> String { dateTime.string(from: date) }

    /// "Nov 27"
    static func shortExpiry(_ date: Date) -> String { shortDate.string(from: date) }

    /// "video.comakers.cz/v/AbC…" without the scheme.
    static func displayLink(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
    }

    static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded(.down)))%"
    }
}
