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

    /// On screen and not in the Dock.
    var isShown: Bool { (window?.isVisible ?? false) && !(window?.isMiniaturized ?? false) }

    /// Called when the window is shown, hidden, minimized or restored.
    var onVisibilityChange: (() -> Void)?

    func show() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        onVisibilityChange?()
    }

    func hide() {
        window?.orderOut(nil)
        onVisibilityChange?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        controller.mainWindowDidBecomeKey()
        onVisibilityChange?()
    }

    func windowDidMiniaturize(_ notification: Notification) { onVisibilityChange?() }
    func windowDidDeminiaturize(_ notification: Notification) { onVisibilityChange?() }
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.onVisibilityChange?() }
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
    private let areaPicker = AreaPickerController()
    private let areaOutline = AreaOutlineController()
    private var outlineUpdateQueued = false
    /// The picker hid a visible main window; it comes back when the picker or a countdown started from it ends.
    private var mainHiddenForPicker = false
    private var cancellables: Set<AnyCancellable> = []
    private var previousState: RecorderController.State = .idle
    private var mainWasVisibleBeforeCountdown = true
    /// The user confirmed "Quit anyway" during an upload.
    private var quitConfirmed = false
    private var isConfirmingQuit = false

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
        statusItem.onCloudSettings = { [weak self] in self?.showCloudSettings(nil) }
        controller.sharing.isMainWindowShown = { [weak self] in self?.mainWindow.isShown ?? false }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.sharing.refreshConfiguration() }
        }

        controller.onAlert = { [weak self] info in self?.presentAlert(info) }
        controller.onSelectArea = { [weak self] in self?.beginAreaSelection() }
        mainWindow.onVisibilityChange = { [weak self] in self?.updateOutline() }
        // Any published change (settings, displays, camera state) may move the area: coalesce to one update.
        controller.objectWillChange
            .sink { [weak self] _ in self?.queueOutlineUpdate() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.areaPicker.isActive { self.areaPicker.cancel() }
                self.controller.screensDidChange()
                self.updateOutline()
            }
        }
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
        if controller.sharing.isBusy && !quitConfirmed {
            if !isConfirmingQuit { confirmQuitDuringUpload() }
            return .terminateLater
        }
        return controller.terminationReply()
    }

    /// "An upload is in progress. Quit anyway?" — a sheet on the main window when it is on screen.
    private func confirmQuitDuringUpload() {
        isConfirmingQuit = true
        let alert = NSAlert()
        alert.messageText = "An upload is in progress. Quit anyway?"
        let waiting = controller.sharing.queue.count
        alert.informativeText = "The upload will be cancelled" + (waiting > 0 ? " and \(waiting) waiting upload\(waiting == 1 ? "" : "s") will not start" : "") + ". Nothing stays on the server."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue Upload")
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.hasDestructiveAction = true
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.isConfirmingQuit = false
            guard response == .alertSecondButtonReturn else {
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            self.quitConfirmed = true
            Task { @MainActor in
                await self.controller.sharing.cancelAllForQuit()
                switch self.controller.terminationReply() {
                case .terminateNow: NSApp.reply(toApplicationShouldTerminate: true)
                case .terminateCancel:
                    self.quitConfirmed = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                case .terminateLater: break // the recorder replies when the file is saved
                @unknown default: NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        if let window = mainWindow.window, mainWindow.isShown, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            NSApp.activate()
            handle(alert.runModal())
        }
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
            let hiddenForPicker = areaPicker.isActive && mainHiddenForPicker
            if areaPicker.isActive { areaPicker.cancel() }
            mainWasVisibleBeforeCountdown = mainWindow.isVisible || hiddenForPicker
            mainWindow.hide()
            if let area = controller.activeAreaOnScreen() {
                countdown.show(centeredIn: area.rect, on: area.screen)
            } else {
                countdown.show(onDisplay: controller.recordedDisplayID)
            }
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
        queueOutlineUpdate()
    }

    // MARK: Area picker and outline

    private func beginAreaSelection() {
        guard controller.canSelectArea, let display = controller.selectedDisplay else { return }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display.id }) else {
            controller.banner = .init(kind: .error, message: "This display is not available for area selection.")
            return
        }
        let mainWasVisible = mainWindow.isShown
        // Hide the main window, so the whole display can be seen and selected.
        mainHiddenForPicker = mainWasVisible
        mainWindow.hide()
        var lockLabel: String?
        if let aspect = controller.areaAspectLock, let slot = controller.portraitSlots?.screen {
            lockLabel = String(format: "Locked to the 9:16 screen slot · %d × %d px · %.2f : 1",
                               Int(slot.width), Int(slot.height), Double(aspect))
        }
        areaPicker.begin(on: screen, initial: controller.pickerInitialArea, aspect: controller.areaAspectLock,
                         lockLabel: lockLabel) { [weak self] rect in
            guard let self else { return }
            self.mainHiddenForPicker = false
            if let rect { self.controller.applyPickedArea(rect, displayID: display.id) }
            if mainWasVisible && self.controller.state.allowsOutputChanges { self.mainWindow.show() }
            self.updateOutline()
        }
        updateOutline()
    }

    private func queueOutlineUpdate() {
        guard !outlineUpdateQueued else { return }
        outlineUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.outlineUpdateQueued = false
            self.updateOutline()
        }
    }

    /// The outline shows around the active area while idle with the main window on screen, and while recording.
    private func updateOutline() {
        let visibleForState: Bool
        switch controller.state {
        case .idle, .finished: visibleForState = mainWindow.isShown
        case .countdown, .recording, .paused: visibleForState = true
        case .finishing: visibleForState = false
        }
        guard visibleForState, !areaPicker.isActive, let area = controller.activeAreaOnScreen() else {
            areaOutline.hide()
            return
        }
        areaOutline.show(area: area.rect, on: area.screen)
    }

    @objc func selectArea(_ sender: Any?) {
        controller.selectArea()
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

    @objc func showCloudSettings(_ sender: Any?) {
        guard controller.state.allowsOutputChanges else { return }
        mainWindow.show()
        controller.sharing.isRecordingsShown = false
        controller.sharing.showSettings()
    }

    @objc func showRecentRecordings(_ sender: Any?) {
        guard controller.state.allowsOutputChanges else { return }
        mainWindow.show()
        // A popover needs its window on screen: open it on the next turn of the run loop.
        DispatchQueue.main.async { [weak self] in self?.controller.sharing.isRecordingsShown = true }
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
        case #selector(selectArea(_:)):
            return controller.canSelectArea && !areaPicker.isActive
        case #selector(showCloudSettings(_:)), #selector(showRecentRecordings(_:)):
            return controller.state.allowsOutputChanges
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
        let cloud = appMenu.addItem(withTitle: "Cloud Settings…", action: #selector(showCloudSettings(_:)), keyEquivalent: "")
        cloud.target = self
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
        let area = recordMenu.addItem(withTitle: "Select Recording Area…", action: #selector(selectArea(_:)), keyEquivalent: "")
        area.target = self
        recordMenu.addItem(.separator())
        let recent = recordMenu.addItem(withTitle: "Recent Recordings…", action: #selector(showRecentRecordings(_:)), keyEquivalent: "l")
        recent.keyEquivalentModifierMask = [.command]
        recent.target = self
        let folder = recordMenu.addItem(withTitle: "Open Recordings Folder", action: #selector(openRecordingsFolder(_:)), keyEquivalent: "")
        folder.target = self
        recordItem.submenu = recordMenu
        main.addItem(recordItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // Undo/Cut/Paste: the cloud settings and the title fields need them (pasting the secret, for one).
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
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
