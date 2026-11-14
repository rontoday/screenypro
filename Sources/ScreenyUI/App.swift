import AppKit
import Carbon.HIToolbox
import Combine
import ScreenyCore
import SwiftUI

/// Entry point of the UI module. Never returns.
public func runScreenyProApp(dependencies: AppDependencies) -> Never {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate(dependencies: dependencies)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // `delegate` is weak in NSApplication; keep it alive for the life of the process.
        AppDelegate.retained = delegate
        app.run()
    }
    exit(0)
}

// MARK: - Main window

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let controller: RecorderController

    init(controller: RecorderController) {
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("screenypro.main")
        window.title = "ScreenyPro"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.nsWindowBackground
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        let host = NSHostingView(rootView: MainView(controller: controller))
        // Only the minimum size (860×560 window, set on `MainView`) comes from SwiftUI.
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.setContentSize(NSSize(width: 980, height: 640))
        window.center()
        window.setFrameAutosaveName("ScreenyPro.MainWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        controller.mainWindowDidBecomeKey()
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var retained: AppDelegate?

    private let dependencies: AppDependencies
    private var controller: RecorderController!
    private var mainWindow: MainWindowController!
    private var hud: HUDController!
    private var countdown: CountdownController!
    private var statusItem: StatusItemController!
    private var cancellables: Set<AnyCancellable> = []
    private var previousState: RecorderController.State = .idle
    private var mainWasVisibleBeforeCountdown = true

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = buildMainMenu()

        controller = RecorderController(dependencies: dependencies)
        mainWindow = MainWindowController(controller: controller)
        hud = HUDController(controller: controller)
        countdown = CountdownController(controller: controller)
        statusItem = StatusItemController(controller: controller) { [weak self] in self?.mainWindow.show() }

        controller.onAlert = { [weak self] info in self?.presentAlert(info) }
        controller.clock.onTick = { [weak self] elapsed in
            guard let self else { return }
            self.statusItem.update(state: self.controller.state, elapsed: elapsed)
        }
        controller.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.stateDidChange(to: state) }
            .store(in: &cancellables)

        registerHotKeys()
        mainWindow.show()
        controller.launch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controller.state.allowsOutputChanges { mainWindow.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.terminationReply()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
        controller.shutdown()
    }

    // MARK: State → windows

    /// Called on `willSet` of `state`; `state` is the new value.
    private func stateDidChange(to state: RecorderController.State) {
        let previous = previousState
        previousState = state

        if state.isCountdown && !previous.isCountdown {
            mainWasVisibleBeforeCountdown = mainWindow.isVisible
            mainWindow.hide()
            countdown.show(onDisplay: controller.recordedDisplayID)
            HotKeyCenter.shared.register(.cancelCountdown, keyCode: kVK_Escape, modifiers: 0) { [weak self] in
                self?.controller.cancelCountdown()
            }
        } else if !state.isCountdown && previous.isCountdown {
            countdown.hide()
            HotKeyCenter.shared.unregister(.cancelCountdown)
        }

        switch state {
        case .recording, .paused, .finishing:
            hud.show()
        case .idle:
            hud.hide()
            if previous.isCountdown {
                if mainWasVisibleBeforeCountdown { mainWindow.show() }
            } else if previous == .finishing {
                mainWindow.show()
            }
        case .finished:
            hud.hide()
            mainWindow.show()
        case .countdown:
            break
        }
        statusItem.update(state: state, elapsed: controller.clock.elapsed)
    }

    private func presentAlert(_ info: RecorderController.AlertInfo) {
        let alert = NSAlert()
        alert.messageText = info.title
        alert.informativeText = info.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = mainWindow.window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate()
            alert.runModal()
        }
    }

    // MARK: Hotkeys

    private func registerHotKeys() {
        let modifiers = cmdKey | shiftKey
        HotKeyCenter.shared.register(.toggleRecording, keyCode: kVK_ANSI_R, modifiers: modifiers) { [weak self] in
            self?.controller.toggleRecording()
        }
        HotKeyCenter.shared.register(.togglePause, keyCode: kVK_ANSI_P, modifiers: modifiers) { [weak self] in
            self?.controller.togglePause()
        }
    }

    // MARK: Menu actions (also reachable through the responder chain)

    @objc func toggleRecording(_ sender: Any?) {
        controller.toggleRecording()
    }

    @objc func togglePause(_ sender: Any?) {
        controller.togglePause()
    }

    @objc func showMainWindow(_ sender: Any?) {
        mainWindow.show()
    }

    @objc func openRecordingsFolder(_ sender: Any?) {
        RecorderController.openRecordingsFolder()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleRecording(_:)):
            switch controller.state {
            case .idle, .finished: menuItem.title = "Start Recording"
            case .countdown: menuItem.title = "Cancel Countdown"
            case .recording, .paused: menuItem.title = "Stop Recording"
            case .finishing: menuItem.title = "Saving…"
            }
            return controller.state != .finishing
        case #selector(togglePause(_:)):
            menuItem.title = controller.state == .paused ? "Resume" : "Pause"
            return controller.state.isCapturingSession
        default:
            return true
        }
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "ScreenyPro")
        appMenu.addItem(withTitle: "About ScreenyPro", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ScreenyPro", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ScreenyPro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let recordItem = NSMenuItem()
        let recordMenu = NSMenu(title: "Recording")
        let toggle = recordMenu.addItem(withTitle: "Start Recording", action: #selector(toggleRecording(_:)), keyEquivalent: "r")
        toggle.keyEquivalentModifierMask = [.command, .shift]
        toggle.target = self
        let pause = recordMenu.addItem(withTitle: "Pause", action: #selector(togglePause(_:)), keyEquivalent: "p")
        pause.keyEquivalentModifierMask = [.command, .shift]
        pause.target = self
        recordMenu.addItem(.separator())
        let folder = recordMenu.addItem(withTitle: "Open Recordings Folder", action: #selector(openRecordingsFolder(_:)), keyEquivalent: "")
        folder.target = self
        recordItem.submenu = recordMenu
        main.addItem(recordItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        let show = windowMenu.addItem(withTitle: "ScreenyPro", action: #selector(showMainWindow(_:)), keyEquivalent: "0")
        show.target = self
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }
}
