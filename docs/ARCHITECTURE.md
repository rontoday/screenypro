# ScreenyPro — architecture and design

Native macOS screencast recorder for Comakers client videos. The styled picture (gradient background,
rounded screen content with a shadow, camera in a corner) is composed **live during recording**.
When the user stops, a finished web-ready MP4 is on disk. Cloud upload with a share link (Loom-like) is a later phase.

## Constraints

- macOS 15+, Apple Silicon. Swift 6.1 toolchain from Command Line Tools. **No Xcode**: build with SwiftPM only
  (`swift build`), bundle with `scripts/build-app.sh`. No XCTest. No third-party dependencies.
- Swift language mode 5 (set in `Package.swift`), so no strict-concurrency errors.
- Not sandboxed, no entitlements. Bundle id `cz.comakers.screenypro`.
- UI language: English.

## Modules (SwiftPM targets)

| Target | Role | Depends on |
|---|---|---|
| `ScreenyCore` | Shared models, style settings, protocols, `AppDependencies`. **Frozen contract.** | — |
| `ScreenyCapture` | ScreenCaptureKit stream (video, system audio, microphone), camera, permissions. | Core |
| `ScreenyRender` | Core Image compositor, timer-driven pipeline, preview view, AVAssetWriter recorder, self-test. | Core |
| `ScreenyUI` | AppKit + SwiftUI app: windows, menu bar, HUD, hotkeys, settings, recording state machine. | Core |
| `ScreenyPro` | `main.swift`: wires concrete types into `AppDependencies`, `--selftest` mode. | all |

Read `Sources/ScreenyCore/*.swift` first. The protocol doc comments there are part of this spec.
`Sources/ScreenyPro/main.swift` shows the concrete type names every module must export.

## Data flow

```
SCStream (screen/window) ──► LatestFrameBox(screen) ─┐
AVCaptureSession (camera) ─► LatestFrameBox(camera) ─┤
                                                     ▼
                        FramePipeline: timer at fps, host clock
                        compose(background, screen, camera, style) ─► CVPixelBuffer
                                                     │ onFrame(buffer, time)
                              ┌──────────────────────┴───────────┐
                              ▼                                  ▼
                       PreviewView (always)            MovieRecorder.appendVideo (while recording)

SCStream audio (.audio → system, .microphone → mic) ─► onAudio ─► MovieRecorder.appendAudio + UI level meter
```

Why timer-driven: SCStream sends no frames while the screen is static, but the camera keeps moving.
A fixed-rate tick that samples the latest frames gives constant frame rate output.

All timestamps are on the host clock (`CMClockGetHostTimeClock`). SCStream audio buffers already use it.

## ScreenyCapture — exports

- `public final class SCScreenCapture: ScreenCapturing` — `public init()`
- `public final class AVCameraCapture: CameraCapturing` — `public init()`
- `public final class MacSystemAccess: SystemAccess` — `public init()`

Requirements:

- One `SCStream` delivers video, system audio and microphone (`captureMicrophone`, `microphoneCaptureDeviceID`,
  output type `.microphone`, macOS 15). Add stream outputs only for the enabled kinds.
- Pixel format 32BGRA. `minimumFrameInterval = 1/fps`. `queueDepth` 5–6. sRGB color space. `showsCursor` from config.
- `excludesCurrentProcessAudio = true`. Audio 48 kHz stereo.
- Display source: `SCContentFilter(display:excludingApplications:[own app]…)` so ScreenyPro windows (control window,
  HUD, countdown) never appear in the recording.
- Window source: `SCContentFilter(desktopIndependentWindow:)`, `ignoreShadowsSingleWindow = true`
  (the compositor draws its own shadow). Follow window resizes: update the stream configuration size when the
  window's pixel size changes, without dropping the stream.
- Frame size: native pixel size of the source, scaled down to fit `maxPixelSize`, never upscaled.
- Only publish frames with status `.complete` (ignore idle/blank). Fill `VideoFrame.contentRect` from
  `SCStreamFrameInfo.contentRect × scaleFactor` (pixels, top-left origin); fall back to the full buffer.
- `listContent()`: on-screen windows only, layer 0, non-empty title, at least 120×80 pt, exclude own bundle id,
  exclude system UI apps (Dock, Window Server, Control Center, Notification Center).
- `thumbnail`: `SCScreenshotManager`.
- `start` while running: use `updateConfiguration` / `updateContentFilter` when possible; restart the stream only
  when audio outputs must change. `stop()` clears `frames`.
- `onStop` on stream errors (`SCStreamDelegate.stream(_:didStopWithError:)`).
- Camera: `AVCaptureSession`, preset up to 1920×1080, 30 fps, 32BGRA video data output, discard late frames.
  Discovery: built-in wide, external, Continuity Camera, desk view excluded. `contentRect` = full buffer.
- Permissions: screen recording via `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`;
  camera and microphone via `AVCaptureDevice.authorizationStatus/requestAccess`. `openSettings` opens the exact
  privacy pane (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` etc.).
- `microphones()`: `AVCaptureDevice.DiscoverySession` audio devices.

## ScreenyRender — exports

- `public final class FramePipeline: RenderPipeline` — `public init(screen: LatestFrameBox, camera: LatestFrameBox)`
- `public final class MovieRecorder: Recording` — `public init(config: RecordingConfig)`
- `public final class PreviewView: NSView, PreviewDisplaying` — `override init(frame:)`
- `public enum SelfTest { public static func run(outputURL: URL, portrait: Bool = false) async throws }`

### Compositor (Core Image on Metal)

One `CIContext` on the default Metal device, working color space sRGB, output tagged Rec. 709.
Render into buffers from a `CVPixelBufferPool` (32BGRA, IOSurface, Metal compatible) of the canvas size.

Layout, in canvas pixels (H = canvas height, W = canvas width):

1. **Background** fills the canvas. Gradient presets: linear base + blurred glows (see `GradientPreset`).
   Render once per (preset, canvas size) and cache. Add a very light noise (≈2%) to prevent banding.
   Solid color and aspect-fill image are the other options.
2. **Screen content**: aspect-fit inside the canvas inset by `padding × H` on all sides, centered.
   Rounded corners `cornerRadius × H`. Soft drop shadow under it: blur ≈ 0.035 × H, offset down ≈ 0.012 × H,
   opacity `shadow × 0.55`. Plus a 1 px inner hairline, white at 12% opacity, for edge definition on dark content.
   When `padding == 0`: fill the canvas (aspect-fit, black bars if needed), no radius, no shadow.
   Use high-quality downscaling (Lanczos or `CIImage` with mipmaps / `samplingLinear` + two-step) — text must stay sharp.
   Cache the shadow and mask images; rebuild only when the target rect changes.
3. **Camera** (when `camera.enabled` and a camera frame exists): height `size × H`.
   `roundedRect` → width = height × 1.5, radius = 0.12 × camera height. `circle` → width = height.
   Position: the chosen corner, `margin × H` from the canvas edges. It overlaps the screen content.
   Aspect-fill crop, centered. Mirror horizontally when `mirrored`. Same shadow as the screen content, scaled down,
   plus a 2 px white border at 20% opacity.
4. No screen frame yet → draw only the background and the camera. Drop camera frames older than 1 s (camera stopped).

Expose the layout math as a pure function (`CanvasLayout`) so it stays testable.

Performance target on M4: 1440p at 60 fps and 4K at 30 fps without dropped ticks. If a tick is still rendering when
the next one fires, skip the tick (never queue up).

### FramePipeline

`DispatchSourceTimer` on a dedicated serial queue with `.userInteractive` QoS, strict leeway. Tick time =
`CMClockGetTime(CMClockGetHostTimeClock())`. `style` guarded by a lock. `start` while running reconfigures.

### PreviewView

Layer-backed `NSView` with `AVSampleBufferDisplayLayer` (`videoGravity = .resizeAspect`), frames enqueued with
"display immediately". Rounded corners 10 pt on the view. Flush and recover when the layer status is `.failed`.
Limit preview to ~30 fps when the pipeline runs at 60.

### MovieRecorder

Two steps, so a crash never loses a recording and the final file has one mixed audio track:

1. **Capture** to a temporary `.mov` next to the output (`.<name>.recording.mov`), `AVAssetWriter` with
   `movieFragmentInterval = 10 s`. Video input: hardware H.264 High (or HEVC), `expectsMediaDataInRealTime`,
   Rec. 709 color properties, bitrate ≈ `width × height × fps × 0.07` bits/s for H.264 (HEVC × 0.6),
   max keyframe interval 2 s. Pixel buffer adaptor. Audio: up to two AAC inputs (system, microphone), 48 kHz,
   stereo for system (160 kbps), mono or as delivered for microphone (128 kbps).
2. **Finalize** in `finish()`: `AVAssetReader` → `AVAssetWriter` to the final `.mp4`. Video samples pass through
   (no re-encode). Audio tracks are mixed into one AAC stereo track with `AVAssetReaderAudioMixOutput`
   (mic at 1.0, system at 0.8). `shouldOptimizeForNetworkUse = true` (fast start). Delete the temporary file.
   With one or zero audio tracks still remux to `.mp4` the same way.

Rules:

- Session starts at the time of the first video frame. Drop audio that arrives before it.
- Never block the callers: appends hop to a private serial queue. If an input is not ready, drop the sample
  (count the drops, log once per second at most).
- Video timestamps must strictly increase; drop a frame that does not.
- Pause/resume: while paused, drop everything. On resume, add the paused duration to a running offset and subtract
  it from all later timestamps (retime audio with `CMSampleBufferCreateCopyWithNewTiming`).
- `duration` = last written video time − start.
- `finish()` with zero video frames throws a clear error and removes the files. `cancel()` removes everything.
- Create the output directory when missing.

### SelfTest

`SelfTest.run(outputURL:)` proves the render and record path without any privacy permission:
generate synthetic frames (a fake "app window" 2940×1912 with moving colored blocks and text drawn with Core Graphics,
and a fake camera frame 1280×720), push them through `LatestFrameBox` → `FramePipeline` (1440p, 30 fps) →
`MovieRecorder` for 3 s, with a synthetic 440 Hz sine as microphone and a 660 Hz sine as system audio
(host-clock timestamps, LPCM sample buffers). Change the style once in the middle (camera corner). Do one
pause/resume of 0.5 s. Then `finish()`, and assert with `AVAsset`: one video track of the canvas size, one audio
track, duration within 2.3–2.8 s. Throw on any mismatch.

## ScreenyUI — export

- `public func runScreenyProApp(dependencies: AppDependencies) -> Never`

`NSApplication` + `AppDelegate` (not the SwiftUI `App` lifecycle), SwiftUI views hosted in AppKit windows.
Regular app (Dock icon) plus an `NSStatusItem`.

### State machine (`RecorderController`, `@MainActor ObservableObject`)

`idle (preview running) → countdown (3-2-1) → recording ⇄ paused → finishing → finished(url) → idle`

- On launch: check permissions. Screen recording is required, camera and microphone are optional.
- In `idle` the capture stream, camera and pipeline run, so the preview is exactly what will be recorded.
- Any settings change applies live (style to `pipeline.style`, capture changes via `start(config)`), debounced ~150 ms
  for sliders.
- `pipeline.onFrame` → preview always; `recorder.appendVideo` while recording.
  `screen.onAudio` → `recorder.appendAudio` while recording; microphone buffers also feed the level meter (RMS → dB).
- `maxPixelSize` for the capture = the screen content rect on the canvas (do not capture more pixels than needed).
- Output file: `~/Movies/ScreenyPro/ScreenyPro 2026-11-13 at 10.45.12.mp4`.
- `onStop` during recording → finish and save what exists, then show the reason.
- Settings (`StyleSettings`, `OutputSettings`, devices, toggles, last source kind) persist in `UserDefaults` as JSON.
- Do not let the Mac sleep while recording (`ProcessInfo.beginActivity`).

### Windows

1. **Main window** (~980×640, min 860×560, dark appearance, unified titlebar).
   - Left: large live preview (16:9, rounded 10 pt, subtle border) on a dark backdrop. Under it one row:
     big red **Record** button (shows `⌘⇧R`), output summary ("1440p · 30 fps · H.264"), microphone level meter.
   - Right: 300 pt inspector, scrollable, grouped sections:
     - **Source** — segmented Display / Window, then a picker list with thumbnails (window: app name + title). Refresh button.
     - **Camera** — on/off, device, shape (rounded / circle), corner picker (2×2 grid), size slider, mirror toggle.
     - **Audio** — microphone device (or None), system audio toggle.
     - **Look** — background swatches (gradient presets rendered as small swatches, plus solid color and image…),
       padding, corner radius, shadow sliders.
     - **Output** — resolution, fps (30/60), codec, "Show cursor", open recordings folder.
   - Permission onboarding replaces the preview when screen recording is not granted: short explanation,
     "Grant access" button, "Open System Settings" button, note that macOS needs an app restart after granting,
     with a "Quit and reopen" button.
2. **Recording HUD** — small floating `NSPanel` (non-activating, all Spaces, above normal windows), bottom-center of
   the main screen, draggable: red dot + elapsed time, Pause/Resume, Stop, Discard (with confirm).
   The main window hides when recording starts and returns after.
   Own windows are excluded from display capture by the capture module, so the HUD is never recorded.
3. **Countdown** — borderless transparent overlay centered on the recorded display: large 3-2-1. `Esc` cancels.
4. **Finished sheet** in the main window — video thumbnail (`AVAssetImageGenerator`), duration, file size, buttons:
   Play (QuickLook / default player), Show in Finder, Copy file, Delete. A disabled "Copy share link — coming soon"
   is **not** wanted: leave cloud out completely.
5. **Status item** — idle: menu (Start Recording, Open ScreenyPro, Open Recordings Folder, Quit).
   Recording: title shows elapsed time in red; click stops.

Global hotkeys (Carbon `RegisterEventHotKey`, no accessibility permission): `⌘⇧R` start/stop, `⌘⇧P` pause/resume.

### Visual design

- Dark, quiet, tool-like. Like a pro video utility, not a marketing page. System font (SF), SF Symbols.
- Window background `#16171B`, inspector panels `#1E2026`, hairlines white 8%, primary text white 92%,
  secondary white 55%. Accent: violet `#8E5CF6` (selection, sliders, focus). Record red `#FF453A`.
- Section headers: 11 pt semibold uppercase, secondary color, 0.6 pt tracking. Controls 13 pt.
- 8 pt spacing grid, 8 pt corner radius on controls, 10–12 pt on cards.
- Selected swatch/corner/thumbnail: 2 pt accent ring with 2 pt gap.
- Motion: only short (150–200 ms) ease-out transitions for state changes. No decorative animation.

## Build, run, check

```
swift build --target <YourTarget> --scratch-path .build-<yourname>   # while developing a module
scripts/build-app.sh            # full app → build/ScreenyPro.app
build/ScreenyPro.app/Contents/MacOS/ScreenyPro --selftest /tmp/x.mp4
```

## Portrait (9:16) mode for Reels

Second canvas format next to 16:9. `OutputSettings.format == .portrait` → `OutputSettings.canvasSize` is
1080×1920 / 1440×2560 / 2160×3840. The pipeline and recorder already take any canvas size.
A canvas is portrait when `height > width`.

Layout comes from `PortraitLayout.slots` in Core (the single source of truth for compositor and UI):

- Background as before, full canvas.
- **Screen card** in the top slot: aspect-fit, centered in the slot, rounded corners `slots.cornerRadius`,
  same shadow and hairline as in landscape (sizes relative to canvas WIDTH instead of height).
- **Camera card** in the bottom slot: aspect-fill crop centered (bias the crop slightly upward so a face is not cut:
  keep the top 8% margin of the source when cropping vertically is not needed; when cropping horizontally just center),
  same radius, same shadow, 2 px border at 20% white. Mirrored when `camera.mirrored`.
  `camera.corner/shape/size/margin` are ignored.
- `padding == 0`: slots are edge to edge, no radius, no shadow, no gap.
- Camera off or no camera frame: screen slot = whole canvas inset by the padding.

The whole display is too small in a 9:16 frame, so the user records a **window** or an **area of a display**:
`CaptureConfig.cropRect` (display points, top-left origin) → `SCStreamConfiguration.sourceRect`.
The UI offers an area picker (drag a rectangle on the display; in portrait the aspect ratio is locked to the
screen slot's aspect so the area fills the slot exactly) and shows a thin outline around the chosen area while
idle and recording (own windows are excluded from display capture, so the outline is never recorded).
