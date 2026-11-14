import AppKit
import Foundation
import ScreenyCapture
import ScreenyCore
import ScreenyRender
import ScreenyUI

// Headless check of the compositor and the recorder. It needs no privacy permissions.
// Usage: ScreenyPro --selftest /path/to/out.mp4
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--selftest") {
    guard arguments.count > index + 1 else {
        FileHandle.standardError.write(Data("usage: ScreenyPro --selftest <out.mp4>\n".utf8))
        exit(2)
    }
    let url = URL(fileURLWithPath: arguments[index + 1])
    let semaphore = DispatchSemaphore(value: 0)
    var failure: Error?
    Task.detached {
        do {
            try await SelfTest.run(outputURL: url)
        } catch {
            failure = error
        }
        semaphore.signal()
    }
    semaphore.wait()
    if let failure {
        FileHandle.standardError.write(Data("selftest failed: \(failure)\n".utf8))
        exit(1)
    }
    print("selftest ok: \(url.path)")
    exit(0)
}

let dependencies = AppDependencies(
    makeScreenCapture: { SCScreenCapture() },
    makeCamera: { AVCameraCapture() },
    system: MacSystemAccess(),
    makePipeline: { screen, camera in FramePipeline(screen: screen, camera: camera) },
    makeRecorder: { config in MovieRecorder(config: config) },
    makePreviewView: { PreviewView(frame: .zero) }
)

runScreenyProApp(dependencies: dependencies)
