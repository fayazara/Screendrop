---
name: build-and-run-screendrop
description: "Build the Screendrop macOS app with xcodebuild, kill any running instance (of any scheme), and launch the fresh build. Use this skill whenever the user asks to run, launch, relaunch, or try out the app, or says things like 'build and run' or 'restart the app'."
---

# Build and Run Screendrop

This skill builds the Screendrop macOS application via `xcodebuild`, kills any
running instance of the app (regardless of which scheme it was launched
from), then launches the newly built app.

## Steps

1. **Pick a scheme.** List the schemes available in the project:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "/Users/fayazahmed/Developer/fayazara/mac/Screendrop/Screendrop.xcodeproj" \
  -list 2>/dev/null | sed -n '/Schemes:/,$p' | tail -n +2
```

- If there is only one scheme, use it without asking.
- If there is more than one scheme, ask the user which one to build/run
  (via AskUserQuestion) before proceeding, unless the user already named a
  scheme in their request (e.g. "run the Dev scheme"). Don't assume - the
  schemes can point at different configurations, bundle IDs, and even
  different launch arguments (e.g. `Screendrop Demo` builds the same
  `Screendrop.app` as the plain scheme but launches it with `--demo-mode`).

2. **Resolve build settings for the chosen scheme** - don't hardcode the
   configuration or output path, since it varies per scheme:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "/Users/fayazahmed/Developer/fayazara/mac/Screendrop/Screendrop.xcodeproj" \
  -scheme "<SCHEME_NAME>" -showBuildSettings 2>/dev/null \
  | grep -E "^\s*(CONFIGURATION|BUILT_PRODUCTS_DIR|FULL_PRODUCT_NAME|EXECUTABLE_NAME) "
```

Use `CONFIGURATION` for the `-configuration` flag in the build step, and
`BUILT_PRODUCTS_DIR` + `FULL_PRODUCT_NAME` to construct the `.app` path for
the run step.

3. **Build** the project with the resolved scheme/configuration:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project "/Users/fayazahmed/Developer/fayazara/mac/Screendrop/Screendrop.xcodeproj" \
  -scheme "<SCHEME_NAME>" \
  -configuration "<CONFIGURATION>" \
  -destination "platform=macOS" \
  2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -20
```

If the output shows `BUILD FAILED`, stop here, read the `error:` lines, and
help the user fix them. Do not proceed to run a broken build. If the output is
empty or unclear, re-run without the grep filter to get full output for
diagnosis.

4. **Kill every running instance of the app, across all schemes** - not just
   the one being launched. Different schemes can produce different
   executable names (`Screendrop`, `Screendrop Dev`), and leaving an old
   instance from another scheme running is confusing (duplicate menu bar
   icons, port/state conflicts, etc). Kill all known variants unconditionally
   before relaunching:

```bash
killall Screendrop 2>/dev/null
killall "Screendrop Dev" 2>/dev/null
```

(It's fine if these error because that variant wasn't running. If a new
scheme is added later with a different `EXECUTABLE_NAME`, add its `killall`
line here too - check with `EXECUTABLE_NAME` from step 2.)

5. **Run** the freshly built app using the path resolved in step 2:

```bash
open "<BUILT_PRODUCTS_DIR>/<FULL_PRODUCT_NAME>"
```

For the `Screendrop Demo` scheme specifically, pass the demo launch argument
(the scheme's `LaunchAction` sets `--demo-mode`, but `open` won't pass it
automatically):

```bash
open "<BUILT_PRODUCTS_DIR>/Screendrop.app" --args --demo-mode
```

## When to Use

- User says "run it", "build and run", "try it out", "relaunch the app"
- After making code changes, when the user wants to see the change live rather
  than just verify it compiles (for compile-only checks, use `build-screendrop`
  instead)

## Notes

- DerivedData paths are specific to this machine/checkout and can change
  between clean builds - always resolve `BUILT_PRODUCTS_DIR` via
  `-showBuildSettings` (step 2) rather than assuming a fixed path.
- `Screendrop Demo` and plain `Screendrop` share the same `Screendrop.app`
  bundle and `Screendrop` executable name - they're only distinguished by the
  `--demo-mode` launch argument, not by build output.
