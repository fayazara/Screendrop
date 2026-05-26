# Screendrop

> **Beta** -- Screendrop is under active development. Expect rough edges, missing features, and breaking changes between releases. Feedback and bug reports are welcome via [GitHub Issues](https://github.com/fayazara/Screendrop/issues).

Screendrop is a native macOS menu bar app for taking screenshots, recording the screen, annotating captures, and sharing them when needed. It is built for a fast local workflow: capture something, preview it immediately, mark it up, save it, copy it, or upload it from the same floating preview.

The app is designed to stay out of the way. It runs as a menu bar utility with no main window, keeps a local capture history, and only talks to the network when you explicitly configure cloud sharing or check for updates.

## What It Does

- Capture the full screen, a selected window, or a selected area.
- Record the full screen, a selected window, or a selected area.
- Preview recent captures in a floating stack.
- Annotate screenshots with shapes, arrows, freehand drawing, text, numbered markers, blur, pixelate, and background styling.
- Trim and compress screen recordings.
- Save captures automatically to your chosen folder.
- Copy screenshots or recordings to the clipboard.
- Keep a local history of screenshots and recordings.
- Upload captures to your own Cloudflare-backed sharing setup.
- Check for app updates with Sparkle.

## Capture Workflow

Screendrop is controlled from the menu bar.

Default screenshot hotkeys:

- `Option + 1`: capture full screen
- `Option + 2`: capture window
- `Option + 3`: capture area

After a capture, Screendrop imports the file into its local history and shows a floating preview. From there you can copy, save, delete, annotate, edit a recording, or upload the capture if cloud sharing is configured.

Screenshots are captured at native display resolution. Annotation coordinates are stored independently from pixel size, then rendered onto the final image at export time.

## Recording Workflow

Screen recording supports display, area, and window sources. Screendrop can also show recording overlays such as mouse indicators and key press captions. Finished recordings are added to history and can be edited or compressed from the built-in video editor.

Video compression uses FFmpeg when available. Install it with Homebrew if you want conversion and compression features:

```bash
brew install ffmpeg
```

## Cloud Sharing

Screendrop does not require a paid backend. Cloud sharing is designed around a small Cloudflare setup that can run on the free tier:

- Cloudflare R2 stores the actual screenshot or recording files.
- A Cloudflare Worker creates and serves share links.
- Cloudflare D1 stores lightweight metadata for each uploaded capture.
- Screendrop uploads directly from your Mac to your own R2 bucket.

The companion Worker lives here:

[github.com/fayazara/screendrop-worker](https://github.com/fayazara/screendrop-worker)

### How Uploads Work

When you upload a capture, Screendrop does two things:

1. It uploads the file directly to your R2 bucket using the S3-compatible R2 API.
2. It calls the Worker's `/api/register` endpoint with the R2 object key and metadata such as filename, content type, size, dimensions, and media type.

The Worker validates the upload token, stores the metadata in D1, and returns a short share URL. Screendrop stores that URL in local history so you can copy it again later.

This keeps large files out of the Worker request path. The Worker only handles metadata and public link routing; the file bytes go directly to R2.

### Cloud Setup

In Cloudflare:

1. Create an R2 bucket.
2. Generate R2 S3 API credentials with read/write access.
3. Deploy the Screendrop Worker.
4. Set the Worker upload token:

```bash
wrangler secret put UPLOAD_TOKEN
```

In Screendrop, open Settings -> Cloud and enter:

- R2 endpoint, for example `https://<account_id>.r2.cloudflarestorage.com`
- Bucket name
- Region, usually `auto` for R2
- R2 access key ID
- R2 secret access key
- Optional public URL base if you use a custom R2 public domain
- Worker URL
- Upload token

Use the built-in connection checks to verify both R2 and the Worker before uploading captures.

## Privacy Model

Screendrop is local-first.

- Captures are stored on your Mac by default.
- R2 credentials and the upload token are stored in Keychain.
- Bucket names, endpoints, and Worker URLs are stored in app preferences.
- Cloud uploads only happen when you use the upload action.
- The app does not depend on a central Screendrop server.

## Building Locally

Requirements:

- macOS 26.4 or newer
- Xcode 26.4 beta toolchain
- Sparkle is resolved through Swift Package Manager

Build from the command line:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Screendrop.xcodeproj \
  -scheme Screendrop \
  -configuration Debug \
  -destination "platform=macOS"
```

## Releasing

Screendrop includes a small Go release helper adapted from the Kaze release flow:

```bash
go run ./cmd/screendrop-release
```

It expects an exported `Screendrop.app` in `~/Downloads`, creates a DMG, signs it for Sparkle, updates `appcast.xml`, pushes the appcast commit, and creates a GitHub release.

## License

License information will be added before the first public release.
