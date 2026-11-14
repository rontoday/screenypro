import AppKit
import ScreenyCore

/// Menu bar item. Idle: a menu. Recording: elapsed time in red, a click stops.
@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let controller: RecorderController
    private let idleMenu = NSMenu()
    private let openMain: () -> Void

    init(controller: RecorderController, openMain: @escaping () -> Void) {
        self.controller = controller
        self.openMain = openMain
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(buttonClicked(_:))
        buildMenu()
        update(state: .idle, elapsed: 0)
    }

    private func buildMenu() {
        let start = ClosureMenuItem(title: "Start Recording", keyEquivalent: "r") { [weak self] in
            self?.controller.toggleRecording()
        }
        start.keyEquivalentModifierMask = [.command, .shift]
        idleMenu.addItem(start)
        idleMenu.addItem(ClosureMenuItem(title: "Open ScreenyPro") { [weak self] in self?.openMain() })
        idleMenu.addItem(ClosureMenuItem(title: "Open Recordings Folder") { RecorderController.openRecordingsFolder() })
        idleMenu.addItem(.separator())
        idleMenu.addItem(ClosureMenuItem(title: "Quit ScreenyPro", keyEquivalent: "q") { NSApp.terminate(nil) })
    }

    func update(state: RecorderController.State, elapsed: TimeInterval) {
        guard let button = item.button else { return }
        switch state {
        case .idle, .finished:
            item.menu = idleMenu
            button.image = Self.symbol("record.circle")
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            button.toolTip = "ScreenyPro"
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
