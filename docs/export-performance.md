# Recording Studio export performance

Studio accelerates the screen's motion-blur pass with Metal. `RecordingStudioExporter` still computes the existing viewport geometry, 60 fps output cadence, one-frame shutter, adaptive 1–24 sample count, and running-average sample weights. It does not reduce the blur samples, output resolution, bitrate, or frame rate to gain speed.

## Rendering policy

- Magnified motion-blur frames use Metal with the original shutter rectangles.
- Reduced frames use Metal when the shutter has at least 8 samples. Lighter blur during reduction stays on Core Graphics: numerical comparisons exposed larger spatial-filter differences in that case.
- Settled frames retain their single Core Graphics draw.
- If Metal initialization, buffer mapping, geometry validation, or rendering fails, the export continues through Core Graphics. A GPU failure disables further GPU attempts for that export.

`StudioMotionBlur.metal` combines the shutter samples in one compute pass, using cubic reconstruction for magnification and scale-aware Lanczos reconstruction for reduction. For large reductions, one Metal Performance Shaders Lanczos prepass bounds the filter footprint while retaining up to twice the required resolution. The cached backdrop and rounded-card mask use the same Core Graphics drawing paths as the original compositor.

Reader and writer buffers are Metal-compatible IOSurfaces. GPU completion precedes the CPU lock, after which the existing pointer, press effects, camera, keystroke, subtitle, and karaoke rendering runs unchanged. Core Video texture wrappers remain alive until the command buffer completes, as required by [Apple's texture-cache documentation](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)). Resources belong to one compositor/export, with one command buffer in flight and one reusable reduction texture; there is no global image cache or intermediate canvas per shutter sample. Per-frame temporary objects drain inside an autorelease pool.

Metal and Core Graphics spatial filtering are **not pixel-identical**. Keeping temporal sampling unchanged preserves the blur algorithm, but representative moving footage still needs visual comparison, especially small text during reductions and the transition between settled and moving frames.

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
  scripts/benchmark-studio-motion-blur.swift \
  -o /tmp/screendrop-motion-blur-benchmark-bin

/tmp/screendrop-motion-blur-benchmark-bin
```

The harness compiles the actual shader source, exercises 2/8/24-sample cases at 1080p and 4K with 1×/2×/4× input sizes, and reports Core Graphics fallback cases separately. For accelerated fixtures it asserts RGB mean absolute error below 4/255 and PSNR above 31 dB against the original compositor's screen pass. These are regression checks, not a perceptual-quality guarantee. PNG pairs are saved under `/tmp/screendrop-motion-blur-benchmark` for inspection.

It also writes and decodes six frames each through H.264 and HEVC, exercising the writer's pixel-buffer pool, GPU rendering, a CPU-drawn overlay, and a Metal-compatible reader. It checks that the overlay survives in the correct position and that invalid rectangles are rejected. Use `--encode-only` to rerun just these integration checks. The harness does not launch Screendrop or access user recordings.

## Compare complete exports

In **Edit Scheme → Run → Arguments → Environment Variables**, set:

| Variable | Value | Purpose |
| --- | --- | --- |
| `SCREENDROP_EXPORT_BYPASS_CACHE` | `1` | Render on every Export/Share instead of reusing the session's flattened deliverable. |
| `SCREENDROP_EXPORT_RENDERER` | `cpu` | Force the original Core Graphics renderer for a baseline. Unset for automatic Metal selection. |

Run the same recording, edits, codec, resolution, and quality once with the CPU override and once without it, keeping cache bypass enabled for both. Keep the baseline export under a separate filename. Remove both variables after measuring so normal render reuse resumes.

Filter the Xcode console or Console.app by `StudioExport`. The log reports:

- `frames` and `Metal blur frames`: how much of the export actually used the accelerated path.
- `renderSeconds`: cumulative screen composition plus existing overlays, including first-use GPU setup.
- `writerWaitSeconds`: time waiting for the encoder input to accept a frame. Encoding also proceeds concurrently, so this is not total encoding time.
- `totalSeconds`: successful exporter duration including preparation, decoding, rendering, audio work, and writer finalization. It excludes the subsequent save/copy to the user's destination or cloud upload.

Compare zooms and pans, small text, rounded edges, crops/reframing, camera placement, cursor effects, subtitles, audio synchronization, and cancellation on representative projects. A successful build and the isolated checks do not establish complete-export performance or visual parity on those projects.
