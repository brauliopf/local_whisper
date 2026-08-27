# local_whisper

A macOS **menu bar** app (no Dock icon) that stays out of the way and does three things from global shortcuts:

| Shortcut | Action |
|---|---|
| **⌃⌥E** | Fetch a short encouragement from OpenAI and show it in a toast |
| **⌃⌥W** | Record audio (tap again to stop, Escape to cancel), transcribe, copy text to the clipboard |
| **⌃⌥R** | System screenshot picker (drag a region; **Space** for a window; **Escape** to cancel), extract text, copy to the clipboard |

The OpenAI API key is entered in **Settings** and stored in the **macOS Keychain**. Chat and transcription models are chosen there too (defaults `gpt-4o-mini` and `gpt-4o-mini-transcribe`).

---

## Project structure

The Xcode project uses a **file-system synchronized** group: Swift files under `local_whisper/` are picked up automatically. You do not need to add new `.swift` files to the pbxproj by hand.

```
local_whisper/
├── local_whisper.xcodeproj/     Xcode project
├── local_whisper/               App sources (synced into the target)
│   ├── App/                     SwiftUI entry, AppDelegate, AppCoordinator
│   ├── Encouragement/           ⌃⌥E toast
│   ├── Voice/                   ⌃⌥W record + transcribe
│   ├── Screenshot/              ⌃⌥R OCR
│   ├── Shared/                  OpenAI client, Keychain, hotkeys, toast, Settings
│   ├── local_whisper.entitlements  Hardened Runtime audio-input
│   └── Assets.xcassets
├── .github/pull_request_template.md
└── AGENTS.md                    PR conventions
```

**How the pieces fit**

- `local_whisperApp` is a `MenuBarExtra` agent (`LSUIElement`). There is no main window.
- `AppDelegate` owns a single `AppCoordinator`. Hotkeys register in `applicationDidFinishLaunching` so launch is not blocked.
- `AppCoordinator` is last-action-wins between encouragement, voice, and screenshot; toasts; clipboard; Settings when the key is missing.
- Views stay thin. Each feature is an `@Observable` type. Network calls go through one `OpenAIClient` actor with `Codable` request types. Secrets never live in source files.

---

## Requirements

- A Mac running **macOS 26.5+** (see `MACOSX_DEPLOYMENT_TARGET` in the project)
- **Xcode** with the matching macOS SDK
- An **Apple ID** / development team for code signing (Xcode Automatic signing)
- An **OpenAI API key**

---

## Build from source

### 1. Clone and open

```bash
git clone https://github.com/brauliopf/local_whisper.git
cd local_whisper
open local_whisper.xcodeproj
```

### 2. Sign the target

In Xcode: select the **local_whisper** target → **Signing & Capabilities**.

- Enable **Automatically manage signing**
- Choose **your** Team (replace the repo’s development team if needed)

The bundle ID is `brauliopf.local-whisper`. If signing fails, change it to something unique under your team, e.g. `yourname.local-whisper`.

### 3. Run from Xcode

**Product → Run** (`⌘R`). Look for the **sparkles** icon in the menu bar.

**Settings…** → paste your OpenAI API key → **Save**. Optionally pick **Chat** and **Transcribe** models (fetched from OpenAI).

### 4. Command-line build

From the repo root:

```bash
xcodebuild -scheme local_whisper -configuration Debug build
```

Release (for a Finder-launchable `.app`):

```bash
xcodebuild -scheme local_whisper -configuration Release build
```

The product is typically:

```
~/Library/Developer/Xcode/DerivedData/local_whisper-*/Build/Products/Release/local_whisper.app
```

Copy it to `/Applications` if you want it outside Xcode:

```bash
cp -R ~/Library/Developer/Xcode/DerivedData/local_whisper-*/Build/Products/Release/local_whisper.app /Applications/
```

Quit any instance started from Xcode before opening the copy, or you may get two menu bar icons.

---

## First-run permissions

| Feature | Permission |
|---|---|
| **⌃⌥W** | **Microphone** |
| **⌃⌥R** | **Screen Recording** (System Settings → Privacy & Security) |

If a shortcut does nothing, confirm `local_whisper` is allowed for that permission, then restart the app.

---

## Distribution note

A local **Apple Development** signed build is meant for **your** Mac. Sending the `.app` to another machine generally will not work without a **Developer ID** certificate and Apple **notarization**.

---

## License

Personal project. Add a license file if you intend to share the source under specific terms.
