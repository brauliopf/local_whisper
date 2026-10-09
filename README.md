# local_whisper

A macOS **menu bar** app (no Dock icon) that enables users with multimodal utility functions.
The app currently uses OpenAI models for general requests, and TypeSafe models exclusively to check need for translation.
The app stays out of the way and does four things from global shortcuts:

| Feature | Shortcut | Action |
|---|---|---|
|Encouragement| **⌃⌥E** | Fetch a short encouragement from the backend and show it in a toast |
|Transcription| **⌃⌥W** | Record audio (tap again to stop, Escape to cancel), transcribe and translate through the backend, copy text to the clipboard |
|OCR| **⌃⌥R** | System screenshot picker (drag a region; **Space** for a window; **Escape** to cancel), extract text through the backend, copy to the clipboard |
|Timer| **⌃⌥T** | Start a timer (default 20 minutes; length configurable in Settings). Remaining time shows next to the menu bar icon. Pressing again while running does nothing. |

The backend service token is entered in **Settings** and stored in the **macOS Keychain**. Voice input may be multilingual; the backend transcribes the source language, uses TypeSafe Jev to determine whether translation is needed, and returns English when translation is required. Provider credentials and model choices are owned by the backend; the Mac no longer needs an OpenAI API key.

---

## System architecture

local_whisper is a macOS menu bar client backed by a hosted Fastify API. The Mac app captures user input, handles global shortcuts and local UI, then sends authenticated audio or image data to the backend. The backend validates the app's service token, calls the configured AI providers, and returns only the result needed by the client. Provider credentials remain on the backend; the Mac stores only the backend service token in the macOS Keychain.

The main components and connections are:

- **macOS menu bar app** — Registers global shortcuts, records microphone input, captures screenshots, runs the countdown timer, shows toasts, and copies results to the clipboard.
- **Backend API** — A Fastify service exposing `/encouragements`, `/transcriptions`, and `/image-text`. It authenticates requests with `SERVICE_TOKEN`, applies request limits and timeouts, and coordinates provider calls.
- **AI providers** — The backend uses OpenAI for encouragement, transcription, translation, and image text extraction. TypeSafe Jev optionally classifies transcripts to determine whether translation is needed.
- **Secret storage** — The app stores `SERVICE_TOKEN` in the macOS Keychain. The deployed backend receives `SERVICE_TOKEN`, `OPENAI_API_KEY`, and the optional `TYPESAFE_API_KEY` through its deployment secret configuration.
- **Local telemetry** — The app records operation metadata locally as JSONL. Raw request and response payloads are omitted unless explicitly enabled in Settings.

The request flow is therefore:

```text
Keyboard shortcut or menu action
        ↓
macOS app → HTTPS request with Bearer SERVICE_TOKEN
        ↓
Fastify backend → OpenAI and optional TypeSafe providers
        ↓
macOS app ← result
        ↓
Toast and/or clipboard
```

### Project structure

The Xcode project uses **file-system synchronized** groups: Swift files under `local_whisper/` are picked up by the app target, and files under `local_whisperTests/` are picked up by the test target. You do not need to add new `.swift` files to the pbxproj by hand.

```
.
├── local_whisper.xcodeproj/     Xcode project and workspace configuration
├── local_whisper/               App sources (file-system synchronized with the app target)
│   ├── App/                     SwiftUI entry, AppDelegate, coordinator, status item
│   ├── Encouragement/           ⌃⌥E encouragement toast
│   ├── Voice/                   ⌃⌥W audio recording and transcription
│   ├── Screenshot/              ⌃⌥R screenshot capture and OCR
│   ├── Countdown/               ⌃⌥T countdown timer
│   ├── Shared/                  Backend client, Keychain, telemetry, hotkeys, settings
│   ├── Assets.xcassets/         App assets
│   └── local_whisper.entitlements
├── local_whisperTests/          XCTest sources (file-system synchronized with the test target)
│   ├── CountdownTests.swift
│   └── TimerSettingsTests.swift
├── backend/                     Fastify API service
│   ├── src/                     TypeScript source and tests
│   ├── dist/                    Compiled JavaScript output
│   ├── README.md                High-level backend functionality
│   └── AGENTS.md                Backend developer onboarding and implementation details
├── .github/pull_request_template.md
├── AGENTS.md                    Editing and validation instructions
├── clean-state-checklist.md     Build, architecture, and runtime validation
└── README.md
```

The `local_whisper/` and `local_whisperTests/` directories are separate
file-system synchronized groups. Swift files placed in the first directory are
picked up by the app target; files placed in the second are picked up by the
test target. New Swift files do not need to be added to the `.pbxproj` by hand.

### macOS app internals

- `local_whisperApp` is an `LSUIElement` with a Settings scene only. `AppDelegate` owns the menu bar `NSStatusItem`.
- `AppDelegate` owns a single `AppCoordinator`. Hotkeys register in `applicationDidFinishLaunching` so launch is not blocked.
- `AppCoordinator` is last-action-wins between encouragement, voice, and screenshot; the timer runs independently; toasts, clipboard operations, and Settings are coordinated centrally.
- Views stay thin. Each feature is an `@Observable` type. Screenshot extraction, encouragement, and transcription use the authenticated `BackendClient`. Secrets never live in source files.

---

## Requirements

- A Mac running **macOS 26.5+** (see `MACOSX_DEPLOYMENT_TARGET` in the project)
- **Xcode** with the matching macOS SDK
- An **Apple ID** / development team for code signing (Xcode Automatic signing)
- A deployed backend URL and service token (see [`backend/README.md`](backend/README.md))

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

**Settings…** → paste the backend service token → **Save**. The production backend URL is configured by default. The backend owns provider credentials and model selection.

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
