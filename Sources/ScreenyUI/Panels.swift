import AppKit
import Carbon.HIToolbox
import ScreenyCore
import SwiftUI

/// Hosting view that reacts to the first click even when the app is not active (HUD in front of other apps).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Background view that drags its window. Buttons on top keep their own clicks.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Recording HUD

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDController {
    static let size = NSSize(width: 300, height: 48)
    let panel: HUDPanel
    private var userOrigin: NSPoint?

    init(controller: RecorderController) {
        panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("screenypro.hud")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = FirstMouseHostingView(rootView: HUDView(controller: controller, clock: controller.clock))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.sizingOptions = []
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.userOrigin = self.panel.frame.origin
            }
        }
    }

    func show() {
        guard !panel.isVisible else { return }
        let origin = validUserOrigin() ?? defaultOrigin()
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Bottom center of the main screen (the one with the menu bar).
    private func defaultOrigin() -> NSPoint {
        let screen = NSScreen.screens.first ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 32)
    }

    private func validUserOrigin() -> NSPoint? {
        guard let origin = userOrigin else { return nil }
        let rect = NSRect(origin: origin, size: Self.size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(rect) } ? origin : nil
    }
}

struct HUDView: View {
    @ObservedObject var controller: RecorderController
    @ObservedObject var clock: ElapsedClock
    @State private var confirmingDiscard = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color(hex: 0x1E2026, opacity: 0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .allowsHitTesting(false)
            WindowDragArea()
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            content
                .padding(.horizontal, 8)
        }
        .frame(width: HUDController.size.width, height: HUDController.size.height)
        .environment(\.colorScheme, .dark)
        .onChange(of: controller.state) { _, state in
            if !state.isCapturingSession { confirmingDiscard = false }
        }
        .animation(Theme.stateAnimation, value: confirmingDiscard)
        .animation(Theme.stateAnimation, value: controller.state)
    }

    @ViewBuilder
    private var content: some View {
        if controller.state == .finishing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(controller.isDiscarding ? "Discarding…" : "Saving recording…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
            }
            .allowsHitTesting(false)
        } else if confirmingDiscard {
            HStack(spacing: 8) {
                Text("Discard recording?")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Theme.primaryText)
                    .padding(.leading, 6)
                    .allowsHitTesting(false)
                Spacer(minLength: 4)
                Button("Keep") { confirmingDiscard = false }
                    .buttonStyle(ToolButtonStyle(kind: .secondary, height: 28))
                    .fixedSize()
                Button("Discard") {
                    confirmingDiscard = false
                    controller.discardRecording()
                }
                .buttonStyle(ToolButtonStyle(kind: .record, height: 28))
                .fixedSize()
            }
        } else {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(controller.state == .paused ? Theme.secondaryText : Theme.record)
                        .frame(width: 9, height: 9)
                    Text(Format.elapsed(clock.elapsed))
                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                        .foregroundStyle(controller.state == .paused ? Theme.secondaryText : Theme.primaryText)
                    if controller.state == .paused {
                        Text("PAUSED")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.leading, 8)
                .allowsHitTesting(false)
                Spacer(minLength: 8)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 22)
                    .padding(.trailing, 6)
                HStack(spacing: 2) {
                    Button(action: controller.togglePause) {
                        Image(systemName: controller.state == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(IconButtonStyle(size: 32, tint: Theme.primaryText))
                    .help(controller.state == .paused ? "Resume (⌘⇧P)" : "Pause (⌘⇧P)")

                    Button(action: { controller.stopRecording() }) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.record)
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(IconButtonStyle(size: 32))
                    .help("Stop and save (⌘⇧R)")

                    Button(action: { confirmingDiscard = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(IconButtonStyle(size: 32))
                    .help("Discard recording")
                }
            }
        }
    }
}

// MARK: - Countdown overlay

final class CountdownWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CountdownController {
    static let size = NSSize(width: 240, height: 240)
    let window: CountdownWindow

    init(controller: RecorderController) {
        window = CountdownWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("screenypro.countdown")
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: CountdownView(controller: controller))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.sizingOptions = []
        window.contentView = host
    }

    func show(onDisplay displayID: UInt32?) {
        let screen = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: frame.midX - Self.size.width / 2, y: frame.midY - Self.size.height / 2)
        window.setFrame(NSRect(origin: origin, size: Self.size), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}

struct CountdownView: View {
    @ObservedObject var controller: RecorderController

    private var number: Int {
        if case .countdown(let n) = controller.state { return n }
        return 1
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color(hex: 0x16171B, opacity: 0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
            VStack(spacing: 6) {
                Text("\(number)")
                    .font(.system(size: 120, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
                    .id(number)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                HStack(spacing: 6) {
                    Keycap(text: "esc")
                    Text("to cancel")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.top, 8)
        }
        .padding(8)
        .frame(width: CountdownController.size.width, height: CountdownController.size.height)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.18), value: number)
    }
}

extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
