# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

PlayTools is the core runtime of [PlayCover](https://github.com/PlayCover/PlayCover). It is a dynamic library injected into iOS app executables (IPAs) during installation so they run on macOS via Mac Catalyst. It provides display control, keyboard/mouse/controller keymapping (translated to synthetic touch events), jailbreak-detection bypass, and a keychain replacement (PlayChain).

## Build & Development

Built with Xcode (`PlayTools.xcodeproj`). There are no tests. CI runs SwiftLint with `--strict` on every push and PR (`.github/workflows/SwiftLint.yml`, config in `.swiftlint.yml`), so lint locally before pushing:

```bash
swiftlint --strict
```

Targets:
- **PlayTools** — the framework, built for **iOS platform** (uses iOS-only APIs unavailable on Mac Catalyst)
- **AKInterface** — a **macOS bundle** wrapping AppKit, loaded at runtime by PlayTools (see Architecture)
- **SwordRPC** — Swift Package dependency (Discord Rich Presence)

Development team must be set for both PlayTools and AKInterface targets. Deploy after building for iOS: use `vtool` to convert the binary to maccatalyst, ad-hoc codesign, then either copy the whole `PlayTools.framework` into `/Applications/PlayCover.app/Contents/Frameworks/` (full deploy, relaunch PlayCover) or copy just the binary into `~/Library/Frameworks/PlayTools.framework/` for fast iteration without relaunching PlayCover. Exact scripts are in README.md.

Production PlayCover builds fetch PlayTools via its Cartfile; point it at a local checkout (`git "file:///path/to/playtools" "branch"`) to test changes end-to-end.

## Architecture

### Two-platform split (the key pattern)

PlayTools.framework is compiled for iOS but runs inside a Mac Catalyst process, so it cannot call AppKit directly. Instead:

- `Plugin.swift` (repo root) defines the `@objc(Plugin)` protocol — the full macOS capability surface (cursor control, event monitors, window info, termination).
- `AKPlugin.swift` implements it with AppKit inside the **AKInterface.bundle** target.
- `PlayTools/Utils/AKPluginLoader.swift` loads that bundle from the app's `PlugIns/` directory at startup; everything accesses macOS APIs through `AKInterface.shared` (typed as `Plugin?`).

Changes to macOS-facing behavior usually touch both `Plugin.swift` (protocol) and `AKPlugin.swift` (implementation).

### Injection & startup flow

`PlayLoader.m` is the entry point. Its `__attribute__((constructor))` calls `PlayCover.launch()` (in `PlayCover.swift`), which initializes in order: `AKInterface` → `UserPluginLoader` (dlopens user dylibs from `Frameworks/UserPlugins/`) → `PlayScreen` (display settings) → `PlayInput` (input pipeline) → `DiscordIPC`.

`PlayLoader.m` also installs `DYLD_INTERPOSE` hooks on libc/system functions:
- `uname`/`sysctl`/`sysctlbyname`/`dyld_get_active_platform` — spoof the device model (from PlaySettings) and report iOS
- `SecItemAdd/Update/Delete/CopyMatching`, `SecKeyCreateRandomKey/GeneratePair` — route to `PlayKeychain` when PlayChain is enabled
- `open`/`stat`/`access`/`rename`/`unlink` — fix Unreal Engine double-slash paths (`//Users/...`)
- `usleep` — block sleep-spamming threads when enabled

### Input pipeline (`PlayTools/Controls/`)

`PlayInput.swift` coordinates; actual flow is Frontend → Backend:

- **Frontend/** — `EventAdapter/` subclasses adapt keyboard/mouse/controller events; `ModeAutomaton`/`ControlMode` track the current mode (e.g. normal vs keymap-editing).
- **Backend/** — `PlayAction`/`ActionDispatcher` map input to game actions; `Toucher.swift` dispatches onto `PlayInput.touchQueue` (serial `playcover.toucher` queue) and calls `PTFakeMetaTouch` (`PTFakeTouch/`, uses Objective-C runtime and UIKit private headers) to synthesize real `UITouch` events into the game's key window.
- `DebugOverlay/` visualizes touches; `MenuController.swift` builds in-game menus.

### Other subsystems

- `Editor/` + `Keymap/` — the in-game keymapping editor UI and persisted keymap model.
- `MysticRunes/` — the bypass module: `PlayShadow.m` (jailbreak detection bypass), `PlayedApple.swift`/`PlayedAppleDB.swift` (`PlayKeychain`, SQLite-backed keychain replacement used by PlayChain).
- `DiscordActivity/` — Discord Rich Presence via IPC.

### Settings

`PlaySettings` reads a per-app plist written by PlayCover from `~/Library/Containers/io.playcover.PlayCover/App Settings/<bundle-id>.plist`. Nearly all properties are `lazy` and cached for the process lifetime — changing the plist only takes effect on next game launch. `AKPlugin.swift` reads the same plist independently (it cannot link PlayTools).

### Localization

Strings live in `PlayTools/<lang>.lproj/` but are named `PlayTools.strings` (not `Localizable.strings`) to avoid conflicting with the game's own strings; PlayCover copies them into the game app. Translations are managed in Weblate — don't hand-edit non-English strings.

## Conventions

- Swift code must pass `swiftlint --strict`; ObjC files (PlayLoader.m, PTFakeTouch, MysticRunes, Utils) are exempt from SwiftLint but follow the same style.
- Bridging header: `AKInterface-Bridging-Header.h` exposes `Plugin.swift` to the AKInterface target.
- Git: default branch for PRs is `master`.
