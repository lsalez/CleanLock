# AGENTS.md

CleanLock — native macOS menu bar app (Swift + SwiftUI + AppKit) that temporarily blocks
keyboard/pointer input so you can wipe your MacBook. No external dependencies: no SPM,
no CocoaPods, no CI, no test target, no linter/formatter.

## Commands

`Scripts/build.sh` is the single entry point for every build/install task.

```bash
./Scripts/build.sh debug                    # fast debug build (swiftc, no Xcode) -> build/Debug/CleanLock.app
./Scripts/build.sh debug --arch universal   # debug build for arm64 + x86_64
./Scripts/build.sh release                  # Release build (xcodebuild, universal) -> build/Release/CleanLock.app
./Scripts/build.sh install                  # Release build + copy to /Applications (+ sign)
./Scripts/build.sh run                      # debug build + launch
./Scripts/build.sh package                  # Release build -> build/dist/CleanLock.zip
./Scripts/build.sh clean                    # remove build/ and the Swift module cache
./Scripts/build.sh help
```

- `debug` prints the `.app` path on stdout; every other message goes to stderr.
- `install` honours `CLEANLOCK_INSTALL_DIR` (default `/Applications`) and falls back to `sudo`
  when the destination is not writable. `--no-sign` skips the signature.
- `CLEANLOCK_SIGN_IDENTITY` overrides the codesigning identity. When it is not set the script
  auto-detects `Developer ID Application` → `Apple Development` → ad-hoc (`-`). `package` always
  falls back to ad-hoc unless the identity is set explicitly, because a development certificate
  is unknown to the machines of the end users.
- **Never ship the bundle unsigned.** macOS matches the Accessibility and Input Monitoring grants
  against the code signature of the running binary, so an unsigned (or `codesign`-less) bundle can
  never be granted those permissions. An ad-hoc signature works but its designated requirement is
  the `cdhash`, so the grants are lost on every rebuild; a real certificate keeps them.
- `Scripts/build-debug.sh` and `Scripts/run-debug.sh` are thin wrappers kept for convenience;
  they delegate to `build.sh`.
- `Scripts/reset-dev-state.sh` kills the app, wipes UserDefaults and resets the TCC grants
  (Accessibility + Input Monitoring) for `dev.cleanlock.CleanLock`.
- Xcode build (equivalent to `build.sh release`):
  ```bash
  xcodebuild -project CleanLock.xcodeproj -scheme CleanLock -configuration Release \
    -destination 'generic/platform=macOS' build
  ```
  Without `-destination` xcodebuild silently builds **arm64 only** — always pass it.
- Output lands in `build/` (gitignored). Module cache: `/private/tmp/cleanlock-module-cache`.
- **No tests, lint, or typecheck step exist.** "Verification" = the app compiles under *both*
  build paths and you manually exercise the flow. If you add a test target, it must be created
  in Xcode (none exists today).

## Adding or moving a Swift file — two registration places

The Xcode project uses plain groups (not a synchronized root group), and `Scripts/build.sh` has a
hardcoded `SWIFT_SOURCES` array. A new file is **silently skipped by the CLI build** (→ "cannot
find X in scope" even though Xcode builds fine) unless you edit both:

1. `Scripts/build.sh` → the `SWIFT_SOURCES` array.
2. `CleanLock.xcodeproj/project.pbxproj` → `PBXFileReference` + `PBXBuildFile` + group children +
   `PBXSourcesBuildPhase`.

Git history shows both files are always updated in the same commit — keep that convention.

## Version numbers live in two places

- `MARKETING_VERSION` in `CleanLock.xcodeproj/project.pbxproj` (Debug + Release configs) — the
  single source of truth. `build.sh` reads it (plus `CURRENT_PROJECT_VERSION` and
  `MACOSX_DEPLOYMENT_TARGET`) out of the pbxproj and renders the bundle plist from it.
- The `"1.0.2"` fallback in `SettingsView.appVersionText` (only used if the bundle plist is
  missing the key).

## One Info.plist source

`CleanLock/Resources/Info.plist` is the only plist in the repo. Xcode expands its
`$(MARKETING_VERSION)`-style variables itself; `build.sh` renders the same file with `sed` for
the CLI build, substituting the values read from the pbxproj. Adding a key therefore covers both
build paths — do not reintroduce a second literal plist.

## Localization: hand-rolled, not `.strings`

All user-facing copy lives in `CleanLock/Models/Localization.swift`:
`AppStrings.Key` enum + `englishText(for:)` + `russianText(for:)`. Adding a string requires
**three edits in that one file** (enum case + English switch + Russian switch). The switches are
exhaustive, so a missing case is a compile error — good.

- `en.lproj` / `ru.lproj` `InfoPlist.strings` only cover `NSInputMonitoringUsageDescription`.
- English **and** Russian are mandatory; the app has no other locale.
- Pattern in every view/controller:
  ```swift
  private func text(_ key: AppStrings.Key) -> String {
      AppStrings.text(key, language: preferences.appLanguage)
  }
  ```
  Pass the language explicitly. `AppStrings.text`'s default arg reads `UserDefaults` directly.
- Language changes post `.appLanguageDidChange`; the menu bar rebuilds on it, SwiftUI views
  re-render because `PreferencesStore.appLanguage` is `@Published`.

## Architecture / flow

`CleanLockApp` (`@main` SwiftUI `App`, `Settings` scene) → `AppDelegate` →
`MenuBarController` (NSStatusItem + menu, owns the onboarding window) →
`CleaningModeManager.shared` (the orchestrator).

`CleaningModeManager` owns the state machine (`CleaningModeState`: inactive → starting → active →
unlocking(progress) → stopping) and starts/stops every subsystem:

| Piece | File | Role |
|---|---|---|
| Event tap | `Managers/InputBlocker.swift` | CGEventTap (`cghidEventTap`) blocks keys/clicks/scroll; detects both Command keys for 3 s to unlock |
| Overlay | `Managers/OverlayManager.swift` | One borderless `NSWindow` per screen at `.screenSaver` level; main screen gets the UI, others get a plain dim |
| HID seize | `Managers/PointerDeviceSeizer.swift` | IOHIDManager exclusive seize of mouse/touchpad |
| Cursor | `Managers/CursorController.swift` | Hides cursor and decouples it from the mouse |
| Permissions | `Managers/PermissionManager.swift` | Accessibility + Input Monitoring checks |
| Prefs | `Managers/PreferencesStore.swift` | UserDefaults (`dev.cleanlock.CleanLock` domain) + `SMAppService` launch-at-login |

Feature work normally goes through `CleaningModeManager`; views only observe `OverlayState`.

## Input-blocking safety rules

This app can lock the user's keyboard. Treat these as non-negotiable:

- **Never shorten or remove the 3-second two-Command hold** (`InputBlocker.unlockDuration`) or the
  auto-unlock timer. Both are the only exits from a locked state.
- Every new subsystem must be wired into **all three** paths in `CleaningModeManager`:
  `startCleaningMode()` (success), the `catch` rollback, and `stopCleaningMode()`. A subsystem
  started but not stopped leaves the user with a seized mouse or hidden cursor.
- `handleSystemWillSleep` and `handleDisplayConfigurationChanged` force a stop; overlay windows
  are bound to screen layout and must be rebuilt if it changes.
- `InputBlocker` is **not** `@MainActor` (its CGEventTap callback runs on the run loop) and uses
  `NSLock` for its state. Its callbacks hop to main via `Task { @MainActor in }` /
  `DispatchQueue.main.async` — keep that pattern when adding callbacks.
- macOS can disable the tap (`.tapDisabledByTimeout` / `.tapDisabledByUserInput`); the handler must
  re-enable it or report via `onFailure` so `CleaningModeManager` restores control.
- New animations must respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
  (see `OverlayManager`, `AnimatedLockIcon`).

## Conventions

- `@MainActor` on every `ObservableObject` manager and SwiftUI view.
- Singletons via `.shared` (`PreferencesStore`, `PermissionManager`, `CleaningModeManager`,
  `SettingsWindowController`). `CleaningModeManager` also has an explicit init for injection.
- Identifiers, comments, and logs in English. The repo carries almost no comments — match that.
- `UserDefaults` keys live in `PreferencesStore.Keys`; add new ones there, not inline.
- macOS deployment target 13.0; `SWIFT_VERSION = 5.0` (Swift 5 language mode) — do not use
  Swift 6-only concurrency syntax.
- `CODE_SIGNING_ALLOWED = YES`, `CODE_SIGN_IDENTITY = "-"`, `CODE_SIGN_STYLE = Manual`: Xcode
  produces an ad-hoc signed bundle; `build.sh` re-signs local builds with the detected identity.

## Permissions

Accessibility (`AXIsProcessTrusted`) **and** Input Monitoring (`IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`)
are both required to start cleaning mode. Use `./Scripts/reset-dev-state.sh` to re-test the
onboarding/permission flow from scratch.

The app must *request* the permissions, not only poll for them: `AXIsProcessTrustedWithOptions`
with `kAXTrustedCheckOptionPrompt` registers it in the Accessibility list, and `IOHIDRequestAccess`
registers it in the Input Monitoring list. Without those calls the app never shows up in either
list. `PermissionManager` also re-checks on `NSApplication.didBecomeActiveNotification`, because
that is when the user comes back from System Settings.

## Release

Manual, not scripted beyond packaging: `./Scripts/build.sh package` produces
`build/dist/CleanLock.zip` (the `CleanLock.app` bundle at the zip root) for GitHub Releases.
Users must run `sudo xattr -r -c /Applications/CleanLock.app` to clear quarantine.

## Known mismatches (pre-existing, not bugs to fix blindly)

- `README.md` links to `github.com/fromtimo/CleanLock`; the `origin` remote is `github.com:lsalez/CleanLock`.
- `README.md` references `assets/demo-1.0.2.apng` and `cleanlock-demo.mp4`; both are currently
  deleted in the working tree.
- There is no `Developer ID Application` certificate on the machine, so the packaged app is signed
  ad-hoc: its designated requirement is the `cdhash`, and macOS drops the Accessibility/Input
  Monitoring grants on every update. A Developer ID certificate fixes that.
