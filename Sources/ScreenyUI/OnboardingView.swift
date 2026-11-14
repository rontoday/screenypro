import ScreenyCore
import SwiftUI

/// Replaces the preview while screen recording is not allowed.
struct OnboardingView: View {
    @ObservedObject var controller: RecorderController

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.16))
                    .frame(width: 56, height: 56)
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.bottom, 16)

            Text("Allow screen recording")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .padding(.bottom, 8)

            Text("ScreenyPro needs the Screen Recording permission to show the live preview and record your screen. Camera and microphone are optional.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 10) {
                Step(number: 1, text: "Click Grant Access, or open System Settings.")
                Step(number: 2, text: "Turn on ScreenyPro under Screen & System Audio Recording.")
                Step(number: 3, text: "Quit and reopen ScreenyPro. macOS needs a restart to apply it.")
            }
            .padding(.bottom, 24)

            HStack(spacing: 8) {
                Button(action: controller.requestScreenAccess) {
                    HStack(spacing: 6) {
                        if controller.isRequestingScreenAccess {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text("Grant Access")
                    }
                }
                .buttonStyle(ToolButtonStyle(kind: .primary, height: 32))
                .disabled(controller.isRequestingScreenAccess)

                Button("Open System Settings") {
                    controller.openSettings(for: .screenRecording)
                }
                .buttonStyle(ToolButtonStyle(kind: .secondary, height: 32))

                Button("Quit and Reopen", action: controller.quitAndReopen)
                    .buttonStyle(ToolButtonStyle(kind: .secondary, height: 32))
            }

            if controller.screenAccessNeedsRestart {
                Text("Already turned it on? Quit and reopen to apply it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .padding(.bottom, 8)
        .animation(Theme.stateAnimation, value: controller.screenAccessNeedsRestart)
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.10)))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
        }
    }
}
