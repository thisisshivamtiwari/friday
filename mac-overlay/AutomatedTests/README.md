# AutomatedTests

Everything in this folder is test infrastructure, kept entirely separate from the Xcode
project (`../FounderOfficeCopilot.xcodeproj` doesn't reference anything here). **Delete this
whole folder any time** - it has zero effect on the app build.

## 1. Swift unit tests (`Sources/`, `Tests/`) - the module tests

Tests the app's actual non-UI logic (state machine, JSON parsing, name filtering, Keychain
round-trips) directly - not a reimplementation. `Sources/FounderOfficeCopilotCore/*.swift`
are **symlinks** into the real `../FounderOfficeCopilot/*.swift` source files, so editing
the app code is what these tests see; nothing is duplicated.

Run:
```bash
cd AutomatedTests
DEVELOPER_DIR="/Users/shivamtiwari/Downloads/Xcode-beta.app/Contents/Developer" swift test
```
(The `DEVELOPER_DIR` override is needed because the system's default Command Line Tools
don't ship XCTest - same reason `xcodebuild` calls for the app itself need it.)

Tests cover:
- `AIEngineControllerTests` - the Start/Stop/mode-toggle state machine (this is what
  regresses the "stuck green dot" / "Stop doesn't stop" class of bug)
- `GeminiLiveMessageParserTests` - parses real captured Gemini Live API server messages
  into events, using fixtures taken from actual session logs, not guesses
- `TeamsParticipantDetectorTests`, `ChatMessageTests`, `KeychainStoreTests` - the other
  pure-logic pieces

Deliberately NOT covered here (needs the real app + your eyes, not a headless test binary):
SwiftUI views, the window/overlay/drag behavior, actual audio hardware, an actual Gemini
network round-trip, actual Teams/Zoom accessibility trees.

### Why some app code has test seams

`AIEngineController` takes an injectable `speechRecognizer: TranscriptSource` and an
`apiKeyProvider` closure. Both exist for a real reason, not just to please a test: the real
`SpeechRecognitionEngine` calls a privacy-gated API that macOS hard-crashes any process
for calling without an Info.plist entry (true of any bare CLI binary), and using the real
`SettingsStore.shared.geminiAPIKey` in a test would open a real network connection with
your actual saved key. Tests inject a no-op stub and a nil key instead.

## 2. Gemini Live API protocol scripts (`api-protocol-scripts/`)

Standalone Python scripts that speak the exact same WebSocket protocol as
`GeminiLiveClient.swift`, for testing the *protocol* against Google's real servers
independent of the Mac app - this is how the "TEXT modality rejected" and "wrong frame
type" issues got diagnosed earlier, before touching Swift code.

Setup (once):
```bash
cd AutomatedTests/api-protocol-scripts
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
```

Run (needs your Gemini API key as an env var - never pass it as a command-line argument,
and never paste it into chat):
```bash
export GEMINI_API_KEY="your-key"
./venv/bin/python3 list_live_models.py      # lists every Live-capable model your key can use
./venv/bin/python3 test_gemini_live.py      # full round-trip test against those models
```

## What's left for you to test manually

Automated tests above cover the logic. They cannot cover:
- Dragging the overlay window
- Screen-share invisibility (needs an actual screen recording/share)
- Real audio hardware (mic input, system audio output via speakers/Bluetooth)
- A real Gemini Live network session end-to-end through the app
- Global hotkeys firing while the app isn't frontmost
- Teams/Zoom accessibility-tree participant detection in a real call
