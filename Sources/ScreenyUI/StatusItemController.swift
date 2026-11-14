import AppKit
import Combine
import ScreenyCore

/// Menu bar item. Idle: a menu (with upload progress while an upload runs). Recording: elapsed time in red,
/// a click stops.
@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let controller: RecorderController
    private let idleMenu = NSMenu()
    private let openMain: () -> Void
    var onCloudSettings: (() -> Void)?

    // Upload section of the idle menu (hidden when there is nothing to show).
    private let uploadItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var cancelUploadItem: ClosureMenuItem!
    private let queueItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var copyLastItem: ClosureMenuItem!
    private let uploadSeparator = NSMenuItem.separator()
    private var cancellables: Set<AnyCancellable> = []
    private var refreshQueued = false
    private var lastState: RecorderController.State = .idle
    private var lastElapsed: TimeInterval = 0

    init(controller: RecorderController, openMain: @escaping () -> Void) {
        self.controller = controller
        self.openMain = openMain
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(buttonClicked(_:))
        buildMenu()
        update(state: .idle, elapsed: 0)
        // Upload progress is already throttled to ~10 Hz; coalesce bursts of other changes to one refresh.
        controller.sharing.objectWillChange
            .sink { [weak self] _ in self?.queueRefresh() }
            .store(in: &cancellables)
    }

    private func buildMenu() {
        uploadItem.isEnabled = false
        queueItem.isEnabled = false
        cancelUploadItem = ClosureMenuItem(title: "Cancel Upload") { [weak self] in
            guard let self, let job = self.controller.sharing.active else { return }
            self.controller.sharing.cancelUpload(for: job.url)
        }
        cancelUploadItem.indentationLevel = 1
        copyLastItem = ClosureMenuItem(title: "Copy Last Link") { [weak self] in
            guard let self, let latest = self.controller.sharing.latestShare else { return }
            self.controller.sharing.copy(latest.share, path: latest.path)
        }
        idleMenu.autoenablesItems = false
        idleMenu.addItem(uploadItem)
        idleMenu.addItem(cancelUploadItem)
        idleMenu.addItem(queueItem)
        idleMenu.addItem(copyLastItem)
        idleMenu.addItem(uploadSeparator)

        let start = ClosureMenuItem(title: "Start Recording", keyEquivalent: "r") { [weak self] in
            self?.controller.toggleRecording()
        }
        start.keyEquivalentModifierMask = [.command, .shift]
        idleMenu.addItem(start)
        idleMenu.addItem(ClosureMenuItem(title: "Open ScreenyPro") { [weak self] in self?.openMain() })
        idleMenu.addItem(ClosureMenuItem(title: "Recent Recordings…") { [weak self] in
            guard let self else { return }
            self.openMain()
            DispatchQueue.main.async { self.controller.sharing.isRecordingsShown = true }
        })
        idleMenu.addItem(ClosureMenuItem(title: "Open Recordings Folder") { RecorderController.openRecordingsFolder() })
        idleMenu.addItem(ClosureMenuItem(title: "Cloud Settings…") { [weak self] in self?.onCloudSettings?() })
        idleMenu.addItem(.separator())
        idleMenu.addItem(ClosureMenuItem(title: "Quit ScreenyPro", keyEquivalent: "q") { NSApp.terminate(nil) })
        refreshUploadItems()
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        // objectWillChange fires before the new value is stored: read it on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refreshUploadItems()
            self.update(state: self.lastState, elapsed: self.lastElapsed)
        }
    }

    /// Menu item titles update live, also while the menu is open.
    private func refreshUploadItems() {
        let sharing = controller.sharing
        if let job = sharing.active {
            uploadItem.title = "Uploading “\(job.title)” — \(CloudFormat.percent(sharing.progress))"
            uploadItem.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: nil)
            uploadItem.isHidden = false
            cancelUploadItem.isHidden = false
        } else {
            uploadItem.isHidden = true
            cancelUploadItem.isHidden = true
        }
        let waiting = sharing.queue.count
        queueItem.title = waiting == 1 ? "1 more upload waiting" : "\(waiting) more uploads waiting"
        queueItem.isHidden = waiting == 0
        if let latest = sharing.latestShare {
            let name = URL(fileURLWithPath: latest.path).deletingPathExtension().lastPathComponent
            copyLastItem.title = sharing.copiedPath == latest.path ? "Link Copied" : "Copy Link: \(name)"
            copyLastItem.toolTip = "\(latest.share.shareURL.absoluteString)\nAvailable until \(CloudFormat.expiry(latest.share.expiresAt))"
            copyLastItem.isHidden = false
        } else {
            copyLastItem.isHidden = true
        }
        uploadSeparator.isHidden = uploadItem.isHidden && queueItem.isHidden && copyLastItem.isHidden
    }

    /// Test and debug aid: the visible titles of the idle menu.
    var idleMenuTitles: [String] {
        idleMenu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    func update(state: RecorderController.State, elapsed: TimeInterval) {
        lastState = state
        lastElapsed = elapsed
        guard let button = item.button else { return }
        switch state {
        case .idle, .finished:
            item.menu = idleMenu
            button.image = Self.symbol("record.circle")
            if let _ = controller.sharing.active {
                // Quiet progress next to the icon, so an upload is visible with the main window closed.
                button.imagePosition = .imageLeading
                button.attributedTitle = Self.title(" " + CloudFormat.percent(controller.sharing.progress), color: .secondaryLabelColor)
                button.toolTip = "ScreenyPro — uploading"
            } else {
                button.attributedTitle = NSAttributedString(string: "")
                button.imagePosition = .imageOnly
                button.toolTip = "ScreenyPro"
            }
        case .countdown(let n):
            item.menu = nil
            button.image = nil
            button.attributedTitle = Self.title("\(n)", color: .labelColor)
            button.toolTip = "Click to cancel"
        case .recording, .paused:
            item.menu = nil
            let paused = state == .paused
            button.image = Self.symbol(paused ? "pause.circle.fill" : "record.circle.fill", tint: paused ? nil : Theme.nsRecord)
            button.imagePosition = .imageLeading
            button.attributedTitle = Self.title(" " + Format.elapsed(elapsed), color: paused ? .secondaryLabelColor : Theme.nsRecord)
            button.toolTip = "Click to stop and save"
        case .finishing:
            item.menu = nil
            button.image = nil
            button.attributedTitle = Self.title("Saving…", color: .secondaryLabelColor)
            button.toolTip = "Saving the recording"
        }
    }

    @objc private func buttonClicked(_ sender: Any?) {
        // Only reached while the menu is detached (countdown, recording).
        switch controller.state {
        case .countdown: controller.cancelCountdown()
        case .recording, .paused: controller.stopRecording()
        default: break
        }
    }

    private static func symbol(_ name: String, tint: NSColor? = nil) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "ScreenyPro") else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let image = base.withSymbolConfiguration(config) else { return base }
        if let tint {
            let colored = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint])) ?? image
            colored.isTemplate = false
            return colored
        }
        image.isTemplate = true
        return image
    }

    private static func title(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color,
        ])
    }
}
