import AVFoundation
import AppKit
import CoreImage
import SwiftUI

/// Facts about a finished recording, loaded off the main thread.
struct RecordingInfo: Equatable {
    var thumbnail: CGImage?
    /// Blurred thumbnail that fills the sides of the box behind a tall (9:16) video.
    var backdrop: CGImage?
    var duration: TimeInterval?
    var fileSize: Int64?
    var pixelSize: CGSize?

    static func load(url: URL) async -> RecordingInfo {
        var info = RecordingInfo()
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber {
            info.fileSize = size.int64Value
        }
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            info.duration = duration.seconds
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            info.pixelSize = size
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Square bound: enough for a 16:9 and a 9:16 thumbnail.
        generator.maximumSize = CGSize(width: 960, height: 960)
        let time = CMTime(seconds: min(0.5, (info.duration ?? 0) / 2), preferredTimescale: 600)
        if let result = try? await generator.image(at: time) {
            info.thumbnail = result.image
            if result.image.height > result.image.width {
                info.backdrop = blurred(result.image)
            }
        }
        return info
    }

    /// A small, heavily blurred copy (Core Image, so it looks the same in every renderer).
    private static func blurred(_ image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        guard source.extent.width > 0 else { return nil }
        let scale = 160 / source.extent.width
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 9).cropped(to: small.extent)
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(blurred, from: small.extent)
    }
}

/// 16:9 box for a landscape video; a full-width box of fixed height for a tall (9:16) video.
private struct ThumbnailFrame: ViewModifier {
    let isTall: Bool

    func body(content: Content) -> some View {
        if isTall {
            content
                .frame(maxWidth: .infinity)
                .frame(height: 252)
        } else {
            content.aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
    }
}

/// The "finished sheet": a card over the main window after a recording is saved.
struct FinishedOverlay: View {
    @ObservedObject var controller: RecorderController
    let url: URL

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture {}
            FinishedCard(controller: controller, url: url)
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
    }
}

private struct FinishedCard: View {
    @ObservedObject var controller: RecorderController
    let url: URL
    @State private var info = RecordingInfo()
    @State private var copied = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.meterGreen)
                Text("Recording saved")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Button(action: controller.dismissFinished) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }

            Button(action: play) {
                ZStack {
                    Rectangle().fill(Color.black)
                    if let thumbnail = info.thumbnail {
                        if isTall, let backdrop = info.backdrop {
                            // A tall video sits in a wide box: fill the sides with a dim, blurred copy.
                            // Color.clear takes the box size, so the filled copy never grows the layout.
                            Color.clear
                                .overlay(
                                    Image(decorative: backdrop, scale: 1)
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fill)
                                        .opacity(0.45)
                                )
                                .clipped()
                        }
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    Circle()
                        .fill(Color.black.opacity(0.5))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .offset(x: 2)
                        )
                }
                .modifier(ThumbnailFrame(isTall: isTall))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Play")

            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(details)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }

            HStack(spacing: 8) {
                Button(action: play) {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(ToolButtonStyle(kind: .primary, fullWidth: true))

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(ToolButtonStyle(kind: .secondary, fullWidth: true))

                Button(action: copyFile) {
                    Label(copied ? "Copied" : "Copy File", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(ToolButtonStyle(kind: .secondary, fullWidth: true))
            }

            Hairline()

            HStack(spacing: 8) {
                if confirmingDelete {
                    Text("Move to Trash?")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.primaryText)
                    Button("Cancel") { confirmingDelete = false }
                        .buttonStyle(ToolButtonStyle(kind: .secondary))
                    Button("Move to Trash", action: controller.trashFinished)
                        .buttonStyle(ToolButtonStyle(kind: .destructive))
                } else {
                    Button {
                        confirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(ToolButtonStyle(kind: .destructive))
                }
                Spacer()
                Button("Done", action: controller.dismissFinished)
                    .buttonStyle(ToolButtonStyle(kind: .secondary))
                    .keyboardShortcut(.defaultAction)
            }
            .animation(Theme.stateAnimation, value: confirmingDelete)
        }
        .padding(20)
        .frame(width: 500)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .task(id: url) {
            info = await RecordingInfo.load(url: url)
        }
    }

    /// Portrait video. Before the file is read, the current canvas format is the best guess.
    private var isTall: Bool {
        if let px = info.pixelSize, px.width > 0, px.height > 0 { return px.height > px.width }
        return controller.settings.output.format == .portrait
    }

    private var details: String {
        var parts: [String] = []
        if let duration = info.duration { parts.append(Format.elapsed(duration)) }
        if let size = info.fileSize { parts.append(Format.fileSize(size)) }
        if let px = info.pixelSize, px.width > 0 { parts.append("\(Int(px.width)) × \(Int(px.height))") }
        return parts.isEmpty ? "Loading…" : parts.joined(separator: "  ·  ")
    }

    private func play() {
        NSWorkspace.shared.open(url)
    }

    private func copyFile() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
