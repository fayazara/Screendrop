# Recording Studio export performance

Studio accelerates the screen's motion-blur pass with Metal. Export Options offers independent **30 / 60 fps** and **Motion blur** controls. Defaults remain **60 fps with blur enabled**, preserving the existing viewport geometry, one-frame shutter, adaptive 1–24 sample count, and running-average sample weights.

## Frame rate and motion blur

`RecordingExportTiming` supplies the actual output clock, frame count, and shutter samples to `RecordingStudioExporter`; the encoder's expected-frame-rate hint uses the same value. Writer timestamps use integer frame ticks to avoid floating-point conversion jitter. A one-minute export produces 1,800 frames at 30 fps or 3,600 at 60 fps. Duration, clip speed, audio timing, output resolution, and bitrate selection are independent of this choice. Capture and interactive Studio preview remain at their existing cadence.

- **Blur enabled:** the shutter spans one output frame, about 16.7 ms at 60 fps or 33.3 ms at 30 fps. The existing adaptive sampler can therefore choose more samples per moving frame at 30 fps. The Metal/Core Graphics selection policy remains the same.
- **Blur disabled:** the screen is drawn once at the exact output frame time, without shutter sampling. Zooms, pans, cursor effects, camera, and captions continue to animate at the selected output rate. This does not remove motion blur already baked into source footage.

Both choices are stored in the project's export settings, inherited by Share and on-demand Library rendering, and remembered for new recordings after confirmation. Missing settings fields decode as 60 fps and blur enabled. Equality treats omitted and explicit defaults identically, so old render stamps remain valid when the rendered settings are unchanged. A different frame rate or blur choice invalidates cached deliverables, including the container-only reuse path.

30 fps halves output-frame submissions, not every stage of the export. Source decoding, audio processing, and file delivery still do work; speedups for these options require measurement on representative recordings. With the existing bitrate policy, 30 fps does not inherently halve the file size.

## Rendering policy

- Magnified motion-blur frames use Metal with the original shutter rectangles.
- Reduced frames use Metal when the shutter has at least 8 samples. Lighter blur during reduction stays on Core Graphics: numerical comparisons exposed larger spatial-filter differences in that case.
- Settled frames retain their single Core Graphics draw. When the decoded source buffer and viewport rectangle repeat, subsequent frames reuse those exact screen/backdrop pixels.
- If Metal initialization, buffer mapping, geometry validation, or rendering fails, the export continues through Core Graphics. A GPU failure disables further GPU attempts for that export.

`StudioMotionBlur.metal` combines the shutter samples in one compute pass, using cubic reconstruction for magnification and scale-aware Lanczos reconstruction for reduction. For large reductions, one Metal Performance Shaders Lanczos prepass bounds the filter footprint while retaining up to twice the required resolution. The cached backdrop and rounded-card mask use the same Core Graphics drawing paths as the original compositor.

Reader and writer buffers are Metal-compatible IOSurfaces. GPU completion precedes the CPU lock, after which the existing pointer, press effects, camera, keystroke, subtitle, and karaoke rendering runs unchanged. Core Video texture wrappers remain alive until the command buffer completes, as required by [Apple's texture-cache documentation](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)). Resources belong to one compositor/export, with one command buffer in flight and one reusable reduction texture; there is no global image cache or intermediate canvas per shutter sample. Per-frame temporary objects drain inside an autorelease pool.

Metal and Core Graphics spatial filtering are **not pixel-identical**. Keeping temporal sampling unchanged preserves the blur algorithm, but representative moving footage still needs visual comparison, especially small text during reductions and the transition between settled and moving frames.

## Settled screen reuse

Sparse screen recordings often hold one decoded frame for several output ticks. `StudioScreenLayerCache` retains one byte-exact snapshot of the settled screen and backdrop, taken **before** drawing the cursor, press effects, camera, keystrokes, subtitles, or karaoke. Those overlays still render on every output tick at the selected 30 or 60 fps. A different source buffer, viewport rectangle, output size, or a motion-blurred frame prevents reuse.

The exporter only takes a snapshot when the next tick can reuse it. This avoids an extra copy on continuously changing footage and moving viewports. Snapshots have a hard **64 MiB** limit; larger canvases render normally. The cache also retains its decoded source buffer to prevent a recycled buffer from producing a false hit. Both belong to the current export and are released with the compositor. This optimization does not alter filtering, blur samples, frame rate, or encoding settings; its complete-export speedup has not yet been measured on representative recordings.

## Measured blur-pass timings

Measured on an Apple M4 Pro, September 5, 2026. Synthetic zoom/pan, rounded clipping, text, one-pixel lines, and colored edges; **24 shutter samples**, four timed iterations after setup/warmup. Times include GPU completion and any reduction prepass.

| Source → output | Core Graphics | Metal | Blur-pass speedup |
| --- | ---: | ---: | ---: |
| 1920×1080 → 1920×1080 | 273.17 ms | 8.03 ms | 34.02× |
| 3840×2160 → 1920×1080 | 265.97 ms | 20.45 ms | 13.00× |
| 7680×4320 → 1920×1080 | 365.05 ms | 36.83 ms | 9.91× |
| 3840×2160 → 3840×2160 | 1087.57 ms | 16.67 ms | 65.24× |

These are **not complete-export speedups**. The harness excludes source decoding, pipeline creation, timeline evaluation, overlays, encoding, audio, and final file delivery. The CPU reference also reuses a prepared source CGImage. Codec throughput, the fraction of frames with blur, and fallback frames limit the overall improvement.

## Standalone check

From the repository root, with Xcode selected and access to the Mac's GPU:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
  -module-cache-path /tmp/screendrop-metal-module-cache -parse-as-library \
  Screendrop/StudioMetalScreenRenderer.swift \
  Screendrop/StudioScreenLayerCache.swift \
  scripts/benchmark-studio-motion-blur.swift \
  -o /tmp/screendrop-motion-blur-benchmark-bin

/tmp/screendrop-motion-blur-benchmark-bin
```

The harness compiles the actual shader source, exercises 2/8/24-sample cases at 1080p and 4K with 1×/2×/4× input sizes, and reports Core Graphics fallback cases separately. For accelerated fixtures it asserts RGB mean absolute error below 4/255 and PSNR above 31 dB against the original compositor's screen pass. These are regression checks, not a perceptual-quality guarantee. PNG pairs are saved under `/tmp/screendrop-motion-blur-benchmark` for inspection.

It also writes and decodes six frames each through H.264 and HEVC, exercising the writer's pixel-buffer pool, GPU rendering, a settled Core Graphics frame, screen-layer reuse, a moving CPU-drawn overlay, and a Metal-compatible reader. It checks that the overlay survives in the correct position, does not remain at its old position, and that invalid rectangles are rejected. Use `--encode-only` to rerun just these integration checks. The harness does not launch Screendrop or access user recordings. The [editor resource checks](editor-performance.md#standalone-checks) additionally verify byte-identical screen reuse, overlay isolation, and the snapshot budget.

## Compare complete exports

For the frame-rate/blur options, compare the same saved recording in all four combinations: 30/off, 30/on, 60/off, and 60/on, keeping resolution, quality, and codec fixed. Check smoothness, blur trails, captions, clip boundaries, and audio synchronization in the resulting files; the interactive preview does not simulate the export's blur or frame-rate selection.

In **Edit Scheme → Run → Arguments → Environment Variables**, set:

| Variable | Value | Purpose |
| --- | --- | --- |
| `SCREENDROP_EXPORT_BYPASS_CACHE` | `1` | Render on every Export/Share instead of reusing the session's flattened deliverable. |
| `SCREENDROP_EXPORT_RENDERER` | `cpu` | Force the original Core Graphics renderer for a baseline. Unset for automatic Metal selection. |
| `SCREENDROP_EXPORT_BYPASS_SCREEN_CACHE` | `1` | Disable settled screen-layer reuse while retaining the selected renderer. |

Run the same recording, edits, codec, resolution, and quality once with the CPU override and once without it, keeping deliverable cache bypass enabled for both. To isolate screen-layer reuse, keep the renderer setting unchanged and toggle only `SCREENDROP_EXPORT_BYPASS_SCREEN_CACHE`. To reproduce the original rendering path, set both the CPU override and screen-cache bypass. Keep baseline exports under separate filenames. Remove the overrides after measuring so normal render reuse resumes.

Filter the Xcode console or Console.app by `StudioExport`. The log reports:

- `frames` and `Metal blur frames`: how much of the export actually used the accelerated path.
- `fps` and `motionBlur`: the selected output cadence and shutter-sampling policy.
- `reusedScreenFrames`: output ticks that reused settled screen/backdrop pixels; overlays still rendered.
- `renderSeconds`: cumulative screen composition plus existing overlays, including first-use GPU setup.
- `writerWaitSeconds`: time waiting for the encoder input to accept a frame. Encoding also proceeds concurrently, so this is not total encoding time.
- `totalSeconds`: successful exporter duration including preparation, decoding, rendering, audio work, and writer finalization. It excludes the subsequent save/copy to the user's destination or cloud upload.

Compare zooms and pans, small text, rounded edges, crops/reframing, camera placement, cursor effects, subtitles, audio synchronization, and cancellation on representative projects. A successful build and the isolated checks do not establish complete-export performance or visual parity on those projects.

## Frame-rate and blur option checks

This standalone harness uses the production settings decoder and timing/sampling policy. It checks legacy settings, all four option combinations, cached-settings equality, the unchanged 60 fps shutter samples on analytical fixtures, and blur-off's single sample. It also writes and decodes synthetic H.264 and HEVC movies to verify frame counts, timestamps, nominal frame rates, and one-second playback duration. It does not launch Screendrop, exercise the complete Studio composition, or claim end-to-end export performance.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
  -module-cache-path /tmp/screendrop-metal-module-cache -parse-as-library \
  Screendrop/VideoCompressionModels.swift Screendrop/RecordingExportTiming.swift \
  scripts/check-recording-export-options.swift -o /tmp/screendrop-export-options-check
/tmp/screendrop-export-options-check
```
