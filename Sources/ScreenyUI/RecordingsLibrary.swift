import AppKit
import Foundation

/// The most recent recordings in the recordings folder, for the "Recent Recordings" list.
/// The folder scan and the media facts load off the main thread.
@MainActor
final class RecordingsLibrary: ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: String { url.path }
        let url: URL
        let date: Date
        let fileSize: Int64

        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var infos: [String: RecordingInfo] = [:]
    @Published private(set) var isLoaded = false

    nonisolated static let limit = 20
    private var loadTask: Task<Void, Never>?
    /// Modification dates the cached infos were loaded for, so a rewritten file reloads.
    private var infoDates: [String: Date] = [:]

    func reload() {
        let folder = RecorderController.recordingsFolder
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) { Self.scan(folder) }.value
            guard let self, !Task.isCancelled else { return }
            self.items = scanned.map { $0.item }
            self.isLoaded = true
            let live = Set(scanned.map { $0.item.id })
            self.infos = self.infos.filter { live.contains($0.key) }
            for entry in scanned {
                let id = entry.item.id
                if self.infos[id] != nil, self.infoDates[id] == entry.modified { continue }
                let info = await RecordingInfo.load(url: entry.item.url, thumbnailSide: 192, backdrop: false)
                if Task.isCancelled { return }
                self.infos[id] = info
                self.infoDates[id] = entry.modified
            }
        }
    }

    private nonisolated static func scan(_ folder: URL) -> [(item: Item, modified: Date)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        let movieExtensions: Set<String> = ["mp4", "mov", "m4v"]
        var result: [(item: Item, modified: Date)] = []
        for url in urls where movieExtensions.contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let date = values.creationDate ?? modified
            result.append((Item(url: url.standardizedFileURL, date: date, fileSize: Int64(values.fileSize ?? 0)), modified))
        }
        result.sort { $0.item.date > $1.item.date }
        return Array(result.prefix(limit))
    }
}
