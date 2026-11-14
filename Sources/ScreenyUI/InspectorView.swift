import AppKit
import ScreenyCore
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @ObservedObject var controller: RecorderController

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                FormatSection(controller: controller)
                Hairline()
                SourceSection(controller: controller)
                Hairline()
                CameraSection(controller: controller)
                Hairline()
                AudioSection(controller: controller)
                Hairline()
                LookSection(controller: controller)
                Hairline()
                OutputSection(controller: controller)
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.automatic)
        .disabled(controller.screenPermission != .granted)
        .opacity(controller.screenPermission == .granted ? 1 : 0.5)
    }
}

// MARK: - Format

private struct FormatSection: View {
    @ObservedObject var controller: RecorderController

    var body: some View {
        InspectorSection("Format") {
            HStack(spacing: 10) {
                FormatTile(format: .landscape, title: "16:9", caption: "Landscape", selection: $controller.settings.output.format)
                FormatTile(format: .portrait, title: "9:16", caption: "Reels", selection: $controller.settings.output.format)
            }
            .padding(.horizontal, 2)
        }
        .disabled(!controller.state.allowsOutputChanges)
    }
}

private struct FormatTile: View {
    let format: CanvasFormat
    let title: String
    let caption: String
    @Binding var selection: CanvasFormat
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    private var selected: Bool { selection == format }

    var body: some View {
        Button {
            withAnimation(Theme.stateAnimation) { selection = format }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(selected ? Theme.accent.opacity(0.28) : Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(selected ? Theme.accent : Color.white.opacity(0.45), lineWidth: 1.5)
                }
                .frame(width: format == .landscape ? 22 : 13, height: format == .landscape ? 13 : 22)
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.primaryText)
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.09) : (hovered && isEnabled ? Theme.fieldFillHover : Theme.fieldFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Theme.fieldBorder, lineWidth: 1)
            )
            .selectionRing(selected, cornerRadius: Theme.controlRadius)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .opacity(isEnabled ? 1 : 0.45)
        .help(format == .landscape ? "16:9 canvas for screencasts" : "9:16 canvas for Reels, Shorts and TikTok: screen on top, camera below")
    }
}

// MARK: - Source

private struct SourceSection: View {
    @ObservedObject var controller: RecorderController

    var body: some View {
        InspectorSection("Source", accessory: {
            Button(action: controller.reloadSources) {
                if controller.isRefreshingContent {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .help("Refresh displays and windows")
        }) {
            SegmentedPicker(
                options: [
                    .init(value: SourceKind.display, title: "Display", systemImage: "display"),
                    .init(value: SourceKind.window, title: "Window", systemImage: "macwindow"),
                ],
                selection: Binding(
                    get: { controller.settings.sourceKind },
                    set: { controller.selectSourceKind($0) }
                )
            )
            sourceList
            if controller.settings.sourceKind == .display && controller.selectedDisplay != nil {
                AreaControls(controller: controller)
                    .padding(.top, 2)
            }
        }
        .disabled(!controller.state.allowsOutputChanges)
    }

    @ViewBuilder
    private var sourceList: some View {
        let rows = self.rows
        if rows.isEmpty {
            Text(controller.settings.sourceKind == .display ? "No displays found." : "No windows found. Open an app window, then press Refresh.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else if rows.count <= 4 {
            VStack(spacing: 4) { ForEach(rows) { row in rowView(row) } }
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 4) { ForEach(rows) { row in rowView(row) } }
                    .padding(.vertical, 4)
                    .padding(.trailing, 2)
            }
            .frame(height: 4 * 56 + 28)
        }
    }

    private struct Row: Identifiable {
        let id: CaptureSource
        let title: String
        let subtitle: String
        let symbol: String
        let action: () -> Void
    }

    private var rows: [Row] {
        if controller.settings.sourceKind == .display {
            let main = CGMainDisplayID()
            return controller.content.displays.map { display in
                let w = Int(display.frame.width * display.scale)
                let h = Int(display.frame.height * display.scale)
                return Row(
                    id: .display(display.id),
                    title: display.name,
                    subtitle: "\(w) × \(h)" + (display.id == main ? " · Main" : ""),
                    symbol: "display",
                    action: { controller.selectDisplay(display.id) }
                )
            }
        }
        return controller.content.windows.map { window in
            Row(
                id: .window(window.id),
                title: window.appName,
                subtitle: window.title,
                symbol: "macwindow",
                action: { controller.selectWindow(window) }
            )
        }
    }

    private func rowView(_ row: Row) -> some View {
        let selected = controller.currentSource == row.id
        return SourceRow(
            title: row.title,
            subtitle: row.subtitle,
            symbol: row.symbol,
            thumbnail: controller.thumbnails[row.id],
            selected: selected,
            action: row.action
        )
    }
}

/// "Area: Full display / Custom area" and "Select area…" for a display source.
private struct AreaControls: View {
    @ObservedObject var controller: RecorderController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledRow(title: "Area") {
                SegmentedPicker(
                    options: [
                        .init(value: false, title: controller.isPortrait ? "Centered" : "Full display"),
                        .init(value: true, title: "Custom area"),
                    ],
                    selection: Binding(
                        get: { controller.usesCustomArea },
                        set: { controller.setUsesCustomArea($0) }
                    )
                )
                .frame(width: 184)
            }
            Button(action: controller.selectArea) {
                Label("Select Area…", systemImage: "rectangle.dashed")
            }
            .buttonStyle(ToolButtonStyle(kind: .secondary, fullWidth: true))
            .disabled(!controller.canSelectArea)
            if let detail {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: controller.usesAutomaticArea ? "info.circle" : "rectangle.dashed")
                        .font(.system(size: 11))
                        .foregroundStyle(controller.usesAutomaticArea ? Theme.accent : Theme.secondaryText)
                        .padding(.top, 1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var detail: String? {
        guard let area = controller.effectiveArea else { return nil }
        let size = "\(Int(area.width.rounded())) × \(Int(area.height.rounded())) pt"
        if controller.usesAutomaticArea {
            return "9:16 records a centered \(size) area that fills the screen slot. Select an area to choose another part."
        }
        if controller.isPortrait {
            return "\(size), locked to the screen slot."
        }
        return "\(size) at \(Int(area.minX.rounded())), \(Int(area.minY.rounded()))"
    }
}

private struct SourceRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let thumbnail: NSImage?
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .selectionRing(selected, cornerRadius: 5)
                .padding(.leading, 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.07 : (hovered ? 0.04 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(subtitle.isEmpty ? title : "\(title) — \(subtitle)")
    }
}

// MARK: - Camera

private struct CameraSection: View {
    @ObservedObject var controller: RecorderController

    private var camera: Binding<CameraStyle> { $controller.settings.style.camera }

    var body: some View {
        InspectorSection("Camera", accessory: {
            SwitchToggle(isOn: camera.enabled)
        }) {
            VStack(alignment: .leading, spacing: 12) {
                if controller.cameraPermission == .denied {
                    PermissionNote(text: "Camera access is off.") {
                        controller.openSettings(for: .camera)
                    }
                }
                DropdownPicker(
                    options: controller.cameras.map { .init(id: $0.id, title: $0.name) },
                    selection: controller.effectiveCameraID ?? controller.cameras.first?.id ?? "",
                    systemImage: "video",
                    emptyTitle: "No camera found",
                    onSelect: { controller.settings.cameraDeviceID = $0 }
                )
                if controller.isPortrait {
                    // Portrait: the camera fills the bottom slot; only its height is a choice.
                    ValueSlider(title: "Camera height", value: camera.portraitShare, range: 0.25...0.6) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                } else {
                    LabeledRow(title: "Shape") {
                        SegmentedPicker(
                            options: [
                                .init(value: CameraShape.roundedRect, title: "Rounded"),
                                .init(value: CameraShape.circle, title: "Circle"),
                            ],
                            selection: camera.shape
                        )
                        .frame(width: 160)
                    }
                    LabeledRow(title: "Position") {
                        CornerPicker(selection: camera.corner, shape: camera.wrappedValue.shape)
                    }
                    ValueSlider(title: "Size", value: camera.size, range: 0.15...0.45) { "\(Int(($0 * 100).rounded()))%" }
                }
                ToggleRow(title: "Mirror", isOn: camera.mirrored)
            }
            .disabled(!camera.wrappedValue.enabled)
            .animation(Theme.stateAnimation, value: camera.wrappedValue.enabled)
        }
    }
}

private struct CornerPicker: View {
    @Binding var selection: CanvasCorner
    let shape: CameraShape

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                tile(.topLeft)
                tile(.topRight)
            }
            GridRow {
                tile(.bottomLeft)
                tile(.bottomRight)
            }
        }
        .padding(4)
    }

    private func tile(_ corner: CanvasCorner) -> some View {
        let selected = corner == selection
        let alignment: Alignment = {
            switch corner {
            case .topLeft: return .topLeading
            case .topRight: return .topTrailing
            case .bottomLeft: return .bottomLeading
            case .bottomRight: return .bottomTrailing
            }
        }()
        return Button {
            withAnimation(Theme.stateAnimation) { selection = corner }
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.10 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(alignment: alignment) {
                    RoundedRectangle(cornerRadius: shape == .circle ? 4 : 2, style: .continuous)
                        .fill(selected ? Theme.accent : Color.white.opacity(0.35))
                        .frame(width: shape == .circle ? 8 : 11, height: 8)
                        .padding(3)
                }
                .frame(width: 36, height: 22)
                .selectionRing(selected, cornerRadius: 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label(corner))
    }

    private func label(_ corner: CanvasCorner) -> String {
        switch corner {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

// MARK: - Audio

private struct AudioSection: View {
    @ObservedObject var controller: RecorderController
    private let noneID = "\u{0}none"

    var body: some View {
        InspectorSection("Audio") {
            VStack(alignment: .leading, spacing: 12) {
                if controller.microphonePermission == .denied && controller.settings.microphoneEnabled {
                    PermissionNote(text: "Microphone access is off.") {
                        controller.openSettings(for: .microphone)
                    }
                }
                DropdownPicker(
                    options: [.init(id: noneID, title: "No microphone")]
                        + controller.microphones.map { .init(id: $0.id, title: $0.name) },
                    selection: selection,
                    systemImage: "mic",
                    onSelect: select
                )
                ToggleRow(title: "System audio", isOn: $controller.settings.capturesSystemAudio)
            }
        }
        .disabled(!controller.state.allowsOutputChanges)
    }

    private var selection: String {
        guard controller.settings.microphoneEnabled else { return noneID }
        if let id = controller.settings.microphoneID, controller.microphones.contains(where: { $0.id == id }) { return id }
        return controller.microphones.first?.id ?? noneID
    }

    private func select(_ id: String) {
        var s = controller.settings
        if id == noneID {
            s.microphoneEnabled = false
        } else {
            s.microphoneEnabled = true
            s.microphoneID = id
        }
        controller.settings = s
    }
}

private struct PermissionNote: View {
    let text: String
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.meterYellow)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 4)
            Button("Open Settings", action: open)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
    }
}

// MARK: - Look

private struct LookSection: View {
    @ObservedObject var controller: RecorderController
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        InspectorSection("Look") {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(GradientPreset.all) { preset in
                        swatchButton(selected: controller.settings.style.background == .gradient(preset.id), help: preset.name) {
                            GradientSwatch(preset: preset)
                        } action: {
                            controller.settings.style.background = .gradient(preset.id)
                        }
                    }
                    swatchButton(selected: isSolid, help: "Solid color") {
                        ZStack {
                            Color(controller.settings.solidColor)
                            Image(systemName: "eyedropper")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.7))
                                .shadow(color: .black.opacity(0.4), radius: 1)
                        }
                    } action: {
                        chooseSolid()
                    }
                    swatchButton(selected: isImage, help: "Image…") {
                        ImageSwatch(url: controller.settings.backgroundImage)
                    } action: {
                        chooseImage()
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)

                ValueSlider(
                    title: "Padding",
                    value: $controller.settings.style.padding,
                    range: 0...0.15,
                    format: ValueSlider.percent(of: 0...0.15)
                )
                ValueSlider(
                    title: "Corner radius",
                    value: $controller.settings.style.cornerRadius,
                    range: 0...0.05,
                    format: ValueSlider.percent(of: 0...0.05)
                )
                .disabled(controller.settings.style.padding == 0)
                ValueSlider(
                    title: "Shadow",
                    value: $controller.settings.style.shadow,
                    range: 0...1,
                    format: ValueSlider.percent(of: 0...1)
                )
                .disabled(controller.settings.style.padding == 0)
            }
        }
    }

    private var isSolid: Bool {
        if case .solid = controller.settings.style.background { return true }
        return false
    }

    private var isImage: Bool {
        if case .image = controller.settings.style.background { return true }
        return false
    }

    private func swatchButton<Content: View>(
        selected: Bool,
        help: String,
        @ViewBuilder content: () -> Content,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            content()
                .aspectRatio(1.45, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .selectionRing(selected, cornerRadius: 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func chooseSolid() {
        let color = controller.settings.solidColor
        controller.settings.style.background = .solid(color)
        ColorPanelBridge.shared.show(color: color.nsColor) { [weak controller] newColor in
            guard let controller else { return }
            let rgba = RGBA(nsColor: newColor)
            var s = controller.settings
            s.solidColor = rgba
            s.style.background = .solid(rgba)
            controller.settings = s
        }
    }

    private func chooseImage() {
        if !isImage, let url = controller.settings.backgroundImage, FileManager.default.fileExists(atPath: url.path) {
            controller.settings.style.background = .image(url)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a background image"
        panel.prompt = "Use Image"
        panel.begin { [weak controller] response in
            guard response == .OK, let url = panel.url, let controller else { return }
            var s = controller.settings
            s.backgroundImage = url
            s.style.background = .image(url)
            controller.settings = s
        }
    }
}

struct GradientSwatch: View {
    let preset: GradientPreset

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: preset.colors.map { Color($0) },
                    startPoint: UnitPoint(x: preset.start.x, y: preset.start.y),
                    endPoint: UnitPoint(x: preset.end.x, y: preset.end.y)
                )
                ForEach(preset.glows.indices, id: \.self) { index in
                    let glow = preset.glows[index]
                    RadialGradient(
                        colors: [Color(glow.color).opacity(0.85), Color(glow.color).opacity(0)],
                        center: UnitPoint(x: glow.center.x, y: glow.center.y),
                        startRadius: 0,
                        endRadius: glow.radius * geo.size.width
                    )
                }
            }
        }
    }
}

private struct ImageSwatch: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color.white.opacity(0.05)
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

/// Routes `NSColorPanel` changes to a closure.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    func show(color: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.color = color
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}

// MARK: - Output

private struct OutputSection: View {
    @ObservedObject var controller: RecorderController

    var body: some View {
        InspectorSection("Output") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledRow(title: "Resolution") {
                    SegmentedPicker(
                        options: OutputResolution.allCases.map { .init(value: $0, title: $0.label) },
                        selection: $controller.settings.output.resolution
                    )
                    .frame(width: 168)
                }
                LabeledRow(title: "Frame rate") {
                    SegmentedPicker(
                        options: [.init(value: 30, title: "30 fps"), .init(value: 60, title: "60 fps")],
                        selection: $controller.settings.output.fps
                    )
                    .frame(width: 168)
                }
                LabeledRow(title: "Codec") {
                    SegmentedPicker(
                        options: VideoCodec.allCases.map { .init(value: $0, title: Format.codec($0)) },
                        selection: $controller.settings.output.codec
                    )
                    .frame(width: 168)
                }
                ToggleRow(title: "Show cursor", isOn: $controller.settings.showsCursor)
                Button {
                    RecorderController.openRecordingsFolder()
                } label: {
                    Label("Open Recordings Folder", systemImage: "folder")
                }
                .buttonStyle(ToolButtonStyle(kind: .secondary, fullWidth: true))
                .padding(.top, 4)
            }
        }
        .disabled(!controller.state.allowsOutputChanges)
    }
}
