import AppKit
import Carbon.HIToolbox
import ScreenyCore
import SwiftUI

extension RecorderController {
    /// The active capture area in AppKit global coordinates and its screen (outline, countdown).
    /// `nil` for window sources and full-display capture.
    func activeAreaOnScreen() -> (rect: CGRect, screen: NSScreen)? {
        guard let display = selectedDisplay, let area = effectiveArea,
              let screen = NSScreen.screens.first(where: { $0.displayID == display.id })
        else { return nil }
        let clamped = AreaGeometry.clamp(area, to: screen.frame.size)
        return (AreaGeometry.appKitRect(fromDisplayRect: clamped, screenFrame: screen.frame), screen)
    }
}

// MARK: - Area picker

final class AreaPickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Full-display overlay to draw, move and resize the capture area.
/// Enter or "Done" confirms, Esc or "Cancel" cancels.
@MainActor
final class AreaPickerController {
    private var window: AreaPickerWindow?
    private var completion: ((CGRect?) -> Void)?

    var isActive: Bool { window != nil }

    /// - Parameters:
    ///   - initial: display rect (points, top-left origin) to start with, or `nil` to start empty.
    ///   - aspect: locked width / height, or `nil` for a free area.
    ///   - completion: the confirmed display rect, or `nil` when cancelled.
    func begin(on screen: NSScreen, initial: CGRect?, aspect: CGFloat?, lockLabel: String?,
               completion: @escaping (CGRect?) -> Void) {
        finish(with: nil)
        self.completion = completion
        let frame = screen.frame
        let window = AreaPickerWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("screenypro.areapicker")
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.acceptsMouseMovedEvents = true

        let view = AreaPickerView(frame: NSRect(origin: .zero, size: frame.size))
        view.aspect = aspect
        view.lockLabel = lockLabel
        if let initial {
            let bounds = CGRect(origin: .zero, size: frame.size)
            view.selection = AreaGeometry.ensuringMinimum(AreaGeometry.clamp(initial, to: frame.size), aspect: aspect, bounds: bounds)
        }
        view.onDone = { [weak self] rect in self?.finish(with: rect) }
        view.onCancel = { [weak self] in self?.finish(with: nil) }
        window.contentView = view
        window.setFrame(frame, display: true)
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.refreshCursor()
    }

    func cancel() {
        finish(with: nil)
    }

    private func finish(with rect: CGRect?) {
        guard let window else { return }
        self.window = nil
        window.orderOut(nil)
        let completion = self.completion
        self.completion = nil
        completion?(rect)
    }
}

/// Flipped, so view coordinates are display points with a top-left origin.
final class AreaPickerView: NSView {
    var selection: CGRect? { didSet { selectionDidChange() } }
    var aspect: CGFloat?
    var lockLabel: String?
    var onDone: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private enum Drag {
        case drawing(start: CGPoint, previous: CGRect?)
        case moving(start: CGPoint, original: CGRect)
        case resizing(AreaGeometry.Handle)
    }

    private var drag: Drag?
    private let toolbarModel = AreaToolbarModel()
    private var toolbar: NSHostingView<AreaToolbar>!
    private let handleRadius: CGFloat = 5
    private let handleHitRadius: CGFloat = 11

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let toolbar = FirstMouseHostingView(rootView: AreaToolbar(
            model: toolbarModel,
            onCancel: { [weak self] in self?.onCancel?() },
            onDone: { [weak self] in self?.confirm() }
        ))
        toolbar.sizingOptions = [.intrinsicContentSize]
        addSubview(toolbar)
        self.toolbar = toolbar
        selectionDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        placeToolbar()
    }

    private func placeToolbar() {
        guard let toolbar else { return }
        let size = toolbar.fittingSize
        // Bottom center, above the Dock area.
        let visibleBottomInset: CGFloat = {
            guard let screen = window?.screen else { return 0 }
            return screen.visibleFrame.minY - screen.frame.minY
        }()
        let y = bounds.height - visibleBottomInset - 28 - size.height
        toolbar.frame = NSRect(x: (bounds.width - size.width) / 2, y: max(8, y), width: size.width, height: size.height).integral
    }

    private func selectionDidChange() {
        toolbarModel.hasSelection = (selection.map { $0.width >= AreaGeometry.minimumSide && $0.height >= AreaGeometry.minimumSide }) ?? false
        toolbarModel.sizeText = selection.map { "\(Int($0.width.rounded())) × \(Int($0.height.rounded())) pt" }
        toolbarModel.lockLabel = lockLabel
        needsDisplay = true
        if let toolbar { toolbar.invalidateIntrinsicContentSize(); needsLayout = true }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        let dim = NSBezierPath(rect: bounds)
        if let selection {
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()

        guard let selection, selection.width > 0, selection.height > 0 else {
            drawHint()
            return
        }

        // Thirds while dragging, to help framing.
        if drag != nil {
            NSColor.white.withAlphaComponent(0.22).setStroke()
            let guides = NSBezierPath()
            for i in 1...2 {
                let x = selection.minX + selection.width * CGFloat(i) / 3
                let y = selection.minY + selection.height * CGFloat(i) / 3
                guides.move(to: NSPoint(x: x, y: selection.minY)); guides.line(to: NSPoint(x: x, y: selection.maxY))
                guides.move(to: NSPoint(x: selection.minX, y: y)); guides.line(to: NSPoint(x: selection.maxX, y: y))
            }
            guides.lineWidth = 1
            guides.stroke()
        }

        // Border: dark hairline outside for contrast on light content, accent line on top.
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let outer = NSBezierPath(rect: selection.insetBy(dx: -1.5, dy: -1.5))
        outer.lineWidth = 1
        outer.stroke()
        NSColor(hex: 0x8E5CF6).setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.75, dy: -0.75))
        border.lineWidth = 1.5
        border.stroke()

        for handle in AreaGeometry.Handle.allCases {
            // Keep handles fully visible when the area touches a display edge.
            var p = handle.point(in: selection)
            p.x = min(max(p.x, handleRadius + 1), bounds.width - handleRadius - 1)
            p.y = min(max(p.y, handleRadius + 1), bounds.height - handleRadius - 1)
            let r = NSRect(x: p.x - handleRadius, y: p.y - handleRadius, width: handleRadius * 2, height: handleRadius * 2)
            let dot = NSBezierPath(ovalIn: r)
            NSColor.white.setFill()
            dot.fill()
            NSColor(hex: 0x8E5CF6).setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }

        drawSizeLabel(for: selection)
    }

    private func drawSizeLabel(for selection: CGRect) {
        let text = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let pill = NSSize(width: ceil(textSize.width) + 16, height: 22)
        var origin = NSPoint(x: selection.minX, y: selection.minY - pill.height - 8)
        if origin.y < 4 { origin.y = selection.minY + 10; origin.x = selection.minX + 10 }
        origin.x = min(max(origin.x, 4), bounds.width - pill.width - 4)
        let rect = NSRect(origin: origin, size: pill)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor(hex: 0x16171B, alpha: 0.88).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 1
        path.stroke()
        string.draw(at: NSPoint(x: rect.minX + 8, y: rect.midY - textSize.height / 2))
    }

    private func drawHint() {
        let title = NSAttributedString(string: "Drag to select the area to record", attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ])
        let size = title.size()
        title.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    // MARK: Mouse

    private func handle(at point: CGPoint) -> AreaGeometry.Handle? {
        guard let selection else { return nil }
        // Corners first, they overlap the edges.
        let ordered = AreaGeometry.Handle.allCases.sorted { $0.isCorner && !$1.isCorner }
        for handle in ordered {
            var p = handle.point(in: selection)
            p.x = min(max(p.x, handleRadius + 1), bounds.width - handleRadius - 1)
            p.y = min(max(p.y, handleRadius + 1), bounds.height - handleRadius - 1)
            if hypot(p.x - point.x, p.y - point.y) <= handleHitRadius { return handle }
        }
        // Edges along their full length.
        let slop: CGFloat = 5
        if abs(point.x - selection.minX) <= slop, point.y > selection.minY, point.y < selection.maxY { return .left }
        if abs(point.x - selection.maxX) <= slop, point.y > selection.minY, point.y < selection.maxY { return .right }
        if abs(point.y - selection.minY) <= slop, point.x > selection.minX, point.x < selection.maxX { return .top }
        if abs(point.y - selection.maxY) <= slop, point.x > selection.minX, point.x < selection.maxX { return .bottom }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let selection, selection.contains(point) {
            confirm()
            return
        }
        if let handle = handle(at: point) {
            drag = .resizing(handle)
        } else if let selection, selection.contains(point) {
            drag = .moving(start: point, original: selection)
            NSCursor.closedHand.set()
        } else {
            drag = .drawing(start: point, previous: selection)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case let .drawing(start, _):
            selection = AreaGeometry.drawnRect(from: start, to: point, aspect: aspect, bounds: bounds)
        case let .moving(start, original):
            selection = AreaGeometry.moved(original, by: CGSize(width: point.x - start.x, height: point.y - start.y), in: bounds)
        case let .resizing(handle):
            if let current = selection {
                selection = AreaGeometry.resized(current, handle: handle, to: point, aspect: aspect, bounds: bounds)
            }
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case let .drawing(_, previous) = drag {
            if let drawn = selection, drawn.width >= 8, drawn.height >= 8 {
                selection = AreaGeometry.ensuringMinimum(drawn, aspect: aspect, bounds: bounds)
            } else {
                // A click, not a drag: keep what was there.
                selection = previous
            }
        }
        drag = nil
        needsDisplay = true
        refreshCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        refreshCursor(at: convert(event.locationInWindow, from: nil))
    }

    func refreshCursor(at point: CGPoint? = nil) {
        guard let window else { return }
        let p = point ?? convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if toolbar.frame.contains(p) {
            NSCursor.arrow.set()
        } else if let handle = handle(at: p) {
            Self.cursor(for: handle).set()
        } else if let selection, selection.contains(p) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private static func cursor(for handle: AreaGeometry.Handle) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch handle {
        case .topLeft: position = .topLeft
        case .top: position = .top
        case .topRight: position = .topRight
        case .right: position = .right
        case .bottomRight: position = .bottomRight
        case .bottom: position = .bottom
        case .bottomLeft: position = .bottomLeft
        case .left: position = .left
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            onCancel?()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            confirm()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    private func confirm() {
        guard let selection, selection.width >= AreaGeometry.minimumSide, selection.height >= AreaGeometry.minimumSide else {
            NSSound.beep()
            return
        }
        onDone?(selection)
    }
}

// MARK: - Picker toolbar

final class AreaToolbarModel: ObservableObject {
    @Published var hasSelection = false
    @Published var sizeText: String?
    @Published var lockLabel: String?
}

struct AreaToolbar: View {
    @ObservedObject var model: AreaToolbarModel
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: model.lockLabel == nil ? "rectangle.dashed" : "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.lockLabel == nil ? Theme.secondaryText : Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.hasSelection ? "Drag to move · handles resize" : "Drag to select an area")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                    Text(model.lockLabel ?? "Free aspect ratio")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .fixedSize()
            }
            .padding(.leading, 4)

            Rectangle().fill(Theme.hairline).frame(width: 1, height: 24)

            HStack(spacing: 6) {
                Keycap(text: "esc")
                Button("Cancel", action: onCancel)
                    .buttonStyle(ToolButtonStyle(kind: .secondary, height: 28))
                    .fixedSize()
            }
            HStack(spacing: 6) {
                Button(action: onDone) {
                    HStack(spacing: 6) {
                        Text("Done")
                        Text("⏎").font(.system(size: 11, weight: .medium)).opacity(0.75)
                    }
                }
                .buttonStyle(ToolButtonStyle(kind: .primary, height: 28))
                .fixedSize()
                .disabled(!model.hasSelection)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color(hex: 0x1E2026, opacity: 0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .environment(\.colorScheme, .dark)
        .padding(16) // room for the shadow inside the hosting view
    }
}

// MARK: - Area outline

final class AreaOutlineWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A thin click-through frame just outside the capture area, so the user sees what is recorded.
/// Own windows are excluded from display capture, so it never appears in the video.
@MainActor
final class AreaOutlineController {
    static let lineWidth: CGFloat = 2
    let window: AreaOutlineWindow
    private var shownFrame: CGRect?

    init() {
        window = AreaOutlineWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("screenypro.outline")
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = AreaOutlineView()
    }

    /// The window frame for an area: the ring just outside it. Where that ring would leave the display
    /// (area touching a display edge), the line moves just inside the area so it stays visible.
    static func outlineFrame(area: CGRect, screenFrame: CGRect) -> CGRect {
        area.insetBy(dx: -lineWidth, dy: -lineWidth).intersection(screenFrame)
    }

    /// `area` in AppKit global coordinates on `screen`.
    func show(area: CGRect, on screen: NSScreen) {
        let frame = Self.outlineFrame(area: area, screenFrame: screen.frame)
        guard !frame.isNull, frame.width > 2 * Self.lineWidth, frame.height > 2 * Self.lineWidth else {
            hide()
            return
        }
        if shownFrame != frame {
            window.setFrame(frame, display: true)
            shownFrame = frame
        }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        guard window.isVisible else { return }
        window.orderOut(nil)
    }
}

private final class AreaOutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let width = AreaOutlineController.lineWidth
        NSColor(hex: 0x8E5CF6, alpha: 0.6).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: width / 2, dy: width / 2))
        path.lineWidth = width
        path.stroke()
    }
}
