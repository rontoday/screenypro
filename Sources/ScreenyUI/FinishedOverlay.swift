import AVFoundation
import AppKit
import CoreImage
import SwiftUI

/// Facts about a finished recording, loaded off the main thread.
struct RecordingInfo: Equatable {
    var thumbnail: CGImage?
    /// Blurred thumbnail that fills the box around a video whose aspect differs from the box.
    var backdrop: CGImage?
    var duration: TimeInterval?
    var fileSize: Int64?
    var pixelSize: CGSize?

    /// `thumbnailSide` bounds the thumbnail; `backdrop` adds the blurred copy that fills the box around it.
    static func load(url: URL, thumbnailSide: CGFloat = 960, backdrop: Bool = true) async -> RecordingInfo {
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
        generator.maximumSize = CGSize(width: thumbnailSide, height: thumbnailSide)
        let time = CMTime(seconds: min(0.5, (info.duration ?? 0) / 2), preferredTimescale: 600)
        if let result = try? await generator.image(at: time) {
            info.thumbnail = result.image
            // The box can be shorter than the video's aspect on small windows: any video may need the backdrop.
            if backdrop { info.backdrop = blurred(result.image) }
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

/// The "finished sheet": a card over the main window after a recording is saved.
struct FinishedOverlay: View {
    @ObservedObject var controller: RecorderController
    let url: URL

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture {}
                FinishedCard(controller: controller, sharing: controller.sharing, url: url)
                    // The thumbnail shrinks first, so the card always fits the window (also at minimum size).
                    .frame(maxHeight: max(320, geo.size.height - 24))
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

private struct FinishedCard: View {
    @ObservedObject var controller: RecorderController
    @ObservedObject var sharing: CloudShareCenter
    let url: URL
    @State private var info = RecordingInfo()
    @State private var copied = false
    @State private var confirmingDelete = false
    @FocusState private var titleFocused: Bool

    /// Natural box height: 16:9 at the card's content width, or the fixed box for a tall video.
    private var naturalThumbnailHeight: CGFloat { isTall ? 252 : 460 * 9 / 16 }

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
                        if let backdrop = info.backdrop {
                            // The box rarely has the video's aspect: fill around it with a dim, blurred copy.
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
                .frame(maxWidth: .infinity)
                .frame(minHeight: 96, maxHeight: naturalThumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Play")
            .layoutPriority(-1)

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
                .buttonStyle(ToolButtonStyle(kind: .secondary, fullWidth: true))

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

            CardShareSection(sharing: sharing, url: url, titleFocused: $titleFocused)

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
                    // Return in the title field must not close the card.
                    .keyboardShortcut(titleFocused ? nil : .defaultAction)
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
        .onAppear { sharing.visibleCardPath = CloudShareCenter.key(url) }
        .onDisappear {
            if sharing.visibleCardPath == CloudShareCenter.key(url) { sharing.visibleCardPath = nil }
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
