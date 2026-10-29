# AGENTS.md

## Project overview

Screendrop is a native macOS screenshot and screen recording tool. Its Library window opens on normal launch; login launches remain in the menu bar (`LSUIElement = YES`). `AppActivationPolicy` uses `.regular` while Library, Settings, or editor windows are open, and returns to `.accessory` when they close. Built with SwiftUI + AppKit and no test target.

**Deployment target:** macOS 26.4 (Xcode 26.4 / Tahoe beta SDK).
**Bundle ID:** `com.fayazahmed.Screendrop`

## Build

Use `xcodebuild` from the command line. The project requires the Xcode 26.4 beta toolchain:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Screendrop.xcodeproj \
  -scheme Screendrop \
  -configuration Debug \
  -destination "platform=macOS" \
  2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -20
```

There are two shared schemes, both building the same target:

- `Screendrop` - `Debug` configuration, produces `Screendrop.app` (`com.fayazahmed.Screendrop`).
- `Screendrop Dev` - `Debug Dev` configuration, produces `Screendrop Dev.app` (`com.fayazahmed.Screendrop.dev`) in `Build/Products/Debug Dev`. It runs alongside an installed release build and keeps its own permissions, so use it for running and testing the app.

`-configuration` overrides the scheme's own, so build the Dev scheme with `-configuration "Debug Dev"` (or leave the flag off). With `-configuration Debug` it quietly builds `Screendrop.app` instead and leaves `Screendrop Dev.app` stale.

No test target exists. Build success is the only automated verification.

## Swift concurrency settings

The project uses **strict concurrency** settings that are easy to violate:

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` - every type is implicitly `@MainActor` unless explicitly opted out.
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` - imports in one file do not leak to other files.

When adding new types, assume `@MainActor` isolation by default. If a type must be `Sendable` or `nonisolated`, mark it explicitly.

## Architecture

All source is in `Screendrop/` (flat, no subdirectories). Key flow:

1. **App entry** - `ScreendropApp.swift`: `@main` App struct. Creates a `MenuBarExtra`, a Settings window, and an annotation editor `WindowGroup`.
2. **Hotkeys** - `HotkeyManager.swift`: Registers global Carbon hotkeys (Option+1/2/3) at launch via `AppDelegate`.
3. **Capture** - `CaptureCoordinator.swift` → `ScreenshotManager.swift`: Fullscreen uses `ScreenCaptureKit`; window/area use `/usr/sbin/screencapture` CLI.
4. **Capture shelf** - `CaptureShelfPresenter.swift` + `CaptureShelfView.swift` + `CaptureShelfCard.swift`: a borderless, card-wide `NSPanel` against the docked screen edge showing recent captures. `CaptureShelf` (an `@Observable` model) owns the cards and their actions; tucking slides them out through the edge and leaves a handle.
5. **Annotation** - `AnnotationEditorWindow.swift` + `AnnotationEditorModel.swift` + `AnnotationCanvas.swift`: Full annotation editor with tools (rectangle, ellipse, arrow, freehand, text, numbered circles, pixelate, blur). All coordinates are normalized (0..1) relative to the image.
6. **Rendering** - `AnnotationRenderer.swift`: Composites annotations onto the source image at full pixel resolution using Core Graphics.
7. **Preferences** - `ScreendropPreferences.swift` + `SettingsView.swift`: `UserDefaults`-backed settings (auto-save, auto-copy, auto-compress, export directory).
8. **Library** - `CaptureLibraryView.swift` + `CaptureLibraryModel.swift`: Single native sidebar/detail/inspector scene. `CaptureLibraryCollection.swift` reuses AppKit cells for grid/list layouts; `CaptureLibraryThumbnails.swift` bounds decoded image memory and concurrency. The model merges History metadata with recording packages by standardized package path. Existing capture storage and editable sidecars remain authoritative. `CaptureLibraryActions.swift` handles batch operations and prevents trashing captures while their editors are open.
9. **Library index** - `CaptureLibraryIndex.swift` + `CaptureLibraryAnalyzer.swift`: background, on-device analysis of every capture (Vision OCR with line boxes, a feature print for Similar, and a Foundation Models category/title/keywords, falling back to `CaptureCategoryRules`). One JSON file per capture lives in `Application Support/Screendrop/Library Index`, keyed by a hash of the item ID and invalidated by `thumbnailKey`; bump `CaptureAnalysis.currentVersion` to re-index. Similar compares feature prints in `Feature Prints.pack`, a memory-mapped, append-only copy of the per-capture `.print` archives (which stay authoritative). Work runs in two passes: `read` (OCR, feature print, rules category) for every capture, then `sort` (the model) for captures made after `ScreendropPreferences.libraryAutoSortSince`, or for all of them once the user opts in (`librarySortExisting`). `libraryAnalyzeCaptures` is the master switch. `CaptureLibrarySearch.swift` folds and matches the search text. `CaptureSource.swift` records the app a capture came from (stored in history.json and the recording manifest).

10. **Agent (MCP) server** - `AgentRelay.swift` + `AgentServer.swift` + `AgentTools.swift` + `AgentToolHandlers.swift` + `AgentProjects.swift`: lets MCP clients (Claude Code, Codex, ...) edit and export recordings. Agents launch the app binary with `--mcp` (`ScreendropMain` branches before SwiftUI starts); that relay copies newline-delimited JSON-RPC between stdio and a Unix socket in `Application Support/Screendrop` (`agent.sock`, or `agent-dev.sock` for the Dev build), opening the app in the background if needed. `AgentServer` speaks MCP over the socket on the main actor. Edits always go through a `RecordingStudioModel`: the open Studio window's model when there is one, otherwise a windowless one (`isAgentSession`) that a window takes over when it opens. Most edits transform `editDocument` as JSON and call `applyAgentDocument` inside `performAgentEdit`, which makes each one a single undo step (socket-driven edits get no UI event to close an undo group). Tool descriptions are the agent's only documentation; keep them accurate when model fields change. Toggle: `ScreendropPreferences.agentServerEnabled` (Settings → MCP, `SettingsMCPPane.swift`).

### Singletons

Most managers are `static let shared` singletons: `ScreenshotManager`, `CaptureCoordinator`, `HotkeyManager`, `CaptureShelfPresenter`, `CaptureShelf`, `PreviewWindowCaptureExclusion`. Follow this pattern for new services.

### Annotation coordinate system

All annotation positions/sizes are normalized to `[0, 1]` relative to the source image dimensions. Pixel conversion happens only in `AnnotationRenderer` at export time and in the canvas view for display. Do not use pixel coordinates in the model layer.

### Memory

Activity Monitor's figure is the heap's high-water mark: malloc keeps the pages a burst of small allocations leaves behind, and `malloc_zone_pressure_relief` returns nothing. Keep long-lived data in few allocations (one string per capture, not one per OCR line), map large read-only data from disk, and avoid `URL.resourceValues` on URLs that are kept (the values stay cached on them). `MallocLargeCache=0` is set through `LSEnvironment` in Info.plist and in the schemes.

## Conventions

- **No SPM packages or external dependencies.** The project uses only Apple frameworks (SwiftUI, AppKit, ScreenCaptureKit, CoreGraphics, CoreImage, ImageIO, Carbon).
- **`@Observable` macro** (Observation framework) is used for state - not `ObservableObject`/`@Published`.
- **App sandbox is disabled** (`ENABLE_APP_SANDBOX = NO`) - the app needs screen capture permissions and direct filesystem access.
- Screenshots are saved as lossless PNG to `NSTemporaryDirectory()` first, then optionally compressed to JPEG on export.

## Commits

Make atomic commits. Each commit should represent exactly one logical change (e.g. one feature, one bug fix, one refactor). Do not bundle unrelated changes into a single commit. If a task touches multiple concerns, split it into separate commits. Verify the build passes before committing.

## Entitlements / permissions

- Screen recording permission (`NSScreenCaptureUsageDescription` in Info.plist) is required.
- Hardened runtime is enabled.
- No App Sandbox - do not add sandbox entitlements.
