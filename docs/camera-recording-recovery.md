# Camera recording failure recovery

Camera preview and camera movie writing are separate. A working preview does not establish that every frame reached the movie writer.

The camera writer removes pauses from host timestamps. That maps the first frame after a pause onto the last timestamp before it. Passing both frames into the fragmented HEVC MOV writer can fail with `AVFoundationErrorDomain -11800` / underlying `-16364`. The writer now accepts only strictly increasing presentation timestamps. Early pauses before the timeline starts do not affect its origin.

A camera recording is written to `camera.partial.mov` inside the recording package. Finalization validates that it contains a readable video track and positive duration before promoting it to `camera.mov`. If AVFoundation reports failure, readable fragments can still be promoted, with a warning. An unreadable partial stays in the package for manual recovery and is excluded from Studio's normal camera input so the screen recording can still be exported. No partial is overwritten when starting a writer.

Unexpected screen startup failures also finish and preserve any camera file already written. Explicit discard/restart still removes the session, as requested by those actions.

After an application crash, `camera.partial.mov` may remain without having been validated or promoted. Automatic crash recovery is not implemented. Keep the original package and inspect a copy of the partial movie with a media player or recovery tool; not every partial file is repairable.

## Regression checks

No test target or additional dependency is needed. From the repository root:

```sh
xcrun swiftc Screendrop/CameraMovieWriter.swift scripts/check-camera-recording.swift -o /tmp/screendrop-camera-check
/tmp/screendrop-camera-check
```

The check uses generated frames and real AVFoundation encoders/decoders. It covers normal recording, early pause, pause/resume, repeated pauses, backward timestamps, a late writer timing failure, no camera frames, existing output files, repeated finish, and explicit discard. It does not access hardware cameras or screen contents. Its temporary test files are removed on completion.

For a hardware smoke test, record a non-sensitive screen with camera enabled for at least 10 seconds, pause/resume twice, then stop. Reopen the project, show the camera in Studio if a preset hides it, and export. Confirm both source movies and the exported camera remain readable and in sync. Use a disposable test recording for this check; do not deliberately fault a writer during valuable work.
