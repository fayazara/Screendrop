---
name: release-screendrop
description: "Release the Screendrop macOS app to GitHub using the screendrop-release CLI tool. Use this skill whenever the user wants to publish a new version, create a release, ship an update, push a release to GitHub, or update the appcast. Also use when they mention DMG creation, Sparkle signing, or anything related to distributing a new Screendrop version."
---

# Release Screendrop

This skill handles releasing new versions of Screendrop to GitHub using a custom Go CLI tool.

## Prerequisites

Before releasing, the user must have:

1. **Exported Screendrop.app** to `~/Downloads/Screendrop.app` from Xcode (Archive > Export after notarization)
2. **Bumped version numbers** in Xcode (`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`)
3. The following tools installed: `create-dmg` (brew), `gh` (GitHub CLI), `git`
4. The Sparkle `sign_update` binary available in DerivedData (built automatically when the project is built in Xcode)

## The Release CLI

The release tool is a Go binary built from source in the project:

```
/Users/fayazahmed/Developer/fayazara/mac/OpenShot/cmd/screendrop-release/
```

### What it does (in order)

1. **Preflight checks** -- verifies `create-dmg`, `gh`, `git`, and Sparkle's `sign_update` are available
2. **Validates Screendrop.app** -- reads version and build number from `~/Downloads/Screendrop.app/Contents/Info.plist`, checks for Sparkle keys (`SUFeedURL`, `SUPublicEDKey`)
3. **Collects release notes** -- prompts for bullet points (one per line, empty line to finish)
4. **Creates DMG** -- uses `create-dmg` to package `~/Downloads/Screendrop.app` into `~/Downloads/Screendrop.dmg`
5. **Signs DMG** -- runs Sparkle's `sign_update` to generate an EdDSA signature
6. **Updates appcast.xml** -- parses the existing appcast in the repo, prepends a new `<item>` entry with version info, signature, and download URL, then writes it back
7. **Git push** -- commits and pushes the updated `appcast.xml` to `main`
8. **Creates GitHub release** -- uses `gh release create` to create a tagged release with the DMG attached

### Running it

The tool is interactive (prompts for release notes and confirmation), so it needs to be run in a terminal the user can interact with. You cannot run it directly via a non-interactive shell.

Guide the user to build and run:

```bash
cd /Users/fayazahmed/Developer/fayazara/mac/OpenShot && go run ./cmd/screendrop-release/
```

Or build a binary first:

```bash
cd /Users/fayazahmed/Developer/fayazara/mac/OpenShot && go build -o screendrop-release ./cmd/screendrop-release/ && ./screendrop-release
```

### Environment

- The tool auto-detects the repo at `~/Developer/fayazara/mac/OpenShot` or `~/Developer/fayazara/mac/Screendrop`. Override with `SCREENDROP_REPO` env var.
- GitHub repo target: `fayazara/screendrop`
- Git branch: `main`
- DMG volume name: `Screendrop`
- Minimum macOS version: `26.4`

## Sparkle Configuration

The Sparkle auto-update framework is fully configured:

- **SUFeedURL**: `https://raw.githubusercontent.com/fayazara/screendrop/main/appcast.xml`
- **SUPublicEDKey**: `MA/6n0fqT0T2updDlkXr8BjhJKoHWik9uf6Lh5pUG7U=`
- **UpdaterManager.swift**: Singleton, starts at launch (Release builds only), menu bar + Settings UI integration

## Workflow Guide

When the user wants to release, walk them through this checklist:

1. Confirm they've bumped the version in Xcode
2. Confirm they've archived, notarized, and exported `Screendrop.app` to `~/Downloads/`
3. Have them run the release CLI
4. After it completes, verify the GitHub release was created successfully

If something goes wrong mid-release (e.g., signing fails, git push fails), help debug using the error output from the CLI. Common issues:
- **Screendrop.app not found** -- they need to export from Xcode first
- **sign_update not found** -- they need to build the project in Xcode so DerivedData has the Sparkle artifacts
- **gh auth** -- they may need to run `gh auth login` first
- **Build already in appcast** -- they may have forgotten to bump the build number
