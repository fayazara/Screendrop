# AGENTS.md

## Project overview

OpenShot is a native macOS screenshot tool. It runs as a menu-bar-only app (`LSUIElement = YES`, activation policy `.accessory`) with no main window. Built with SwiftUI + AppKit, single Xcode target, no SPM dependencies, no tests.

**Deployment target:** macOS 26.4 (Xcode 26.4 / Tahoe beta SDK).
**Bundle ID:** `com.fayazahmed.OpenShot`

## Build

Use `xcodebuild` from the command line. The project requires the Xcode 26.4 beta toolchain:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project OpenShot.xcodeproj \
  -scheme OpenShot \
  -configuration Debug \
  -destination "platform=macOS" \
  2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -20
```

There are two shared schemes (`OpenShot` and `OpenShot Dev`) — both build the same target with Debug config. Use `OpenShot` unless told otherwise.

No test target exists. Build success is the only automated verification.

## Swift concurrency settings

The project uses **strict concurrency** settings that are easy to violate:

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every type is implicitly `@MainActor` unless explicitly opted out.
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` — imports in one file do not leak to other files.

When adding new types, assume `@MainActor` isolation by default. If a type must be `Sendable` or `nonisolated`, mark it explicitly.

## Architecture

All source is in `OpenShot/` (flat, no subdirectories). Key flow:

1. **App entry** — `OpenShotApp.swift`: `@main` App struct. Creates a `MenuBarExtra`, a Settings window, and an annotation editor `WindowGroup`.
2. **Hotkeys** — `HotkeyManager.swift`: Registers global Carbon hotkeys (Option+1/2/3) at launch via `AppDelegate`.
3. **Capture** — `CaptureCoordinator.swift` → `ScreenshotManager.swift`: Fullscreen uses `ScreenCaptureKit`; window/area use `/usr/sbin/screencapture` CLI.
4. **Preview** — `PreviewPanelPresenter.swift` + `PreviewWindowView.swift`: Borderless floating `NSPanel` showing a screenshot stack. Uses `ScreenshotPreviewStack` (an `@Observable` model).
5. **Annotation** — `AnnotationEditorWindow.swift` + `AnnotationEditorModel.swift` + `AnnotationCanvas.swift`: Full annotation editor with tools (rectangle, ellipse, arrow, freehand, text, numbered circles, pixelate, blur). All coordinates are normalized (0..1) relative to the image.
6. **Rendering** — `AnnotationRenderer.swift`: Composites annotations onto the source image at full pixel resolution using Core Graphics.
7. **Preferences** — `OpenShotPreferences.swift` + `SettingsView.swift`: `UserDefaults`-backed settings (auto-save, auto-copy, auto-compress, export directory).

### Singletons

Most managers are `static let shared` singletons: `ScreenshotManager`, `CaptureCoordinator`, `HotkeyManager`, `PreviewPanelPresenter`, `ScreenshotPreviewStack`, `PreviewWindowPlacement`, `PreviewWindowCaptureExclusion`. Follow this pattern for new services.

### Annotation coordinate system

All annotation positions/sizes are normalized to `[0, 1]` relative to the source image dimensions. Pixel conversion happens only in `AnnotationRenderer` at export time and in the canvas view for display. Do not use pixel coordinates in the model layer.

## Conventions

- **No SPM packages or external dependencies.** The project uses only Apple frameworks (SwiftUI, AppKit, ScreenCaptureKit, CoreGraphics, CoreImage, ImageIO, Carbon).
- **`@Observable` macro** (Observation framework) is used for state — not `ObservableObject`/`@Published`.
- **App sandbox is disabled** (`ENABLE_APP_SANDBOX = NO`) — the app needs screen capture permissions and direct filesystem access.
- Screenshots are saved as lossless PNG to `NSTemporaryDirectory()` first, then optionally compressed to JPEG on export.

## Commits

Make atomic commits. Each commit should represent exactly one logical change (e.g. one feature, one bug fix, one refactor). Do not bundle unrelated changes into a single commit. If a task touches multiple concerns, split it into separate commits. Verify the build passes before committing.

## Entitlements / permissions

- Screen recording permission (`NSScreenCaptureUsageDescription` in Info.plist) is required.
- Hardened runtime is enabled.
- No App Sandbox — do not add sandbox entitlements.
