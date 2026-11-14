import AppKit
import Foundation
import ScreenyCapture
import ScreenyCloud
import ScreenyCore
import ScreenyRender
import ScreenyUI

// Headless check of the compositor and the recorder. It needs no privacy permissions.
// Usage: ScreenyPro --selftest /path/to/out.mp4      (16:9)
//        ScreenyPro --selftest-portrait /path/to/out.mp4   (9:16)
let arguments = CommandLine.arguments
let selfTestPortrait = arguments.contains("--selftest-portrait")
if let index = arguments.firstIndex(of: "--selftest") ?? arguments.firstIndex(of: "--selftest-portrait") {
    guard arguments.count > index + 1 else {
        FileHandle.standardError.write(Data("usage: ScreenyPro --selftest <out.mp4>\n".utf8))
        exit(2)
    }
    let url = URL(fileURLWithPath: arguments[index + 1])
    let semaphore = DispatchSemaphore(value: 0)
    var failure: Error?
    Task.detached {
        do {
            try await SelfTest.run(outputURL: url, portrait: selfTestPortrait)
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

// Cloud sharing from the command line (no GUI):
//   ScreenyPro --cloud-configure <endpoint> <secret-file>   reads the secret from a file, never from argv
//   ScreenyPro --cloud-upload <file.mp4>                    prints progress and the share URL (Ctrl-C cancels)
//   ScreenyPro --cloud-delete <id>
func cloudCommand(_ arguments: [String]) -> Int32? {
    func fail(_ message: String, code: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        return code
    }
    func describe(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
    /// Runs async work on a detached task; Ctrl-C cancels it.
    func runBlocking(_ work: @escaping @Sendable () async throws -> Void) -> Error? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        let task = Task.detached {
            do { try await work() } catch { failure = error }
            semaphore.signal()
        }
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { task.cancel() }
        interrupt.resume()
        semaphore.wait()
        interrupt.cancel()
        return failure
    }

    let cloud = CloudUploader()
    if let i = arguments.firstIndex(of: "--cloud-configure") {
        guard arguments.count > i + 2, let endpoint = URL(string: arguments[i + 1]) else {
            return fail("usage: ScreenyPro --cloud-configure <endpoint> <secret-file>", code: 2)
        }
        let secret: String
        do {
            secret = try String(contentsOfFile: arguments[i + 2], encoding: .utf8)
        } catch {
            return fail("cannot read the secret file: \(error.localizedDescription)")
        }
        do {
            try cloud.configure(endpoint: endpoint, secret: secret)
        } catch {
            return fail("configure failed: \(describe(error))")
        }
        print("cloud configured: \(cloud.configuration?.endpoint.absoluteString ?? "?")")
        return 0
    }
    if let i = arguments.firstIndex(of: "--cloud-upload") {
        guard arguments.count > i + 1 else { return fail("usage: ScreenyPro --cloud-upload <file.mp4>", code: 2) }
        let url = URL(fileURLWithPath: arguments[i + 1])
        let request = CloudUploadRequest(fileURL: url, title: url.deletingPathExtension().lastPathComponent)
        nonisolated(unsafe) var share: CloudShare?
        let error = runBlocking {
            share = try await cloud.upload(request) { value in
                FileHandle.standardError.write(Data(String(format: "\ruploading %5.1f%%", value * 100).utf8))
            }
        }
        FileHandle.standardError.write(Data("\n".utf8))
        if let error { return fail("upload failed: \(describe(error))") }
        guard let share else { return fail("upload failed") }
        print(share.shareURL.absoluteString)
        FileHandle.standardError.write(Data("id \(share.id), expires \(share.expiresAt)\n".utf8))
        return 0
    }
    if let i = arguments.firstIndex(of: "--cloud-delete") {
        guard arguments.count > i + 1 else { return fail("usage: ScreenyPro --cloud-delete <id>", code: 2) }
        let id = arguments[i + 1]
        if let error = runBlocking({ try await cloud.delete(id: id) }) {
            return fail("delete failed: \(describe(error))")
        }
        print("deleted \(id)")
        return 0
    }
    return nil
}

if let code = cloudCommand(arguments) {
    exit(code)
}

let dependencies = AppDependencies(
    makeScreenCapture: { SCScreenCapture() },
    makeCamera: { AVCameraCapture() },
    system: MacSystemAccess(),
    makePipeline: { screen, camera in FramePipeline(screen: screen, camera: camera) },
    makeRecorder: { config in MovieRecorder(config: config) },
    makePreviewView: { PreviewView(frame: .zero) },
    cloud: CloudUploader()
)

runScreenyProApp(dependencies: dependencies)
