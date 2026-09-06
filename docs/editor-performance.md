# Editor resource lifetime and performance

Closing an editor explicitly releases its working image data, rather than relying on SwiftUI to destroy the scene immediately. These are source-level retention and repeated-work fixes; they are not a claim that every allocation reported by Instruments is a leak or that the app has a measured idle-memory target.

## Image budgets

| Cache | Decoded-pixel budget | Lifetime |
| --- | --- | --- |
| Wallpaper thumbnails/previews | 32 MiB, at most 48 images | Shared by visible wallpaper views; last consumer releases all entries. |
| Wallpapers used by the renderer | 64 MiB, at most 4 images | Shared by active screenshot/recording editors and in-progress loads. |
| Processed blur/pixelation previews | 32 MiB, at most 32 crops per canvas | Released when the canvas is dismantled or the source changes. |

`BoundedCGImageCache` enforces both byte and count limits with LRU eviction. Images larger than the budget can still render at the existing resolution, but are not cached. A generation token prevents an old decode from refilling a cache after its last consumer closes. Wallpaper preview decoding runs serially, with duplicate requests coalesced; obsolete queued decodes are skipped. The budgets apply to cache-owned pixels, not the entire app's memory: visible images, current decoding, AVFoundation, and Core Image have their own allocations.

Redaction preview keys include the sampled bounds, density, and blur/pixelation kind. Source-image identity and display geometry invalidate the cache. Selecting a shape or repainting unrelated UI reuses the exact processed image. Export still samples the composed context and processes every redaction, preserving overlapping-redaction behavior.

## Cancellation and close behavior

- Screenshot editor closure cancels its tracked Smart Redact task and Vision request. Results from a replaced or closed document are ignored, and the task does not hold the editor alive while awaiting recognition.
- Recording Studio saves its loaded draft before clearing state. It cancels background tasks and active sharing, removes playback observers and player items, clears timeline thumbnails, assets, undo history, and derived timelines, and releases the window's model reference.
- Loading media and restoring saved audio check cancellation/teardown after suspension points, so late work cannot recreate a closed player's resources.
- Thumbnail task cancellation reaches `AVAssetImageGenerator`; released stores ignore late completions. Core Image caches are cleared after screenshot rendering and canvas teardown.

## Standalone checks

These checks use synthetic data and do not launch Screendrop. Run from the repository root with Xcode selected:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
  -module-cache-path /tmp/screendrop-metal-module-cache -parse-as-library \
  Screendrop/BoundedCGImageCache.swift Screendrop/AnnoRedactionPreviewCache.swift \
  Screendrop/StudioScreenLayerCache.swift scripts/check-editor-resources.swift \
  -o /tmp/screendrop-editor-resources-check
/tmp/screendrop-editor-resources-check
```

This checks budgets, eviction, overlapping consumers, last-close release, stale decode rejection, redaction invalidation, and exact screen-layer copying with moving overlays and different row strides.

First run the [export harness](export-performance.md#standalone-check) with `--encode-only` to create the synthetic thumbnail movie. Then, with access to the Mac's Vision/media services:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
  -module-cache-path /tmp/screendrop-metal-module-cache -parse-as-library \
  Screendrop/SmartRedactionRecognizer.swift Screendrop/RecordingTimelineThumbnails.swift \
  scripts/check-editor-cancellation.swift -o /tmp/screendrop-editor-cancellation-check
/tmp/screendrop-editor-cancellation-check
```

This checks that normal OCR still recognizes an email, cancellation returns no regions, and thumbnails disappear on release without returning after late completions. Full app validation still needs repeated editor open/close cycles and representative exports under Instruments, including closing during OCR or media loading and keeping two editors open together.
