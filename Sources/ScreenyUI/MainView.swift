import AppKit
import ScreenyCore
import SwiftUI

/// Root of the main window: live preview on the left, inspector on the right.
struct MainView: View {
    @ObservedObject var controller: RecorderController

    var body: some View {
        HStack(spacing: 0) {
            StagePane(controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline(vertical: true)
                .ignoresSafeArea()
            InspectorView(controller: controller)
                .frame(width: 300)
                .background(Theme.panel.ignoresSafeArea())
        }
        .frame(minWidth: 860, minHeight: 532) // + 28 pt title bar = 560 window height
        .background(Theme.windowBackground.ignoresSafeArea())
        .overlay {
            if case .finished(let url) = controller.state {
                FinishedOverlay(controller: controller, url: url)
                    .transition(.opacity)
            }
        }
        .animation(Theme.stateAnimation, value: controller.state)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Stage (preview + record row)

private struct StagePane: View {
    @ObservedObject var controller: RecorderController

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Group {
                    if controller.screenPermission == .granted {
                        PreviewCard(controller: controller)
                    } else {
                        OnboardingView(controller: controller)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let banner = controller.banner {
                    BannerView(banner: banner) { controller.banner = nil }
                        .padding(.top, 12)
                        .padding(.horizontal, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .animation(Theme.stateAnimation, value: controller.banner)

            RecordBar(controller: controller)
                .padding(.horizontal, 24)
                .frame(height: 72)
        }
    }
}

private struct PreviewCard: View {
    @ObservedObject var controller: RecorderController

    private var aspect: CGFloat {
        let canvas = controller.settings.output.canvasSize
        return canvas.height > 0 ? canvas.width / canvas.height : 16.0 / 9.0
    }

    var body: some View {
        PreviewHost(preview: controller.previewView)
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .overlay(alignment: .bottomLeading) {
                SourceChip(
                    title: controller.sourceTitle,
                    isWindow: controller.settings.sourceKind == .window,
                    areaText: areaText
                )
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Theme.stateAnimation, value: controller.settings.output.format)
    }
}

extension PreviewCard {
    /// "Area" when only a part of the display is recorded.
    fileprivate var areaText: String? {
        controller.effectiveArea == nil ? nil : "Area"
    }
}

/// Small label on the preview: what is being recorded.
private struct SourceChip: View {
    let title: String
    let isWindow: Bool
    var areaText: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isWindow ? "macwindow" : (areaText == nil ? "display" : "rectangle.dashed"))
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let areaText {
                Text(areaText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
            }
        }
        .foregroundStyle(Color.white.opacity(0.85))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .frame(maxWidth: 360, alignment: .leading)
    }
}

/// Hosts the injected preview view. The view itself is created once by the controller and reused.
struct PreviewHost: NSViewRepresentable {
    let preview: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if preview.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        preview.removeFromSuperview()
        preview.frame = container.bounds
        preview.autoresizingMask = [.width, .height]
        container.addSubview(preview)
    }
}

// MARK: - Record row

private struct RecordBar: View {
    @ObservedObject var controller: RecorderController

    var body: some View {
        HStack(spacing: 16) {
            RecordButton(controller: controller)
            VStack(alignment: .leading, spacing: 2) {
                Text(outputSummary)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
                Text("Saved to Movies › ScreenyPro")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 12)
            MicLevelMeter(meter: controller.meter, deviceName: microphoneName)
        }
    }

    private var outputSummary: String {
        Format.outputSummary(controller.settings.output)
    }

    private var microphoneName: String? {
        guard let id = controller.effectiveMicrophoneID else { return nil }
        return controller.microphones.first { $0.id == id }?.name
    }
}

private struct RecordButton: View {
    @ObservedObject var controller: RecorderController

    var body: some View {
        Button(action: controller.toggleRecording) {
            HStack(spacing: 8) {
                switch controller.state {
                case .idle, .finished:
                    Circle().fill(Color.white).frame(width: 10, height: 10)
                    Text("Record").font(.system(size: 14, weight: .semibold))
                    Keycap(text: "⌘⇧R", onDark: false)
                case .countdown:
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    Text("Cancel").font(.system(size: 14, weight: .semibold))
                case .recording, .paused:
                    RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 10, height: 10)
                    Text("Stop").font(.system(size: 14, weight: .semibold))
                    Keycap(text: "⌘⇧R", onDark: false)
                case .finishing:
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Saving…").font(.system(size: 14, weight: .semibold))
                }
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(ToolButtonStyle(kind: .record, height: 38))
        .disabled(controller.state == .finishing || controller.screenPermission != .granted)
        .help("Start or stop recording (⌘⇧R)")
    }
}

private struct MicLevelMeter: View {
    @ObservedObject var meter: LevelMeterModel
    let deviceName: String?
    private let segments = 16

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: deviceName == nil ? "mic.slash" : "mic.fill")
                .font(.system(size: 12))
                .foregroundStyle(deviceName == nil ? Theme.tertiaryText : Theme.secondaryText)
                .frame(width: 14)
            if deviceName == nil {
                Text("No microphone")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<segments, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(color(for: index))
                            .frame(width: 3, height: 14)
                    }
                }
            }
        }
        .help(deviceName.map { "Microphone: \($0)" } ?? "No microphone selected")
    }

    private func color(for index: Int) -> Color {
        let threshold = Double(index + 1) / Double(segments)
        guard meter.level >= threshold - 0.0001 else { return Color.white.opacity(0.12) }
        if index >= segments - 2 { return Theme.record }
        if index >= segments - 5 { return Theme.meterYellow }
        return Theme.meterGreen
    }
}

// MARK: - Banner

struct BannerView: View {
    let banner: RecorderController.Banner
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(banner.kind == .error ? Theme.record : Theme.secondaryText)
                .padding(.top, 1)
            Text(banner.message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 20))
            .help("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(banner.kind == .error ? Color(hex: 0x3A1D1E) : Color(hex: 0x2A2C33))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(banner.kind == .error ? Theme.record.opacity(0.35) : Theme.fieldBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .frame(maxWidth: 560)
    }
}
