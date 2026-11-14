import AppKit
import ScreenyCore
import SwiftUI

// Cloud sharing views: the share block of the finished card, the upload indicator in the record row,
// the in-app notice, the recent recordings list and the cloud settings sheet.

// MARK: - Small parts

/// Thin determinate bar in the slider style (4 pt capsule, accent fill).
struct UploadProgressBar: View {
    let value: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(height, geo.size.width * fraction))
                    .opacity(fraction > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.1), value: value)
        .accessibilityElement()
        .accessibilityLabel("Upload progress")
        .accessibilityValue(CloudFormat.percent(value))
    }
}

/// Single-line text field on the dark field background, with a leading caption.
struct CaptionedField<Field: View>: View {
    let caption: String
    var captionWidth: CGFloat?
    @ViewBuilder var field: () -> Field

    var body: some View {
        HStack(spacing: 8) {
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: captionWidth, alignment: .leading)
            field()
                .textFieldStyle(.plain)
                .font(Theme.controlFont)
                .foregroundStyle(Theme.primaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.controlHeight)
        .background(FieldBackground())
    }
}

// MARK: - Finished card: share block

/// Title + "Upload & Copy Link", then the upload states. Every state has two 28 pt rows, so the card keeps
/// its height while the state changes.
struct CardShareSection: View {
    @ObservedObject var sharing: CloudShareCenter
    let url: URL
    var titleFocused: FocusState<Bool>.Binding
    @State private var confirmingRemove = false

    private var status: CloudShareCenter.Status { sharing.status(for: url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch status {
            case .shared(let share):
                linkRow(share)
                sharedFooter(share)
            case .removing(let share):
                linkRow(share)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Removing from the cloud…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                }
                .frame(height: Theme.controlHeight)
            default:
                titleField
                actionRow
            }
        }
        .animation(Theme.stateAnimation, value: status.kindKey)
        .animation(Theme.stateAnimation, value: confirmingRemove)
        .onChange(of: status.kindKey) { _, _ in confirmingRemove = false }
    }

    private var titleField: some View {
        CaptionedField(caption: "Title") {
            TextField("", text: Binding(
                get: { sharing.title(for: url) },
                set: { sharing.setTitle($0, for: url) }
            ), prompt: Text(CloudShareCenter.defaultTitle(for: url)))
            .focused(titleFocused)
            .onSubmit { titleFocused.wrappedValue = false }
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1)
        .help("Shown to the client on the video page")
    }

    private var isBusy: Bool {
        switch status {
        case .uploading, .queued: return true
        default: return false
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch status {
        case .uploading(let progress):
            HStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                UploadProgressBar(value: progress)
                Text(CloudFormat.percent(progress))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 36, alignment: .trailing)
                Button("Cancel") { sharing.cancelUpload(for: url) }
                    .buttonStyle(ToolButtonStyle(kind: .secondary))
            }
            .frame(height: Theme.controlHeight)
            .help("You can close this card. The upload continues and the link is copied when it is done.")
        case .queued:
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                Text("Waiting for the current upload to finish…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel") { sharing.cancelUpload(for: url) }
                    .buttonStyle(ToolButtonStyle(kind: .secondary))
            }
            .frame(height: Theme.controlHeight)
        case .failed(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.record)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .help(message)
                Button {
                    sharing.upload(url)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ToolButtonStyle(kind: .primary))
            }
            .frame(minHeight: Theme.controlHeight)
        default:
            if sharing.configuration == nil {
                Button {
                    sharing.upload(url)
                } label: {
                    Label("Set Up Cloud Sharing…", systemImage: "icloud")
                }
                .buttonStyle(ToolButtonStyle(kind: .primary, fullWidth: true))
                .help("Connect ScreenyPro to the video server, then upload")
            } else {
                Button {
                    titleFocused.wrappedValue = false
                    sharing.upload(url)
                } label: {
                    Label("Upload & Copy Link", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(ToolButtonStyle(kind: .primary, fullWidth: true))
                .help("Upload to \(sharing.configuration.map { $0.endpoint.host ?? $0.endpoint.absoluteString } ?? "the cloud") and copy a link that works for 14 days")
            }
        }
    }

    private func linkRow(_ share: CloudShare) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(share.shareURL.absoluteString)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.controlHeight)
            .background(FieldBackground())
            .help(share.shareURL.absoluteString)

            let copied = sharing.isCopied(url)
            Button {
                sharing.copyLink(for: url)
            } label: {
                Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 86)
            }
            .buttonStyle(ToolButtonStyle(kind: .primary))

            Button {
                sharing.open(share)
            } label: {
                Label("Open", systemImage: "safari")
            }
            .buttonStyle(ToolButtonStyle(kind: .secondary))
            .help("Open the video page in the browser")
        }
    }

    @ViewBuilder
    private func sharedFooter(_ share: CloudShare) -> some View {
        HStack(spacing: 8) {
            if confirmingRemove {
                Text("Remove from the cloud? The link stops working.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 4)
                Button("Cancel") { confirmingRemove = false }
                    .buttonStyle(ToolButtonStyle(kind: .secondary))
                Button("Remove") { sharing.removeFromCloud(url) }
                    .buttonStyle(ToolButtonStyle(kind: .destructive))
            } else {
                if let error = sharing.removeError(for: url) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.record)
                    Text("Could not remove: \(error)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                } else if sharing.isCopied(url) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.meterGreen)
                    Text("Link copied")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .fixedSize()
                    Text("·").foregroundStyle(Theme.tertiaryText)
                    expiryText(share)
                } else {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                    expiryText(share)
                }
                Spacer(minLength: 8)
                Button {
                    confirmingRemove = true
                } label: {
                    Text("Remove from cloud")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .underline(false)
                }
                .buttonStyle(.plain)
                .help("Delete the video on the server now. The link stops working.")
            }
        }
        .frame(height: Theme.controlHeight)
    }

    private func expiryText(_ share: CloudShare) -> some View {
        Text("Available until \(CloudFormat.expiry(share.expiresAt))")
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

extension CloudShareCenter.Status {
    /// Changes only between states (not with progress), for animations.
    var kindKey: Int {
        switch self {
        case .idle: return 0
        case .queued: return 1
        case .uploading: return 2
        case .failed: return 3
        case .shared: return 4
        case .removing: return 5
        }
    }
}

// MARK: - Record row indicator

/// Replaces "Saved to Movies › ScreenyPro" in the record row while uploads run. Opens the recordings list.
struct RecordBarSubtitle: View {
    @ObservedObject var sharing: CloudShareCenter

    var body: some View {
        if let job = sharing.active {
            Button {
                sharing.isRecordingsShown = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    UploadProgressBar(value: sharing.progress, height: 3)
                        .frame(width: 56)
                    Text(CloudFormat.percent(sharing.progress))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 30, alignment: .leading)
                    if !sharing.queue.isEmpty {
                        Text("+\(sharing.queue.count)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 4)
                            .frame(height: 14)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                            .fixedSize()
                    }
                }
                .frame(height: 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Uploading “\(job.title)”" + (sharing.queue.isEmpty ? "" : ", \(sharing.queue.count) more waiting") + ". Click to see recordings.")
        } else {
            Text("Saved to Movies › ScreenyPro")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .frame(height: 14)
        }
    }
}

// MARK: - Notice banner

/// "Notification" in the main window when an upload ends while its card is closed.
struct CloudNoticeView: View {
    @ObservedObject var sharing: CloudShareCenter
    let notice: CloudShareCenter.Notice

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(detailHelp)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
            Button {
                sharing.notice = nil
            } label: {
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
                .fill(isFailure ? Color(hex: 0x3A1D1E) : Color(hex: 0x2A2C33))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(isFailure ? Theme.record.opacity(0.35) : Theme.fieldBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .frame(maxWidth: 560)
    }

    private var isFailure: Bool {
        if case .failed = notice.kind { return true }
        return false
    }

    @ViewBuilder
    private var icon: some View {
        switch notice.kind {
        case .shared:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.meterGreen)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.record)
        }
    }

    private var headline: String {
        switch notice.kind {
        case .shared(_, let copied): return copied ? "Upload finished · Link copied" : "Upload finished · Link ready"
        case .failed: return "Upload failed"
        }
    }

    private var detail: String {
        switch notice.kind {
        case .shared(let share, _):
            return "“\(notice.title)” · available until \(CloudFormat.shortExpiry(share.expiresAt))"
        case .failed(let message):
            return "“\(notice.title)”: \(message)"
        }
    }

    private var detailHelp: String {
        switch notice.kind {
        case .shared(let share, _):
            return "\(notice.title)\n\(share.shareURL.absoluteString)\nAvailable until \(CloudFormat.expiry(share.expiresAt))"
        case .failed(let message):
            return "\(notice.title)\n\(message)"
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch notice.kind {
        case .shared(let share, _):
            let copied = sharing.copiedPath == notice.path
            Button {
                sharing.copy(share, path: notice.path)
            } label: {
                Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(ToolButtonStyle(kind: .secondary, height: 24))
            .fixedSize()
            Button {
                sharing.open(share)
            } label: {
                Image(systemName: "safari").font(.system(size: 12))
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .help("Open the video page in the browser")
            .accessibilityLabel("Open")
        case .failed:
            Button {
                let url = notice.url
                sharing.notice = nil
                sharing.upload(url)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ToolButtonStyle(kind: .secondary, height: 24))
            .fixedSize()
        }
    }
}

// MARK: - Recent recordings

struct RecordingsListView: View {
    @ObservedObject var sharing: CloudShareCenter
    @ObservedObject var library: RecordingsLibrary

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Recent Recordings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Button {
                    RecorderController.openRecordingsFolder()
                } label: {
                    Image(systemName: "folder").font(.system(size: 12))
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Open Recordings Folder")
                Button {
                    sharing.isRecordingsShown = false
                    sharing.showSettings()
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 12))
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Cloud Settings…")
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 44)

            Hairline()

            if library.items.isEmpty {
                Text(library.isLoaded ? "No recordings yet." : "Loading…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(library.items) { item in
                            RecordingRow(sharing: sharing, item: item, info: library.infos[item.id])
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .frame(height: min(CGFloat(library.items.count) * 58 + 16, 420))
            }

            Hairline()

            HStack(spacing: 6) {
                Image(systemName: sharing.configuration == nil ? "icloud.slash" : "clock")
                    .font(.system(size: 10))
                Text(footer)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(Theme.tertiaryText)
            .padding(.horizontal, 16)
            .frame(height: 30)
        }
        .frame(width: 560)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
        .onAppear {
            sharing.pruneShares()
            library.reload()
        }
    }

    private var footer: String {
        guard let configuration = sharing.configuration else { return "Cloud sharing is not set up." }
        return "Links work for 14 days · \(configuration.endpoint.host ?? configuration.endpoint.absoluteString)"
    }
}

private struct RecordingRow: View {
    @ObservedObject var sharing: CloudShareCenter
    let item: RecordingsLibrary.Item
    let info: RecordingInfo?
    @State private var hovered = false

    private var status: CloudShareCenter.Status { sharing.status(for: item.url) }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
                    .frame(height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "folder").font(.system(size: 12))
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help("Show in Finder")
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.04 : 0))
        )
        .onHover { hovered = $0 }
        .help(item.url.lastPathComponent)
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.45))
            if let image = info?.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: isTall ? .fit : .fill)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .frame(width: 64, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var isTall: Bool {
        guard let px = info?.pixelSize, px.width > 0 else { return false }
        return px.height > px.width
    }

    private var facts: String {
        var parts: [String] = []
        if let duration = info?.duration { parts.append(Format.elapsed(duration)) }
        parts.append(Format.fileSize(info?.fileSize ?? item.fileSize))
        if isTall { parts.append("9:16") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var subtitle: some View {
        switch status {
        case .uploading(let progress):
            HStack(spacing: 6) {
                UploadProgressBar(value: progress, height: 3)
                    .frame(width: 90)
                Text(CloudFormat.percent(progress))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
        case .queued:
            Text("Waiting to upload…")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        case .failed(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.record)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.primaryText.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(message)
        case .shared(let share), .removing(let share):
            HStack(spacing: 4) {
                Text(facts)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize()
                Text("·").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                Image(systemName: "link")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(sharing.isCopied(item.url) ? "Link copied" : "until \(CloudFormat.shortExpiry(share.expiresAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(sharing.isCopied(item.url) ? Theme.primaryText : Theme.secondaryText)
                    .lineLimit(1)
            }
            .help("\(share.shareURL.absoluteString)\nAvailable until \(CloudFormat.expiry(share.expiresAt))")
        case .idle:
            Text(facts)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch status {
        case .uploading, .queued:
            Button("Cancel") { sharing.cancelUpload(for: item.url) }
                .buttonStyle(ToolButtonStyle(kind: .secondary, height: 26))
                .fixedSize()
        case .failed:
            Button {
                sharing.upload(item.url)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ToolButtonStyle(kind: .secondary, height: 26))
            .fixedSize()
        case .shared:
            let copied = sharing.isCopied(item.url)
            Button {
                sharing.copyLink(for: item.url)
            } label: {
                Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link")
            }
            .buttonStyle(ToolButtonStyle(kind: .secondary, height: 26))
            .fixedSize()
        case .removing:
            ProgressView().controlSize(.small)
        case .idle:
            Button {
                if sharing.configuration == nil { sharing.isRecordingsShown = false }
                sharing.upload(item.url)
            } label: {
                Label("Upload & Copy Link", systemImage: "icloud.and.arrow.up")
            }
            .buttonStyle(ToolButtonStyle(kind: .secondary, height: 26))
            .fixedSize()
        }
    }
}

// MARK: - Cloud settings

struct CloudSettingsView: View {
    @ObservedObject var sharing: CloudShareCenter
    @State private var endpoint = ""
    @State private var secret = ""
    @State private var error: String?
    @State private var isSaving = false
    @State private var confirmingDisconnect = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cloud Sharing")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text("Upload a recording and send the client a link. Videos are deleted after 14 days.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                CaptionedField(caption: "Server", captionWidth: 52) {
                    TextField("", text: $endpoint, prompt: Text("https://video.comakers.cz"))
                }
                CaptionedField(caption: "Secret", captionWidth: 52) {
                    SecureField("", text: $secret, prompt: Text(sharing.configuration == nil ? "Upload secret" : "Saved in Keychain"))
                        .onSubmit(save)
                }
            }
            .disabled(isSaving)

            statusRow

            Hairline()

            HStack(spacing: 8) {
                if sharing.configuration != nil {
                    if confirmingDisconnect {
                        Text("Disconnect?")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.primaryText)
                        Button("Disconnect") {
                            sharing.disconnect()
                            confirmingDisconnect = false
                            secret = ""
                        }
                        .buttonStyle(ToolButtonStyle(kind: .destructive))
                    } else {
                        Button("Disconnect") { confirmingDisconnect = true }
                            .buttonStyle(ToolButtonStyle(kind: .destructive))
                            .help("Remove the server and the secret from this Mac. Shared links keep working.")
                    }
                }
                Spacer()
                Button("Cancel") { close() }
                    .buttonStyle(ToolButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button(action: save) {
                    if isSaving {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(ToolButtonStyle(kind: .primary))
                .frame(minWidth: 64)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || endpoint.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .animation(Theme.stateAnimation, value: confirmingDisconnect)
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
        .onAppear {
            endpoint = sharing.configuration?.endpoint.absoluteString ?? ""
            secret = ""
            error = nil
        }
        .onChange(of: sharing.configuration) { _, configuration in
            if configuration == nil { confirmingDisconnect = false }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(alignment: .top, spacing: 8) {
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.record)
                    .padding(.top, 1)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if let configuration = sharing.configuration {
                Circle().fill(Theme.meterGreen).frame(width: 7, height: 7).padding(.top, 4)
                Text("Set up for \(configuration.endpoint.host ?? configuration.endpoint.absoluteString). The secret is stored in the Keychain.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Circle().fill(Color.white.opacity(0.3)).frame(width: 7, height: 7).padding(.top, 4)
                Text("Not set up. Enter the server URL and the upload secret.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: 16)
    }

    private func close() {
        sharing.settingsDismissed()
        dismiss()
    }

    private func save() {
        guard !isSaving else { return }
        error = nil
        guard let url = Self.parseEndpoint(endpoint) else {
            error = "Enter a valid server URL, for example https://video.comakers.cz."
            return
        }
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSecret.isEmpty {
            if let current = sharing.configuration, current.endpoint == url {
                close() // nothing changed
                return
            }
            error = "Enter the upload secret."
            return
        }
        isSaving = true
        Task {
            do {
                try await sharing.configure(endpoint: url, secret: trimmedSecret)
                isSaving = false
                if sharing.configuration == nil {
                    error = "The settings were not saved. Check the server URL and the secret."
                } else {
                    secret = ""
                    dismiss()
                }
            } catch {
                isSaving = false
                self.error = CloudShareCenter.message(for: error)
            }
        }
    }

    /// Accepts "video.comakers.cz" (adds https://), drops a trailing slash. http only for local testing.
    static func parseEndpoint(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty, host.contains(".") || host == "localhost"
        else { return nil }
        return components.url
    }
}
