# Studio editor: UX analysis and work plan

> **Status (2026-11-14):** everything below is built on `studio-editor-engine`, except
> 2.4 (lift / non-ripple delete, which needs your call) and the `Tools/` test folder in
> section 6 (the checks were run from a scratch folder instead). Video transitions (2.5,
> second half) were never in scope.

Written 2026-11-13, after the sound-engine rebuild on branch `studio-editor-engine`.
This is a hand-off document: each item is meant to be picked up on its own by an
agent (or a person) who has not seen the conversation that produced it.

How to read the confidence labels:

- **[seen]** I read the code that causes this. The file and function names are right.
- **[suspected]** I inferred it from code I read nearby, or from how AVFoundation
  behaves. Confirm it in the code before changing anything.
- **[missing]** A feature that does not exist yet.

Line numbers are deliberately left out; search for the function or type name.

---

## 0. Read this before touching anything

### What the editor is now

- The video is a list of clips: `RecordingClipTimeline` (`segments: [RecordingClipSegment]`),
  each a range of the source recording with a `speed`, and its own sound `volume` and `isMuted`.
- "Editor time" (also "edited clock") is seconds into the cut movie. "Source time" is seconds
  into the raw recording. Zooms, text, redactions, images and layout cues are stored in source
  time. Audio clips are stored in editor time.
- Sound is built by `StudioAudioComposer` for playback, video export and audio-only export.
  Levels and fades are applied by `RecordingAudioGain.makeEnvelopeTap`. Do **not** go back to
  `AVMutableAudioMixInputParameters.setVolume` / `setVolumeRamp`: they smear level changes across
  cuts (this was measured, it is not a guess).
- `StudioAudioConform.conform(_:from:to:)` carries audio clips through every change of the video's
  clips. Linked clips (`isLinked`) are cut with the video. Unlinked clips stay whole and keep their
  starting moment.
- Every change to the video's clips must go through `RecordingStudioModel.applyClipTimeline`.
  It changes video and audio in one undo step. Never assign `clipTimeline` directly for a
  structural edit.
- Keys are in `StudioKeyCommands.swift` (a window-level `NSEvent` local monitor).

### Rules of this repo (from `AGENTS.md` and from the owner's past feedback)

1. Build with the command in `AGENTS.md`. While Xcode is open, add
   `-derivedDataPath <some scratch folder>` or the build can report success without compiling.
2. There is no test target. Verification is: the build, plus the two Debug launch arguments
   - `-benchmarkExport <project.screendroprec> -benchmarkKeepOutput YES` renders a project headlessly.
   - `-studioEngineCheck <project copy> [-studioEngineCheckAudio <audio file>]` drives the real
     model through split / delete / import / link / cut / mute / split-all / detach / trim / undo-all / redo-all
     and prints the clips and audio after each step. **It edits the project: run it on a copy.**
3. Do not launch the app or UI-test it. The owner runs it. Stop at a green build plus headless checks.
4. Swift settings: everything is `@MainActor` by default; mark pure value types `nonisolated`.
   Imports do not leak between files (`MemberImportVisibility`): import `AVFoundation` / `CoreMedia`
   in any file that touches their members.
5. No external packages. `@Observable`, not `ObservableObject`.
6. Atomic commits: one logical change per commit, build green before each. Commit only when asked.
7. Taste rules that have each been given as explicit feedback. Breaking them gets work reverted:
   - **No spring or morph animation on timeline content** (lanes, blocks, clip strip, playhead position).
     Edits land instantly. Lanes carry `.transaction { $0.animation = nil }`.
   - **Tracks stay full height** with normal-size glyphs. Never collapse, thin, or auto-hide a track.
   - **Only restyle the surface a task names.** Do not "tidy" neighbouring UI.
   - Timeline blocks reuse `StudioBlockLane`, `StudioBlockSurface`, `StudioBlockLabel`,
     `StudioSelectionFrame` in `StudioTimelineBlocks.swift`. Yellow is reserved for selection.
   - Inspector UI uses only the `Inspector*` components (`InspectorSlider`, `InspectorFieldPair`,
     `InspectorHalfField`, `InspectorActionButton`, `InspectorToggleRow`, `InspectorHint`, `InspectorSegmented`).
   - No custom cursors. No full-screen overlays. No `TextField` prompts in bars.
   - Nested rounded rects: outer radius = inner radius + padding.
8. Comments say why, in plain words. Tool descriptions in `AgentTools.swift` are the MCP agent's only
   documentation: update them whenever a document field changes.

### First job: commit what exists

The branch has one large uncommitted change. Split it into atomic commits, in this order, building
after each (later commits depend on earlier ones, so stage by file where possible):

1. Clip sound fields: `RecordingClipTimeline.swift`.
2. Audio clip model + engine: `RecordingAudioClip.swift`, `StudioAudioEngine.swift`.
3. Composer + envelope tap + exports: `StudioAudioComposer.swift`, `RecordingAudioGain.swift`,
   `RecordingCompositionBuilder.swift`, `RecordingStudioExporter.swift`, `RecordingAudioExport.swift`,
   `RecordingSessionRenderer.swift`, `RecordingStudioStyle.swift` (the `replacementAudioSync` field).
4. Model: `RecordingStudioModel.swift`.
5. UI: `RecordingStudioTimelineDock.swift`, `RecordingClipTimelineView.swift`, `StudioKeyCommands.swift`,
   `RecordingStudioInspector.swift`, `StudioOverlayInspector.swift`.
6. `AgentTools.swift`, `RecordingExportBenchmark.swift`, `AGENTS.md`, this file.

If the files will not build separately in that order, fewer commits are fine; do not spend long on it.

---

## 1. Bugs and data-loss risks (do these first)

### 1.1 Removing or replacing the soundtrack deletes the file and cannot be undone  [seen]

**Where:** `RecordingStudioModel.replaceAudio(with:)`, `removeReplacementAudio()`,
`removeStoredReplacementAudio(in:)`, `clearReplacementAudio()`.

**Problem:** "Replace" deletes any previous `audio-replacement.*` from the package before copying the
new one. "Remove" deletes the file immediately. Neither registers an undo. One wrong click loses a
soundtrack that may have taken a cleanup tool minutes to produce, and ⌘Z does nothing. Since the
rebuild, `clearReplacementAudio()` also drops every audio clip detached from the soundtrack
(`source == .replacement`), also without undo.

**Fix:**
1. Never delete on remove/replace. Give each import a unique name
   (`audio-replacement-<short uuid>.<ext>`). `RecordingEditDocument.replacementAudioFileName` already
   stores the name, so nothing else changes on disk.
2. Make both actions undoable. The undo closure needs the previous
   `(RecordingReplacementAudio?, RecordingAudioSync?, [RecordingAudioClip])`. Restoring is synchronous
   because the resolved `RecordingReplacementAudio` (asset + track) can be kept in the closure.
   Use `registerUndo` and call `adoptReplacementAudio(_:sync:)`, set `audioClips`, then
   `applyReplacementAudioToPlayback()`.
3. Garbage-collect unreferenced `audio-replacement-*` files in `saveProject()` (after a successful
   write) and never at any other time. Keep the file the last *saved* document references too.
4. `applyAgentDocument` currently pins the soundtrack ("stays put"). Leave that as is.

**Check:** `-studioEngineCheck` on a copy with a soundtrack: add steps for replace → undo → redo and
remove → undo; print `replacementAudio?.url.lastPathComponent` after each. The file must exist after undo.

### 1.2 Removed audio and images leave orphan files in `media/`  [seen]

**Where:** `copyIntoProject(_:directory:)`, `removeAudioClip(id:)`, `removeImage(id:)`.

**Problem:** Imports are copied into `<project>/media/` under a UUID name. Removing the clip never
removes the file (correctly, because of undo), but nothing ever does. Projects grow forever.
Duplicating or splitting an audio clip shares one file between clips, so deletion must be by reference count.

**Fix:** In `saveProject()`, after the write succeeds, list `media/`, and delete files that are
referenced by neither the saved document nor the current in-memory document
(`imageOverlays[].fileName`, `audioClips[] where source == .file`). Do it off the main actor.

### 1.3 ⌘Z within 600 ms of a slider change undoes the wrong thing  [seen]

**Where:** `editClipSound`, `editAudioClip`, and the older `textCoalesceTask` / `redactionCoalesceTask` /
`imageCoalesceTask` paths; `undo()`.

**Problem:** Slider edits are held in a snapshot and only registered with the undo manager after a
600 ms rest. If the user presses ⌘Z before that, the pending edit is not on the stack yet, so the
*previous* action is undone and the slider change survives.

**Fix:** Add one `private func flushPendingEdits()` that cancels each coalesce task and calls the
matching `end…Edit` (`endClipSoundEdit`, `endAudioClipEdit`, and the text/redaction/image
equivalents). Call it at the top of `undo()`, `redo()`, `saveProject()`, `performAgentEdit`, and
`applyClipTimeline`.

### 1.4 Every clip edit force-selects a clip  [seen]

**Where:** `applyClipTimeline`: `selectedClipID = selectedID.flatMap {…} ?? next.segments.first?.id`.

**Problem:** When the requested selection no longer exists (or is nil with `selectsClip == true`), the
*first clip of the video* becomes selected. Undoing an edit near the end of a long recording suddenly
selects clip 1, the inspector switches to it, and Delete now targets it. Transcript cuts
(`cutSourceRanges`) pass `selectedClipID` through and hit the same fallback.

**Fix:** Fall back to the clip under the new playhead (`next.location(at: playheadTime)?.segmentID`)
only when a clip was selected before the edit; otherwise leave nothing selected. Never fall back to
`segments.first`.

### 1.5 The envelope tap silently does nothing for unknown sample formats  [seen]

**Where:** `RecordingAudioGain.makeEnvelopeTap`, the `process` callback.

**Problem:** It handles Float32, Float64, Int16, Int32. For anything else the samples pass through
untouched, so a *muted* clip would play. In practice taps receive Float32, but a silent failure of
mute is the worst kind.

**Fix:** In `prepare`, record whether the format is supported. If not, log once with `Logger`
(category `StudioAudio`) and, in `process`, zero the buffers when the gain at that time is 0 (use
`memset` on `mData`) so mute at least always works.

### 1.6 Waveform and peaks read only the first audio track  [seen]

**Where:** `RecordingAudioPeaks.load(url:)` (`loadTracks(withMediaType: .audio).first`).

**Problem:** A recording with system audio *and* microphone has two audio tracks. The clip waveform
shows only the first, which may be the silent system track, so the waveform is flat while someone is
talking. The exported and played sound uses all tracks (`StudioAudioSources.recording`).

**Fix:** Read all audio tracks through one `AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: …)`
(same PCM settings as now). One code path, one mixed outline.

### 1.7 Linked audio is destroyed by a trim and does not come back  [seen]

**Where:** `StudioAudioConform.conformLinked`.

**Problem:** Trim a video clip's end in by 2 s: the linked audio under those 2 s is cut away
(correct). Now drag the same edge back out 2 s: the video returns, the linked audio does not,
because the piece's `trimEnd` was shortened and nothing knows it used to continue. The clip's *own*
sound comes back (it is derived from the source range), so the two kinds of sound behave differently.
Undo restores it; re-trimming does not.

**Fix (heal on extension):** In `conform`, after computing the new pieces for a linked clip, for each
piece whose end sits exactly on a video cut (within 2 ms of an entry in `new.editPoints`) and whose
file still has material after `trimEnd` (`trimEnd < fileDuration`): if the *old* timeline had that
same piece ending on the same clip's edge and the clip's edge moved outward (the segment with the
same `id` has a larger `sourceEnd`), extend `trimEnd` by `(newSourceEnd - oldSourceEnd) * filePerSource`,
clamped to `fileDuration` and to the start of the next piece on that lane. Mirror it for the leading
edge with `trimStart` / `start`. Only do this when the piece's edge and the video edge coincided
*before* the edit, so audio the user trimmed on purpose is never extended.
Add cases to the standalone engine test (see section 6).

### 1.8 Audio clips past the end of the video are invisible and silently dropped  [seen]

**Where:** `StudioTimelineScale.x(for:)` clamps to `duration`; `StudioAudioComposer.add` cuts clips to
`videoDuration`; `importAudio` and `duplicateAudioClip`.

**Problem:** Duplicate a clip near the end, or delete video under unlinked music, and part or all of
an audio clip lies after the last frame. The block is drawn squashed against the right edge (x is
clamped), it cannot be grabbed sensibly, and it plays nothing. The user cannot tell why.

**Fix:**
1. In `StudioAudioLane.visibleBlocks`, pass `editorEnd: min(clip.end, model.duration)` and skip clips with
   `start >= model.duration - 0.01`.
2. For a clip cut short by the end of the video, draw `StudioBlockHatch` over its last 10 pt and set
   the help text to "Continues past the end of the video".
3. Add `var audioClipsPastEnd: Int` to the model. When > 0, show one `InspectorHint` in the Audio
   section: "N audio clips start after the video ends" with an `InspectorActionButton("Remove")`.
4. `duplicateAudioClip`: if the copy would start at or past `duration`, do nothing (beep with `NSSound.beep()`).

### 1.9 Import truncates audio and jumps to zero  [seen]

**Where:** `importAudio(_:into:atEditorTime:)`.

**Problem:** (a) `clip.trimEnd = min(fileDuration, duration - start)` trims the import to the video's
length *at import time*; (b) dropping within 0.5 s of the end silently places it at 0 instead.
(a) is reasonable but invisible; (b) is surprising.

**Fix:** Keep (a) (it avoids 1.8). Remove (b): if `time > duration - 0.5`, place it at
`max(0, duration - min(fileDuration, duration))` so it ends at the end of the video.

### 1.10 `clipSoundPeak` sorts the sync spans for every waveform bar  [seen]

**Where:** `RecordingStudioModel.clipSoundPeak(fromSource:to:)` → `RecordingAudioSync.pieces(...)`
(which calls `spans.sorted`). `RecordingClipTimelineControl.drawWaveform` calls it once per 3 pt bar.
Also `RecordingClipTimelineControl.update(...)` sets `needsDisplay = true` on every SwiftUI update,
which during playback is every time-observer tick (50 Hz).

**Fix:**
1. Keep `RecordingAudioSync.spans` sorted at construction (`flat(over:)` already is; sort in
   `init(from:)`), and make `pieces` skip the sort.
2. In `update(...)`, only set `needsDisplay` when `timeline`, `selectedClipID`, `title`, or the thumbnail
   store actually changed. The control does not draw the playhead (the SwiftUI overlay
   `StudioTimelinePlayhead` does), so `playheadTime` changes need no redraw. **Verify** that nothing in
   `draw(_:)` reads `playheadTime` before removing it.

---

## 2. Editing model gaps (the "professional editor" list)

### 2.1 Clips cannot be reordered or reused  [seen]

**Where:** `RecordingClipTimeline.normalized(to:)` sorts segments by `sourceStart` and trims overlaps.

**Problem:** The cut can only ever be the recording in its original order with pieces removed. A demo
recorded last cannot go first. A clip cannot be duplicated.

**Why it is not a one-line change:** `ViewportTimeline.build`, `PointerTimeline.build` and
`RecordingStudioMotionTimeline.build` integrate springs along editor time. Across a cut that jumps
backwards in the source, the zoom and the synthetic cursor would glide across the screen instead of
jumping. The branch `video-projects` (not `video-projects-wip`) solved this: commit `33597023`
"Keep clips in cut order when normalizing" and `92dba955` "Let zoom and pointer land on hard cuts".
Read those two commits as reference; do not merge the branch.

**Plan:**
1. `normalized`: stop sorting; keep cut order; still clamp each range and drop too-short ones; allow
   overlapping source ranges.
2. Add `hardCuts: [TimeInterval]` (editor times where the next segment's `sourceStart` is not the
   previous segment's `sourceEnd` *and* is earlier, or is a different stretch entirely) and make the
   three motion builders reset their spring state at each (snap, no easing).
3. Everything that maps source → editor (`editorTime(forSourceTime:)`, `slices(overlapping:)`) returns
   the *first* match today. With duplicates, overlay blocks (zoom/text/redaction/image) would need one
   block per occurrence. Until that is built, forbid duplicates and allow only reordering.
4. `StudioAudioConform` already prefers the segment with the same `id` (`editorTime(forSourceTime:preferring:in:)`),
   but `slices(of:overlapping:preferring:)` ignores its `preferring` argument. With reordering, make it
   place each slice under the segment with the same id first.
5. UI: drag a clip's body in `RecordingClipTimelineControl` past its neighbour's midpoint to swap.
   Today a body drag scrubs the playhead; keep scrub for a press that moves < 4 pt vertically *and*
   starts in the top 14 pt (title area) … simpler and more discoverable: body drag scrubs as now,
   **⌥-drag** or "Move Left / Move Right" in the context menu reorders. Add `⌘[` / `⌘]`? Avoid: keep
   to the menu and ⌥-drag for the first version.
6. Trim limits in `updateTrim` use the neighbours' source ranges (`previousEnd` / `nextStart`). With
   reordering, the limit is just `0...sourceDuration`.

Size: large. Do it as its own branch.

### 2.2 No range selection, no "delete this stretch"  [missing]

**Problem:** To remove a stretch you must split twice, select the middle, delete. Every pro editor has
in/out points.

**Plan:**
- Model: `var rangeSelection: ClosedRange<TimeInterval>?` (editor time). `I` sets the start at the
  playhead, `O` the end, `⌥X` clears. ⌫ with a range and nothing else selected calls a new
  `deleteRange(_:)`: map the range to source ranges per segment (walk `segments` with their editor
  ranges) and call `clipTimeline.removingSourceRanges(...)` then `applyClipTimeline`. Linked audio
  follows automatically.
- UI: draw the range in `StudioTimelineRuler` as a yellow band (selection colour) with the two times
  in the transport (`studioPreciseTimecode`). Dragging on the ruler while holding ⇧ draws a range
  instead of scrubbing (`scrubGesture`).
- Keys go in `StudioKeyCommands.handle`.
- Also offer "Export Selection" later; not now.

### 2.3 Single selection only  [seen]

**Where:** `clearTimelineSelection()`; seven separate `selected…ID` properties.

**Problem:** Cannot select two audio clips and move/delete/mute them together, or select a run of video
clips to change their speed.

**Plan (audio first, smallest useful step):** `selectedAudioClipIDs: Set<UUID>` with ⇧-click and ⌘-click
in `StudioBlockLane` (the lane gets `NSEvent.modifierFlags` at press time). Move applies the same
delta to all selected clips; delete/mute/link apply to all. Keep `selectedAudioClipID` as "the
primary one" (the last clicked) so the inspector keeps working. Do video clips after 2.1.

### 2.4 No gap / non-ripple delete  [missing]

Deleting always closes the gap. For screen recordings that is nearly always right. Low priority.
If wanted: `⇧⌫` = "Lift": replace the clip's sound with silence and its picture with a freeze of the
last frame. Do not build without asking.

### 2.5 No transitions or audio crossfades at cuts  [seen for audio]

**Problem (audio):** A hard cut in the middle of speech or room tone clicks, because the waveform
jumps. `StudioAudioComposer.mix` plays every placement at a constant gain right up to the cut.

**Fix (cheap, high value):** In `mix(for:plan:)`, for every placement whose owner is `.segment`, add a
4 ms ramp-in and 4 ms ramp-out to the envelope spans (skip if the placement is shorter than 20 ms;
skip the ramp-in at editor time 0 and when the previous placement on the same track is contiguous in
*source* time, i.e. a split with nothing removed. To know that, carry `mediaStart`/`mediaEnd` in
`StudioAudioLayout.Placement`). For `.clip` owners do the same at ends that have no user fade.
This is inaudible as a fade and removes the clicks.

**Video transitions** (cross-dissolve) are a much bigger job (two decode streams); do not start it.

### 2.6 Audio clip speed is not editable  [seen]

`RecordingAudioClip.speed` exists and plays correctly, but only `conform` and `detachAudio` ever set it.
Add an `InspectorSegmented` (0.5×, 1×, 1.5×, 2×) to `StudioAudioClipInspectorControls` for *unlinked*
clips; for linked clips show the value read-only with the hint "Follows the video's speed".
Changing speed keeps `start` and changes `duration`; run `resolvingLanes`.

**[suspected]** Pitch: `AVPlayerItem.audioTimePitchAlgorithm` is never set, so sped-up audio uses the
default algorithm. Set `.timeDomain` (good for speech) on the item in `rebuildScreenPlayerItem`, and
check what the export path does (the reader has `audioTimePitchAlgorithm` on
`AVAssetReaderAudioMixOutput`); set the same there and in `RecordingAudioExporter` so playback and
export sound alike.

### 2.7 The soundtrack cannot be nudged into sync  [missing]

**Problem:** Cleanup tools often return audio with a few tens of milliseconds of added latency. There
is no way to slide the replaced soundtrack against the picture.

**Plan:** Add `var offset: TimeInterval = 0` to `RecordingAudioSync` (encode only when non-zero).
`pieces(from:to:fileDuration:)` adds it to every `fileStart`/`fileEnd` (then clamps to `0...fileDuration`,
moving the piece's source bounds to match). UI: in the Audio section under the replacement chip, an
`InspectorSlider("Sync", range: -0.5...0.5, format: .seconds)` bound through a new
`model.setReplacementAudioOffset(_:)` that is coalesced and undoable like `editClipSound`. Because the
placement changes, it goes through `scheduleAudioPlaybackRebuild()`.

### 2.8 Frame stepping assumes 30 fps  [seen]

`stepFrames` uses `1/30`. Read the video track's `nominalFrameRate` once in `load()`
(`try await videoTrack.load(.nominalFrameRate)`), store `sourceFrameDuration`, use it in `stepFrames`
and for the precise timecode. Recordings are commonly 60 fps.

### 2.9 Markers  [missing]

`M` drops a marker at the playhead (editor time is wrong: store **source** time so markers follow
cuts, like zooms). Draw as small flags in the ruler; ↑/↓ (`seekToEditPoint`) should stop at them
(add them to `editPoints`). Store `markers: [RecordingMarker]?` in `RecordingEditDocument`
(id, sourceTime, optional note). Update `AgentTools.swift`. Medium priority.

---

## 3. Timeline interaction and feedback

### 3.1 Skimming cannot be turned off and fights precise work  [seen]

**Where:** `StudioTimelineDock.lanes` `.onContinuousHover` sets `model.hoverPreviewTime`; its `didSet`
seeks both players.

**Problem:** Moving the pointer anywhere over the timeline changes the preview frame. Park the
playhead on a frame, move the mouse toward the inspector, and the picture changes on the way out,
then snaps back. While dragging an audio clip the picture chases the pointer instead of showing the
playhead.

**Fix:**
1. `@AppStorage("StudioTimelineSkimming") var skims = true`; toggle with ⇧S and a `GlassIconButton`
   next to the snapping button (same cluster, `isOn:`). When off, never set `hoverPreviewTime`
   (still set `timelineHoverTime` so `C` works).
2. Regardless of the setting, suppress skimming while any lane drag is in progress. `StudioBlockLane`
   already reports scrubbing via `onScrubbing`; add an `onEditing: (Bool) -> Void` beside it and have
   the dock hold `isEditingBlock`; in the hover handler, skip `hoverPreviewTime` when it is true.

### 3.2 No live picture while trimming a video clip  [seen]

**Where:** `RecordingClipTimelineControl.updateTrim` changes only the control's private `timeline`;
`trimDidCommit` fires on mouse-up.

**Problem:** While dragging a clip edge you cannot see the frame you are trimming to, which is the
whole point of a trim.

**Fix:** Add `var trimPreview: ((TimeInterval) -> Void)?` (source time of the edge being dragged) to
the control and call it from `updateTrim`. In the dock, map it to a new
`model.previewSourceTime(_:)` that seeks the players to that *source* time without touching
`currentTime` (the screen player is a composition in editor time, so: if the source time is inside
the current cut use `editorTime(forSourceTime:)`; if it is outside, i.e. the edge is being dragged
outward into removed footage, there is no editor time for it. In that case show nothing new; do not
try to rebuild the item mid-drag). Clear the preview on mouse-up (`hoverPreviewTime = nil`).

### 3.3 Video trims do not snap; audio does  [seen]

Add snapping to `updateTrim` using the same rule as `StudioAudioLane.snapped` (7 pt tolerance) against:
the playhead, audio clip starts/ends, and recorded click times (`model.visibleRecordedPressTimes`).
Pass the snap points in through `update(...)` as an array of editor times, and honour the dock's
`snapsEdits` flag. Hold ⌘ during a drag to invert snapping temporarily (also add that to the audio lane).

### 3.4 No visible snap feedback  [seen]

When an edge snaps nothing shows it. Add `var snapGuideTime: TimeInterval?` as dock `@State`, set by the
audio lane (and the clip strip after 3.3) while an edge is caught, cleared on drag end. Draw it in
the same overlay as the playhead (`StudioTimelinePlayhead`'s parent overlay) as a 1 pt yellow vertical
line through all lanes. No animation.

### 3.5 ⌘-scroll and pinch zoom only work over the clip strip  [seen]

**Where:** `RecordingClipTimelineControl.scrollWheel` / `magnify`.

**Problem:** Pinch over the audio or zoom lanes and nothing happens.

**Fix:** Put a transparent `NSView`-backed gesture catcher behind the whole lanes area in the dock
(an `NSViewRepresentable` whose view overrides `scrollWheel` and `magnify` and forwards unhandled
scrolls with `super`/`nextResponder`). It calls the dock's existing `applyZoom(factor:anchorTime:)`.
Then delete the two overrides from the clip control. **Verify** that the SwiftUI `ScrollView` still
receives plain two-finger scrolls after this; if the catcher swallows them, use
`NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify])` scoped to the dock's frame instead.

### 3.6 Audio clips cannot be dragged between lanes  [seen]

Only the context menu moves lanes. In `StudioBlockLane` the drag is one-dimensional.

**Plan:** In `StudioAudioLane.apply`, the edit carries only a horizontal delta. Extend
`StudioBlockEdit` with `verticalTranslation: CGFloat` (points). In the audio lane, for `.move`,
compute `laneDelta = Int((verticalTranslation / (StudioTrack.audioHeight + trackSpacing)).rounded())`
and set `edited.lane = max(0, base.lane + laneDelta)`. Because each lane is its own `StudioBlockLane`
view and the block is drawn by the lane that owns it, the block will jump to the other lane view
mid-drag and the gesture's owning view will disappear, cancelling the drag. To avoid that, render all
audio lanes in **one** `StudioBlockLane`-like view whose height is `laneCount * (audioHeight + spacing)`
and whose blocks are offset by `lane`. That means `StudioTrack.audio(Int)` collapses back to a single
`.audio` track with a variable height. `StudioBlockLane` needs a `rowOf: (Item) -> Int` and row height.
This is a medium refactor of `StudioTimelineBlocks.swift`; follow the hit-testing rules in the file's
header comment exactly and re-test small blocks.
While dragging down past the last lane, show one extra empty lane so a new lane can be created.

### 3.7 Lanes have no headers  [seen]

The gutter shows the same `music.note` glyph for every audio lane (`StudioTrack.systemImage`). There is
no per-lane mute or solo.

**Plan (keep the gutter 40 pt, glyph-only, as designed):** make the audio lane glyph a button: click
toggles mute for every clip on that lane (`model.setAudioLaneMuted(_:lane:)`, one undo step), glyph
becomes `speaker.slash` when all clips on it are muted. ⌥-click solos (mutes all other lanes; a second
⌥-click restores what was muted before, kept in dock `@State`). Number lanes 2+ with a tiny digit is
*not* wanted (it restyles the gutter); use the `.help` text ("Audio 2") that already exists.

### 3.8 Fades can only be set by slider  [seen]

Add fade handles to the selected audio block: a 9 pt circle at the top of the block at `fadeIn` from
the leading edge and `fadeOut` from the trailing edge (only when the block is selected and wider than
60 pt). Dragging one calls `model.editAudioClip` with the new fade. They must be hit-tested *before*
the block body in `StudioBlockHitTester` (add an `accessory` target kind) or the lane's single drag
gesture will treat the press as a move. The selection colour (yellow) is right for these.

### 3.9 The timeline height jumps when a lane appears  [seen]

`visibleTracksHeight` grows when `audioLaneCount` grows (detach, overlap), pushing the preview up
mid-edit. If the user has set a height (`storedTracksHeight > 0`) nothing moves (the tracks scroll);
the jump only happens in the default "show everything" state. Acceptable, but scroll the new lane
into view when the dock is fixed-height: after an edit that raises `audioLaneCount`, call
`verticalScrollPosition.scrollTo(edge: .bottom)`.

### 3.10 The blade is ambiguous  [seen]

`model.blade(at:)` cuts the selected audio clip if the playhead is inside it, else the video. The
scissors tooltip is static. Make the tooltip say what it will do: "Split Audio at Playhead (⌘B)" vs
"Split Clip at Playhead (⌘B)", computed from `model.selectedAudioClip` and
`StudioAudioConform.split(_:at:) != nil`. Disable the button when neither a video split
(`clipTimeline.split(at:) != nil`) nor an audio split is possible, instead of doing nothing.

### 3.11 No feedback for keyboard actions that change nothing visible  [seen]

`V` (mute), `N` (snapping), `L`/`J` speed changes, and failed splits (too close to an edge) give no
confirmation. The canvas already has a transient badge view (`StudioCanvasBadge`, `StudioSkimBadge`,
`StudioPlaybackFlashView` in `RecordingStudioWindow.swift`). Add a small model property
`var transientNotice: String?` (cleared after 0.9 s) and show it with the existing badge style, top
centre of the canvas: "Muted", "Unmuted", "Snapping Off", "2×", "◀ 4×", "Too close to a cut".
Use the existing badge look; do not design a new one.

### 3.12 Shuttle speed is not shown  [seen]

`shuttleRate` is private(set) and nothing displays it. When `abs(rate) != 1` or `rate < 0`, show it
next to the timecode in `transport` (e.g. "2×", "◀ 1×") in the secondary text style already used for
the duration. Also add K+L / K+J (hold K, tap L or J) = step one frame, the standard behaviour:
track `isKHeld` from keyDown/keyUp in `StudioKeyCommands` (add `.keyUp` to the monitor mask).

**[suspected]** Reverse playback (`J`) relies on `AVPlayerItem.canPlayReverse` for a composition with
scaled segments and on the camera player following at a negative rate. It has not been run. If the
owner reports stutter, restrict `J` to "step back 1 s per press, repeat while held".

### 3.13 The transport timecode is display-only  [seen]

Make the current-time `Text` in `transport` click-to-edit: a click turns it into a small field
accepting `ss`, `m:ss`, or `m:ss.ff`; Return seeks. This needs a `TextField`, which the owner has
banned from *bars* in the recording UI; this is the Studio dock, a different surface, but ask before
building it.

### 3.14 Shortcuts are undiscoverable  [seen]

All keys live in a comment at the top of `StudioKeyCommands.swift`. There is no menu.

**Fix:** Add SwiftUI `Commands` to the Studio scene in `ScreendropApp.swift`: menus **Clip**
(Split, Split All, Trim Start, Trim End, Detach Audio, Mute, Duplicate, Delete) and **Playback**
(Play/Pause, Play Backward, Play Forward, Next Cut, Previous Cut, Step Frame, Snapping, Skimming).
Each calls the same model methods through `@FocusedValue` of the front Studio model. Give the menu
items the key equivalents and then *remove* the equivalents that AppKit will now deliver itself from
`StudioKeyCommands.handle` (anything with ⌘ or ⌥). Keep the bare-letter keys (J K L S C V N I O M) and
arrows in the monitor, because menu key equivalents without modifiers steal typing in text fields.
Also move the hidden `.keyboardShortcut`s on the dock's glass buttons (⌘B, ⌘Z, ⇧⌘Z, ⌘0, ⌘-, ⌘=, Space)
into the menus so they work when the button is not in the view tree.
**Check for double-firing**: one key must reach exactly one handler.

---

## 4. Inspector and wording

### 4.1 Clip controls act on a clip the user did not pick  [seen]

**Where:** `RecordingStudioInspector.shownClip` = selected clip, else the clip under the playhead.

**Problem:** With nothing selected, the Clip section's speed, the new Clip Volume / Mute / Detach all
act on "whichever clip the playhead is in". Scrub a little and the same controls now change a
different clip. Nothing says which.

**Fix:** Put the clip's identity in the section summary: "Clip 3 of 7 · 0:12–0:31" (editor range from
`clipTimeline.editorRange(for:)`), and when it is not the selected clip prefix "At playhead · ".
No layout change, summary text only.

### 4.2 Replacing audio is buried and under-explained  [seen]

The whole export → clean up → re-import round trip is two buttons in the "Audio" inspector section
with the explanation in tooltips. Now that the soundtrack follows cuts, the single most important
fact is invisible: *it lines up with the cut as it is right now*. Add one `InspectorHint` under the
buttons, shown only when a replacement exists: "Lined up with the cut when it was added. Later cuts
cut it with the video." And when the drift warning shows, say what to do: "Export the audio again
after your edits if you want a full-length replacement."

### 4.3 Audio-only export leaves the lanes out, silently  [seen]

By design (so the round trip does not bake music into the replacement). Add a toggle to
`StudioAudioExportOptions`: "Include added audio" (default off), stored in the model next to
`audioExportFormat`, passed to `RecordingAudioExporter.Configuration.audioClips` / `mediaDirectory`
(the fields exist and are already honoured by the exporter; the model just does not fill them).

### 4.4 Names  [seen]

- Detached audio is called "Recording Audio". Use "\(projectDisplayName) audio" so two detached clips
  from different takes can be told apart later.
- The context menu says "Unlink from Video" with glyph `personalhotspot.slash` (a stand-in I chose).
  Check for a better SF Symbol (`link.badge.minus` does not exist in all versions; verify in the SF
  Symbols app list available for macOS 26) or use `link` for both states.
- The snapping button glyph `arrow.right.and.line.vertical.and.arrow.left` is also a stand-in.

### 4.5 `InspectorHint` text on the audio clip page is long

Three hints stack on the selected-audio page. Keep the link explanation; drop the "Plays X of Y from Z"
line into the page header's subtitle if `pageHeader` supports one (**verify**), otherwise leave it.

---

## 5. Robustness and performance

1. **Peaks resolution [seen]:** `RecordingAudioPeaks.peaksPerSecond = 40`. At the maximum zoom
   (240 pt/s) the audio lane draws a bar every 4 pt = 60 bars/s and the clip strip one every 3 pt =
   80/s, so adjacent bars repeat. Raise to 100/s (a one-hour file is 360 k floats = 1.4 MB; acceptable,
   but follow the Memory note in `AGENTS.md`: one allocation per file).
2. **Peaks are normalised to the loudest sample [seen]**, so a quiet recording looks as loud as a hot
   one and "Clip Volume" has no visual reference. Keep the normalisation (the owner wants the lane to
   read), but clip the drawn bar at full height when `value * gain > 1` and tint those bars
   `systemOrange` to show clipping when volume is above 100%.
3. **Stale peaks [suspected]:** `loadPeaks(for:url:)` guards on `audioPeaks[key] == nil`. The soundtrack
   key is cleared in `adoptReplacementAudio`, but a slow load of an old file can finish after a new
   one was adopted and overwrite it. Capture the URL and drop the result if
   `replacementAudio?.url != url` when it arrives.
4. **`applyClipTimeline` rebuilds everything [seen]:** pointer timeline, viewport timeline, and the
   player item, even for `detachAudio`, where only a mute flag and the audio list change. Skip
   `rebuildPointerTimeline()` / `rebuildViewportTimeline()` when the segments' ranges and speeds are
   unchanged (compare with volume and mute stripped, the way `StudioAudioPlan.placement` does).
5. **Audio drag rebuilds [seen]:** `scheduleAudioPlaybackRebuild` debounces 180 ms and pauses playback.
   Fine. But `replaceAudioClips` compares `audioPlan.placement` (maps both arrays) on every drag tick;
   with hundreds of clips cache the placement key.
6. **Many audio tracks [suspected]:** the composer uses one composition track per lane per source
   track, plus recording tracks, plus the soundtrack. AVPlayer handles ~16 simultaneously enabled audio
   tracks comfortably; beyond that it may fail to play. Cap lanes at 8 in `resolvingLanes` (overflow
   clips share the last lane; the composer already refuses to overlap within a track by pushing the
   later clip to the track's end, which would misplace it, so instead **drop** overlapping overflow
   from playback and show the `InspectorHint` "Too many overlapping audio clips").
7. **Undo of clip-sound vs structure [seen]:** `registerClipSoundUndo` bails out if the clip ids changed
   ("replayed out of order"). With a linear undo stack that cannot happen; it is a guard only. Leave it.
8. **Accessibility [seen]:** `RecordingClipTimelineControl` draws everything itself and exposes no
   accessibility children; audio blocks are SwiftUI and are fine. Add `accessibilityChildren` returning
   one `NSAccessibilityElement` per clip (role button, label "Clip 2, 0:12 to 0:31, 2× speed, muted").
9. **Bare movies [seen]:** a video opened without a project cannot import media (`canImportMedia`), and
   its replacement audio references the picked file in place. The + button explains this in a tooltip
   only. Fine; no change.

---

## 6. Tests worth keeping

The sound engine was verified with throwaway scripts. Put them in the repo so the next change can
re-run them. No Xcode test target is needed (and the owner has not asked for one):

- `Tools/engine-test/main.swift`: compiled with
  `xcrun swiftc -O -o /tmp/t main.swift ../../Screendrop/RecordingClipTimeline.swift ../../Screendrop/RecordingAudioClip.swift ../../Screendrop/StudioAudioEngine.swift`.
  Cases that passed and must keep passing (full source timeline 0–60 s; music unlinked 0–60;
  voiceover linked at 10–30 from file 0–20 with 1 s fades; an unlinked effect at 40–42):
  1. Split only → audio unchanged, one piece.
  2. Remove source 15–25 → voiceover becomes two pieces (10–15 from file 0–5; 15–20 from file 15–20),
     fades only on the outer ends, first piece keeps the id; music untouched; effect moves 40 → 30.
  3. Conform back from the cut to the full timeline → the two pieces sit at 10 and 25.
  4. Middle clip to 2× → linked audio under it has `speed` 2 and half the length; effect after it moves earlier.
  5. Delete the first clip → music stays whole at 0; voiceover loses its first half.
  6. No two clips overlap on one lane after any of the above.
  7. `RecordingAudioSync.flat(over:)` + `pieces(...)`: source 30–40 maps to file 20–30 after a 15–25
     removal; restored video has no soundtrack piece; a short file ends early.
  8. `split` of an audio clip; old JSON without the new keys decodes; defaults are not encoded.
- `Tools/engine-test/export-check.sh`: builds a synthetic project with ffmpeg
  (`testsrc2` video; recording audio is a tone at `300 + 100*floor(t)` Hz; the soundtrack
  `2000 + 100*floor(t)` Hz; music a 5 kHz tone), writes `edit.json` variants (copy the `style` object
  from any real project in `~/Library/Application Support/Screendrop/Recordings/*/edit.json`; a
  hand-written `style` fails to decode and the export silently uses defaults), runs
  `-benchmarkExport … -benchmarkKeepOutput YES`, decodes the result to 16 kHz mono PCM and prints the
  dominant frequency and peak level per half second. Expected rows are in the conversation that
  produced this file; the key ones:
  - Soundtrack synced to the full recording, video cut 4–8 → 2000…2300 then 2800…3100 Hz.
  - No sync stored (old project) → 2000…2700 (flat, as before).
  - Middle clip 2× and muted, last clip at 50% → silence for that second, last clip at half level.
  - Soundtrack made for a cut, trim opened back up → recorded audio (700…1000) fills the gap.
  - Music with fade in 1 s / out 2 s → level ramps, exact silence outside.
- New cases to add with the work above: 1.7 (heal on extension), 2.5 (no click: measure the largest
  sample-to-sample jump within ±1 ms of a cut, before and after), 2.7 (offset).

---

## 7. Suggested order

| # | Item | Size | Why this order |
|---|------|------|----------------|
| 1 | 0 "commit what exists" | S | Everything else builds on it |
| 2 | 1.1, 1.2 soundtrack/media deletion + undo | M | Data loss |
| 3 | 1.3, 1.4 undo flush, selection fallback | S | Wrong-target edits |
| 4 | 1.6 peaks from all tracks | S | Waveform can be flat for mic recordings |
| 5 | 2.5 micro-fades at cuts | S | Audible quality, cheap |
| 6 | 3.1 skimming toggle + suppress during drags | S | Daily annoyance |
| 7 | 1.8, 1.9 audio past the end, import placement | S | Confusing states |
| 8 | 3.10, 3.11, 3.12 blade tooltip, notices, shuttle readout | S | Feedback |
| 9 | 1.10, 5.4 redraw and rebuild trimming | S | Smoothness on long recordings |
| 10 | 2.8 real frame rate | S | Correctness |
| 11 | 3.3, 3.4 video trim snapping + snap guide | M | Precision |
| 12 | 3.2 live trim preview | M | Precision |
| 13 | 2.2 range selection | M | Biggest missing editing gesture |
| 14 | 3.14 menus | M | Discoverability; touches app scene |
| 15 | 1.7 heal linked audio on extension | M | Consistency; needs careful tests |
| 16 | 2.7 soundtrack sync offset | S | Common real-world need |
| 17 | 3.5 zoom gestures everywhere | S–M | Verify scroll passthrough |
| 18 | 3.7, 3.8 lane mute/solo, fade handles | M | Audio polish |
| 19 | 3.6 drag between lanes | L | Refactor of `StudioBlockLane` |
| 20 | 2.3 multi-select | L | |
| 21 | 2.1 reordering | L | Own branch; motion timelines need hard cuts |
| 22 | 2.9 markers, 2.6 audio speed, 4.x wording | S each | Any time |

Ask the owner before starting: 2.1 (scope), 2.4, 3.13 (text field), 3.14 (new menus), and anything in
section 6 that adds a `Tools/` folder.

## 8. Things that were deliberately left alone

- Layout cues, zooms, text, redactions and images already live on the source clock and follow cuts.
- The clip strip stays an AppKit control (`RecordingClipTimelineControl`) for pixel-exact hit-testing
  and cheap drawing of very wide lanes; do not port it to SwiftUI.
- Audio clips stay on the edited clock (not anchored by id to a video clip). Anchoring by id was
  considered and rejected: `conform` gives the same result without a second source of truth, and it
  keeps the document readable for the MCP agent.
- The project volume (`audioVolume`) applies to the video clips' own sound only; audio clips carry their own.
