---
name: release-screendrop
description: "Release the Screendrop macOS app to GitHub using the screendrop-release CLI tool. Use this skill whenever the user wants to publish a new version, create a release, ship an update, cut a build, push a release to GitHub, or update the appcast. Also use when they mention archiving, notarization, DMG creation, Sparkle signing, bumping the version/build, or anything related to building and distributing a new Screendrop version."
---

# Release Screendrop

This skill releases new versions of Screendrop using a custom Go CLI
(`cmd/screendrop-release`). The CLI can run **fully automated and
non-interactively**, so a release can be triggered directly from a chat session
(the agent can run it end to end).

There are two modes:

- **Full auto (`-build`)** — archive, export (Developer ID), notarize, staple,
  package, sign, and publish. Nothing in Xcode's GUI is required.
- **Package-only** (no `-build`) — assumes the user already exported a
  notarized `~/Downloads/Screendrop.app` from Xcode, then packages & publishes.

Prefer **full auto** unless the user says they've already exported the app.

## Prerequisites

Always required:

1. Tools installed: `create-dmg` (brew), `gh` (GitHub CLI, authenticated), `git`, `plutil`.
2. The Sparkle `sign_update` binary in DerivedData (created when the project is
   built/archived — the `-build` flow produces it automatically).

For **full auto (`-build`)** additionally:

3. `xcodebuild`, `xcrun`, `ditto` (all part of Xcode / command line tools).
4. A **notarytool keychain profile** named `screendrop-notary` (already set up
   on this machine via an App Store Connect API key). It was created once with:
   ```bash
   xcrun notarytool store-credentials "screendrop-notary" \
     --key /path/to/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```
   If notarization fails with a credentials error, this profile is missing or
   wrong — ask the user to re-run `store-credentials`.

## The Release CLI

Source: `/Users/fayazahmed/Developer/fayazara/mac/OpenShot/cmd/screendrop-release/`

### Flags

- `-build` — run the archive → export → notarize → staple phase first.
- `-set-version <x.y.z>` — set `MARKETING_VERSION` before archiving (and commit it). Used with `-build`.
- `-set-build <n>` — set `CURRENT_PROJECT_VERSION` before archiving (and commit it). Used with `-build`.
- `-scheme <name>` — Xcode scheme to archive (default `Screendrop`).
- `-notes "<text>"` — release notes, one bullet per line (markdown `- ` prefixes are stripped). Skips the interactive prompt.
- `-notes-file <path>` — read release notes from a file instead.
- `-notary-profile <name>` — notarytool keychain profile (default `screendrop-notary`).
- `-yes` / `-y` — assume "yes" for all confirmation prompts (non-interactive).

### Triggering a full release from here (recommended)

1. **Decide the version and build number.** The build number
   (`CURRENT_PROJECT_VERSION`) **must increase** every release or Sparkle won't
   offer the update. Check the current values:
   ```bash
   grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION" \
     Screendrop.xcodeproj/project.pbxproj | sort -u
   ```
   Pick the next `MARKETING_VERSION` (use real dotted semver like `0.20.2`, never
   regress — e.g. don't go `0.19` → `0.2`) and `CURRENT_PROJECT_VERSION` = current + 1.
2. **Make sure code changes are committed and pushed** to `main` first, so the
   release tag points at the released source. (The CLI commits the version bump
   and pushes the appcast, but it does not push your other unrelated commits.)
3. **Run it** (this is non-interactive and safe to run from a tool call):
   ```bash
   cd /Users/fayazahmed/Developer/fayazara/mac/OpenShot && \
   go run ./cmd/screendrop-release -build -yes \
     -set-version <x.y.z> -set-build <n> \
     -notes "First note
   Second note"
   ```
   Notarization blocks for a few minutes — this is expected, not a hang. Use a
   generous tool timeout (~7 min).

### Package-only (app already exported by the user)

```bash
cd /Users/fayazahmed/Developer/fayazara/mac/OpenShot && \
go run ./cmd/screendrop-release -yes -notes "Your notes here"
```

### What it does (in order)

With `-build`:
1. **Set version/build** (if `-set-version`/`-set-build` given) — edits pbxproj and commits.
2. **Archive** — `xcodebuild archive` (scheme `Screendrop`, Release, `generic/platform=macOS`).
3. **Export** — `xcodebuild -exportArchive` with a generated Developer ID `ExportOptions.plist`.
4. **Notarize** — zips the app and runs `xcrun notarytool submit --wait`, verifying `status: Accepted`.
5. **Staple** — `xcrun stapler staple`, then places the app at `~/Downloads/Screendrop.app`.

Then always:
6. **Preflight checks** + **validate** the app's version/build and Sparkle keys.
7. **Collect release notes** (from `-notes`/`-notes-file`, else stdin).
8. **Create DMG** with `create-dmg` → `~/Downloads/Screendrop.dmg`.
9. **Sign DMG** with Sparkle `sign_update` (EdDSA).
10. **Push commits** — push any local commits (e.g. the version bump) to `main`.
11. **GitHub release** — `gh release create vX.Y.Z` with the DMG attached.
12. **Update + push appcast.xml** — prepend the new `<item>` (de-duping any entry for the same build), commit & push to `main`.
13. **Homebrew cask** — regenerate and push the cask to `fayazara/homebrew-tap` (non-fatal).

**Ordering & robustness:** the release is created **before** the appcast is
pushed, so a published appcast never points at a missing release. Network
operations (`gh`, `git push`) are retried with backoff. Re-running a release is
safe: an existing GitHub release gets the DMG re-uploaded (`--clobber`) and the
appcast entry for that build is replaced rather than duplicated. The `-build`
phase also auto-points `DEVELOPER_DIR` at Xcode, so it works even when the
active developer dir is the Command Line Tools.

### Environment / constants

- Repo auto-detected at `~/Developer/fayazara/mac/OpenShot` (override with `SCREENDROP_REPO`).
- GitHub repo: `fayazara/screendrop` · branch: `main` · team: `TB2S44TFQS` · bundle: `com.fayazahmed.Screendrop`.
- DMG volume: `Screendrop` · minimum macOS: `26.4`.

## Sparkle Configuration

- **SUFeedURL**: `https://raw.githubusercontent.com/fayazara/screendrop/main/appcast.xml`
- **SUPublicEDKey**: `MA/6n0fqT0T2updDlkXr8BjhJKoHWik9uf6Lh5pUG7U=`
- **UpdaterManager.swift**: Singleton, starts at launch (Release builds only), menu bar + Settings UI integration.

## After releasing

Verify the release succeeded:
```bash
gh release view v<x.y.z> --repo fayazara/screendrop --json tagName,assets -q '{tag: .tagName, assets: [.assets[].name]}'
```
The CLI pushes the appcast commit itself, so run `git pull --ff-only origin main`
afterward to sync your local `main`.

## Troubleshooting

- **Partial failure / network error mid-release** — just re-run the exact same command. The pipeline is idempotent: an existing GitHub release gets the DMG re-uploaded, and the appcast entry for that build is replaced (not duplicated). Network calls already retry with backoff.
- **notarytool credentials error** — the `screendrop-notary` keychain profile is missing/invalid; have the user re-run `store-credentials`.
- **Notarization "Invalid"** — inspect with `xcrun notarytool log <submission-id> --keychain-profile screendrop-notary` (usually a signing/entitlements issue).
- **`xcodebuild archive` fails** — the CLI prints the last ~40 lines and auto-sets `DEVELOPER_DIR` to Xcode; if it still fails, common causes are signing or a Dev-scheme/`LSUIElement` mismatch. Confirm scheme is `Screendrop` (not `Screendrop Dev`).
- **Screendrop.app not found** (package-only mode) — the user must export from Xcode first, or use `-build`.
- **sign_update not found** — build/archive the project once so DerivedData has the Sparkle artifacts.
- **gh auth** — run `gh auth login`.
- **Build already in appcast** — re-running is safe (the entry is replaced), but a *new* release still needs a higher build number; bump `-set-build`.
- **Version regression** — never set `MARKETING_VERSION` lower (Sparkle compares by build number, but the display string should still read forward, e.g. `0.20.1`, not `0.2`).
