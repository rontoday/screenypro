import AppKit
import SwiftUI

// Custom controls for the dark inspector. The stock macOS controls look washed out on #1E2026,
// so the common ones are drawn here with the design tokens from `Theme`.

// MARK: - Section

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.secondaryText)
    }
}

struct InspectorSection<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionHeader(title: title)
                Spacer(minLength: 8)
                accessory()
            }
            .frame(height: 20)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Rounded field background used by dropdowns and segmented controls.
struct FieldBackground: View {
    var hovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(hovered ? Theme.fieldFillHover : Theme.fieldFill)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Theme.fieldBorder, lineWidth: 1)
            )
    }
}

/// A row with a label on the left and a control on the right.
struct LabeledRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(Theme.controlFont)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: Theme.controlHeight)
    }
}

// MARK: - Switch

struct SwitchToggle: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            withAnimation(Theme.stateAnimation) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.accent : Color.white.opacity(0.16))
                    .frame(width: 30, height: 18)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .padding(2)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        LabeledRow(title: title) {
            SwitchToggle(isOn: $isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Theme.stateAnimation) { isOn.toggle() } }
    }
}

// MARK: - Slider

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(Theme.controlFont)
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Text(format(value))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            SliderTrack(value: $value, range: range)
        }
    }

    /// Shows the value as a percentage of the slider range.
    static func percent(of range: ClosedRange<Double>) -> (Double) -> String {
        { value in
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            return "\(Int((fraction * 100).rounded()))%"
        }
    }
}

struct SliderTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @Environment(\.isEnabled) private var isEnabled
    private let thumb: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, thumb + 1)
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
            let x = thumb / 2 + (width - thumb) * fraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 4)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: x, height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: x - thumb / 2)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let f = (drag.location.x - thumb / 2) / (width - thumb)
                        let clamped = min(max(Double(f), 0), 1)
                        value = range.lowerBound + clamped * span
                    }
            )
        }
        .frame(height: 18)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Segmented

struct SegmentedPicker<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var systemImage: String?
    }

    let options: [Option]
    @Binding var selection: Value
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button {
                    withAnimation(Theme.stateAnimation) { selection = option.value }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.systemImage {
                            Image(systemName: symbol)
                                .font(.system(size: 11, weight: .medium))
                        }
                        Text(option.title)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selected ? Theme.primaryText : Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? Color.white.opacity(0.13) : Color.clear)
                            .shadow(color: .black.opacity(selected ? 0.25 : 0), radius: 1, y: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(FieldBackground())
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Dropdown (native NSMenu, custom label)

/// Holds the AppKit view behind a SwiftUI control so a native menu can pop up from it.
final class ViewAnchor {
    weak var view: NSView?
}

private struct AnchorView: NSViewRepresentable {
    let anchor: ViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
    }
}

struct DropdownPicker<ID: Hashable>: View {
    struct Option {
        let id: ID
        let title: String
    }

    let options: [Option]
    let selection: ID
    var systemImage: String?
    var emptyTitle = "None available"
    let onSelect: (ID) -> Void

    @State private var anchor = ViewAnchor()
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    private var title: String {
        options.first { $0.id == selection }?.title ?? (options.isEmpty ? emptyTitle : "Choose…")
    }

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 16)
                }
                Text(title)
                    .font(Theme.controlFont)
                    .foregroundStyle(options.isEmpty ? Theme.secondaryText : Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.controlHeight)
            .background(FieldBackground(hovered: hovered && isEnabled))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(AnchorView(anchor: anchor))
        .onHover { hovered = $0 }
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(options.isEmpty)
    }

    private func showMenu() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        var selected: NSMenuItem?
        for option in options {
            let id = option.id
            let item = ClosureMenuItem(title: option.title) { onSelect(id) }
            if id == selection {
                item.state = .on
                selected = item
            }
            menu.addItem(item)
        }
        menu.minimumWidth = view.bounds.width
        menu.font = NSFont.systemFont(ofSize: 13)
        let topLeft = NSPoint(x: 0, y: view.isFlipped ? 0 : view.bounds.height)
        menu.popUp(positioning: selected, at: topLeft, in: view)
    }
}

// MARK: - Buttons

enum ToolButtonKind {
    case primary
    case secondary
    case destructive
    case record
}

struct ToolButtonStyle: ButtonStyle {
    var kind: ToolButtonKind = .secondary
    var height: CGFloat = Theme.controlHeight
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        ToolButtonBody(configuration: configuration, kind: kind, height: height, fullWidth: fullWidth)
    }
}

private struct ToolButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: ToolButtonKind
    let height: CGFloat
    let fullWidth: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .onHover { hovered = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary, .record: return .white
        case .secondary: return Theme.primaryText
        case .destructive: return Theme.record
        }
    }

    private var fill: Color {
        let lift = hovered && isEnabled
        switch kind {
        case .primary: return lift ? Color(hex: 0x9A6DF8) : Theme.accent
        case .record: return lift ? Color(hex: 0xFF5A50) : Theme.record
        case .secondary, .destructive: return lift ? Color.white.opacity(0.11) : Color.white.opacity(0.07)
        }
    }

    private var border: Color {
        switch kind {
        case .primary, .record: return Color.white.opacity(0.10)
        case .secondary, .destructive: return Theme.fieldBorder
        }
    }
}

/// Small square icon button (refresh, close banner, HUD controls).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 24
    var tint: Color = Theme.secondaryText

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, tint: tint)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let tint: Color
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(hovered && isEnabled ? Theme.primaryText : tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(hovered && isEnabled ? 0.10 : 0))
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .onHover { hovered = $0 }
    }
}

struct Keycap: View {
    let text: String
    var onDark = true

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(onDark ? 0.16 : 0.22))
            )
    }
}

// MARK: - Selection ring

extension View {
    /// 2 pt accent ring with a 2 pt gap around the view.
    func selectionRing(_ selected: Bool, cornerRadius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .padding(-4)
                .opacity(selected ? 1 : 0)
        )
    }
}
