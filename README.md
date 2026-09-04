# Screendrop

A beautiful screenshot + screen recording + Loom alternative - all native, self hostable and free.

<p>
  <a href="https://github.com/fayazara/Screendrop/releases/latest/download/Screendrop.dmg">
    <img src="download-button.png" alt="Download the latest version of Screendrop" width="220">
  </a>
</p>

<img width="3494" height="2206" alt="Screendrop_2026-08-17-09-17-20-compressed-550B05" src="https://github.com/user-attachments/assets/e4c2ef6c-97af-4ad4-8885-442c7fbb07b7" />



<br />
<br />



> [!IMPORTANT]
> Screendrop is under active development. Expect rough edges and occasional breaking changes


<p>
  <a href="https://github.com/fayazara/Screendrop/releases/latest">Latest release</a>
  ·
  <a href="https://github.com/fayazara/Screendrop/releases">All releases</a>
</p>


## Features

- Capture a display, window, or selected area as a screenshot or recording.
- Configure global hotkeys, timers, file formats, save behavior, and complete after-capture workflows.
- Copy, compress, save, pin, preview, annotate, edit, upload, or delete directly from a customizable floating preview stack.
- Grab text off the screen with on-device OCR - no screenshot saved, just the text on your clipboard.
- Open images from Finder with Screendrop and edit imported copies without touching the originals.
- Annotate non-destructively with drawing tools, crop, smart redaction, backgrounds, wallpaper packs, perspective effects, progressive blur, borders, and watermarks.
- Record camera, microphone, and system audio as separately editable sources.
- Use a notch-native teleprompter that follows your narration with on-device speech recognition.
- Edit recordings with smooth zooms, reconstructed cursors and clicks, keystroke captions, camera layouts, clip cuts, speed changes, social aspect ratios, and reusable style presets.
- Transcribe narration on-device, burn in karaoke-style captions, or edit the video by cutting its transcript.
- Share through your own Cloudflare account with a video player, scrub previews, searchable transcripts, comments, and rich link previews.
- Automate screenshots and recordings with Apple Shortcuts, Siri, and App Intents.

## Install

### Download

1. Download the latest `Screendrop.dmg` using the button above or from the [releases page](https://github.com/fayazara/Screendrop/releases/latest).
2. Open the DMG and drag **Screendrop** into your Applications folder.
3. Launch Screendrop. It lives in the menu bar at the top-right of the screen.

The download button always points to the newest release.

**Requirements:** macOS 26.4 or newer.

> On first launch, macOS may warn that the app is from an unidentified developer. Right-click the app and choose **Open**, or allow it under **System Settings → Privacy & Security**.

### Homebrew

Install from the Homebrew tap:

```bash
brew install --cask fayazara/tap/screendrop
```

Update later with:

```bash
brew upgrade --cask screendrop
```

Screendrop can also update itself through Sparkle.

## Quick Start

Screendrop can be controlled from its menu bar item or with global hotkeys.

| Default shortcut | Action |
| --- | --- |
| `Option + 1` | Capture full screen |
| `Option + 2` | Capture a window |
| `Option + 3` | Capture an area |
| `Option + 4` | Open the screen-recording picker |
| `Option + 5` | Capture text (OCR) to the clipboard |

All five shortcuts are customizable under **Settings → Screenshots** and **Settings → Screen Recordings**.

You can also:

- Run capture and recording actions from Apple Shortcuts, Siri, or Spotlight.
- Right-click one or more images in Finder and choose **Open With → Screendrop**.
- Reopen recent screenshots and recordings from the menu bar or the full History view.

## Screenshots

### Capture

Capture an entire display, a window, or a freely selected area. Screenshots are taken at native display resolution and imported into local History before any optional automation runs.

Screenshot preferences include:

- A self-timer of 3, 5, or 10 seconds.
- Optional window shadows.
- Automatic trimming of the empty black menu-bar strip on notched Macs.
- PNG or JPEG export with configurable JPEG quality.
- A configurable export folder and a Save action that can bypass the save panel.
- A lower-resolution editor preview to reduce memory use while preserving full-resolution exports.
- An option to include Screendrop's own windows in screenshots and recordings; they are excluded by default.

### Capture Text

**Capture Text** (`Option + 5`, or the menu bar) drags out an area like a normal
area capture, recognizes the text inside it with on-device Vision OCR, and puts
that text on the clipboard. No image is saved, nothing is added to History, and
no preview card appears - a brief toast confirms what was copied.

Recognized lines are returned in reading order, so multi-column screenshots
paste in the order you read them rather than the order Vision happened to find
them.

### After-Capture Automation

Choose exactly what happens after every screenshot:

- Show the preview overlay.
- Copy the image to the clipboard.
- Save it to the export folder.
- Upload it and copy the share link.
- Open the annotation editor.
- Pin it above other windows.

Recording automation has its own independent settings for previewing, copying, saving, uploading, and opening Studio.

### Floating Preview Stack

New captures appear as floating cards on the active display. From a card you can:

- Copy the capture or drag it into another app.
- Save it to disk.
- Create a smaller JPEG.
- Pin a screenshot as an always-on-top reference.
- Open Quick Look.
- Annotate a screenshot or edit a recording.
- Upload to your cloud and copy the link.
- Delete the file or dismiss only the preview.
- Copy recognized text from a screenshot using on-device OCR.
- Add screenshots to a basket and drag the complete basket into another app as separate files.

The overlay can appear on the left or right, close automatically after a chosen delay, and dismiss after a drag. Its actions are completely rearrangeable: drag actions between four corner slots, the center buttons, and a hidden-actions tray in **Settings → Overlay**.

When the stack is collapsed, it becomes a small peek tab instead of disappearing. This keeps captures close without covering the workspace.

### History

History keeps screenshots and complete recording projects together. It shows thumbnails, dimensions, capture times, video durations, editable-project state, and saved cloud links. Select any number of screenshots in History to add them to the same draggable basket used by the floating preview.

From History you can Quick Look, copy, annotate, edit, upload, reveal in Finder, or delete a capture. The menu bar also exposes a compact list of recent items.

### Open Images from Finder

Screendrop registers as an image editor in Finder. Opening an image with Screendrop:

1. Validates the image.
2. Imports a copy into Screendrop History.
3. Opens the copy in the annotation editor.

The original file is never modified. Multiple selected images can be opened at once, each in its own editor window.

## Annotation Studio

The annotation editor is non-destructive. Screendrop preserves the untouched base image and writes editable state to a neighboring `.screendrop` sidecar, so saved annotations can be reopened and changed later. Display previews are lightweight, while final renders use the source image's full pixel resolution.

### Drawing and Redaction

Available tools include:

- Rectangle and filled rectangle
- Circle
- Straight line and arrow
- Freehand drawing
- Numbered markers
- Text with font, weight, alignment, and size controls
- Highlight regions that dim everything outside the selection
- Pixelate and blur
- Select, move, resize, multi-select, delete, undo, and redo

Smart Redaction scans the screenshot for sensitive text and can add blur or pixelation automatically. Redaction strength remains editable after detection.

### Crop

Crop at full resolution with freeform, original, `1:1`, `16:9`, `9:16`, `4:3`, and `3:2` presets. Crops remap existing annotations into the new image coordinates and participate in undo and redo.

### Backgrounds and Mockups

Turn a plain screenshot into a finished visual without leaving Screendrop:

- Apply solid colors, gradients, custom images, or downloadable wallpaper packs.
- Save, import, export, and share background presets as versioned `.screendroppreset` JSON files.
- Adjust padding, corner radius, shadow, aspect ratio, and nine-point alignment.
- Add a configurable solid border around the screenshot.
- Add a text watermark with placement and typography controls.
- Use camera-style perspective, rotation, zoom, and pan controls for dimensional mockups.
- Add radial or directional progressive blur, either clipped to the screenshot or bleeding into the surrounding scene.

The editor keeps these effects live and re-editable instead of flattening them into the source.

Shared presets include portable colors, gradients, layout, camera, blur, border, and watermark settings. Local wallpaper images and their file paths are never exported or imported; a wallpaper-based preset uses no background when opened on another Mac.

## Screen Recording

### Before Recording

The recording picker provides one place to prepare a session:

- Choose a display, app window, or selected area.
- Choose a camera, including external and Continuity Camera devices.
- Choose a microphone.
- Toggle system audio.
- Set a 1, 3, or 5 second start timer.
- Write and enable a teleprompter script.

Turning on the camera starts a live preview before recording begins, giving the camera time to settle exposure and white balance. Camera permission failures or disconnected optional devices do not throw away the screen recording; Screendrop warns and continues without that input.

For area recordings, the selected boundary remains visibly highlighted while the rest of the display is dimmed. The guide is click-through and excluded from the recording.

### While Recording

A floating control bar shows elapsed time and lets you:

- Pause or resume.
- Restart the same source.
- Stop and keep the recording.
- Delete the current recording.

The screen, camera, cursor activity, clicks, keystrokes, microphone, and system audio are captured as coordinated inputs. Screendrop keeps the raw screen and camera masters separate so later edits do not permanently burn effects into the footage.

### Teleprompter

Paste or type a script from the pre-record bar, choose how many lines to show, and enable the teleprompter for the next recording.

On a Mac with a notch, the script grows out of the hardware notch in a Dynamic Island-style panel. On other displays it appears as a floating pill below the menu bar. With a microphone enabled, Apple's on-device Speech Analyzer follows the spoken words, highlights progress, and advances the script automatically. Without a microphone, the script remains available as a static prompt.

The teleprompter and its speech tracking are best-effort and never interrupt the recording if recognition is unavailable.

## Recording Studio

Every new recording is stored as a non-destructive session package. The package preserves the screen master, optional camera master, input timeline, metadata, and a small editable project document. The original media stays untouched, and the project can be reopened from History.

### Timeline Editing

- Scrub with generated frame thumbnails.
- Split clips at the playhead.
- Trim or delete clips.
- Change speed per clip.
- Select zoom and clip blocks directly on the timeline.
- Undo and redo project edits.

### Background, Layout, and Social Formats

- Use colors, gradients, or wallpapers behind the recording.
- Adjust padding, corner radius, and shadow.
- Export in the original aspect ratio, `16:9`, `9:16`, `1:1`, or `4:5`.
- Choose **Fill** for a pointer-following reframed crop or **Fit** to keep the full recording visible on the background.
- Crop only the screen-video card with freeform, original, `1:1`, `16:9`, `9:16`, `4:3`, or `3:2` handles; the background canvas and source recording remain unchanged.
- Save the current background, layout, cursor, and camera design as a named preset.
- Choose a preset as the default for future recordings.

### Zooms, Cursor, Clicks, and Keystrokes

Screendrop records interaction data separately from the screen pixels, so presentation effects remain editable:

- **Auto Zoom** turns recorded clicks into smooth camera moves.
- Add, remove, enable, resize, and retime zooms manually.
- Let a zoom follow the pointer or give it a fixed focal point with a visual focus pad.
- Adjust the reconstructed cursor size after recording.
- Toggle click highlights.
- Toggle keystroke captions and place them across six top or bottom positions.

Because the operating-system cursor is not baked into the source video, Studio can reconstruct a smoother cursor using the artwork and pointer timeline captured during the session.

### Camera

The camera remains a separate video track:

- Show or hide it at any time.
- Drag it directly on the canvas.
- Adjust its size and roundness.
- Preserve camera edits as part of a reusable Studio preset.

### Transcription, Captions, and Text-Based Editing

Narrated recordings can be transcribed entirely on-device with Apple's Speech Analyzer.

The result powers two workflows:

- **Captions:** edit text line by line, click timestamps to seek, adjust position and size, and optionally highlight each spoken word for a karaoke-style effect.
- **Edit Video:** click a word to seek, Shift-click to select a passage, and cut the selection to remove the matching footage. Screendrop can also remove filler words and trim narration silences automatically.

Transcript cuts update the video timeline and captions together and remain undoable.

### Export and Share

Studio exports the complete composition-screen, camera, backgrounds, zooms, cursor, click effects, keystrokes, captions, edits, speed changes, and selected audio-in one render.

You can choose quality, codec, resolution, and whether to include audio. Export and Share show progress, can be cancelled, and report completion. Renders are cached against the project state, so exporting or sharing the same edit again can reuse finished work.

Screendrop also includes a lightweight trim-and-compress editor for regular video files. FFmpeg enables its conversion and compression options:

```bash
brew install ffmpeg
```

## Cloud Sharing

Cloud sharing is optional, self-hosted, and Cloudflare-first:

- A Cloudflare Worker receives authenticated uploads and returns share links.
- [Cloudflare R2](https://developers.cloudflare.com/r2/) stores screenshots and recordings without egress-bandwidth charges.
- [Cloudflare D1](https://developers.cloudflare.com/d1/) stores lightweight upload and share-page metadata.
- Screendrop only needs the Worker URL and an upload token; it never needs R2 or S3 access keys.

Shared recordings get a Loom-style page:

- A video player with captions, playback speed, theater mode, and thumbnail previews while scrubbing.
- A synced, searchable transcript that follows playback and seeks when clicked.
- Comments that can be attached to moments in the video.
- View counts, a poster image, and rich previews when the link is pasted into chat.

Shared screenshots use a clean viewer with copy and download actions.

The companion Worker lives at:

[github.com/fayazara/screendrop-worker](https://github.com/fayazara/screendrop-worker)

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/fayazara/screendrop-worker)

### Cloud Setup

The fastest setup is built into Screendrop:

1. Open **Settings → Cloud**.
2. Copy the generated upload token.
3. Click **Deploy to Cloudflare**.
4. Paste the token when Cloudflare asks for the `UPLOAD_TOKEN` secret.
5. After deployment, copy the Worker URL back into Screendrop.
6. Click **Verify Connection**.

The deploy flow provisions the R2 and D1 bindings used by the Worker. For a manual deployment, configure the Worker with those bindings and store the token as a Worker secret:

```bash
npx wrangler secret put UPLOAD_TOKEN
```

Screendrop verifies the Worker URL and token before enabling uploads.

### How Uploads Work

1. Screendrop sends the file to the Worker with `PUT /api/upload`.
2. The Worker validates the bearer token, streams the file to R2, and writes its metadata to D1.
3. The Worker returns a share URL. Screendrop copies it and stores it in local History.
4. For edited recordings, Screendrop uploads the rendered final cut-not the raw screen master.
5. Screendrop then adds best-effort video sidecars: a title, poster, transcript remapped to the edited timeline, and a storyboard sprite used for scrub previews.

The share link works as soon as the main upload finishes and becomes richer as the sidecars arrive.

## Privacy and Permissions

Screendrop is local-first:

- Captures, project files, editable annotation sidecars, and transcripts are stored on your Mac.
- Speech transcription runs on-device. Apple may download the required language model when you first enable transcription or the speech-following teleprompter.
- The cloud upload token is stored in Keychain.
- Cloud uploads only happen when an upload action or configured after-capture action requests one.
- Screendrop has no central account or hosted Screendrop server.
- Network access is otherwise limited to explicit features such as update checks, cloud setup, and wallpaper downloads.

macOS may request:

- **Screen & System Audio Recording** for screenshots and screen recordings.
- **Camera** for the separate camera track and preview.
- **Microphone** for narration and speech-following teleprompter progress.
- **Input Monitoring** for editable keystroke captions.

Screendrop windows are excluded from captures by default. Enable **Settings → General → Include Screendrop windows in captures** when you intentionally want preview cards, recording controls, Settings, or other Screendrop UI in the result.

## Building Locally

Requirements:

- macOS 26.4 or newer
- Xcode 26.4 beta toolchain

Xcode resolves the Sparkle and DockProgress package dependencies automatically.

Build from the command line:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Screendrop.xcodeproj \
  -scheme Screendrop \
  -configuration Debug \
  -destination "platform=macOS"
```

There is no test target. A successful Xcode build is the automated verification gate.

## Releasing

Screendrop includes a Go release helper. To run the complete archive, notarize, package, and publish flow:

```bash
go run ./cmd/screendrop-release -build
```

It creates a DMG, signs the update for Sparkle, creates the GitHub release, updates and pushes `appcast.xml`, and updates the Homebrew cask. Without `-build`, the helper expects an already exported `Screendrop.app` in `~/Downloads`.

## License

Screendrop is dedicated to the public domain under [CC0 1.0 Universal](LICENSE).
