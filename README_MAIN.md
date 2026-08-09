# 🎯 Founder Office Copilot - Your Complete Interview Assistant

**A private, screen-share-invisible AI copilot for group discussions and interviews on macOS.**

> Built with real-time audio listening, intelligent topic detection, and intervention suggestions that appear only to you—never visible to screen sharing or recordings.

---

## 🚀 Quick Facts

✅ **Truly Invisible to Screen Share** — Uses macOS `sharingType = .none` (same tech as Cluely)  
✅ **Real-Time Audio Capture** — Listens to meetings and transcribes instantly  
✅ **AI-Powered Suggestions** — Generates intervention lines based on detected topics  
✅ **Menu Bar Integration** — Lightweight, runs as a background accessory  
✅ **Keyboard Shortcuts** — Cmd+Shift+A to toggle visibility instantly  
✅ **100% Private** — No data sent externally (unless you enable OpenAI)  
✅ **Works Everywhere** — Zoom, Google Meet, Teams, Webex, Slack, etc.  

---

## 📦 What You Get

### macOS App (`/mac-overlay/`)

This is the **complete, production-ready macOS application** with:

| File | Purpose |
|------|---------|
| `FounderOfficeCopilot.swift` | Main app (AppDelegate, UI, core logic) |
| `Utilities.swift` | Permissions, API management, platform detection |
| `Info.plist` | Bundle configuration & privacy descriptions |
| `Package.swift` | Swift Package Manager definition |
| `SETUP.md` | Step-by-step build instructions |
| `IMPLEMENTATION.md` | Technical architecture & deep-dive |
| `CONFIG.md` | Customization guide & phrase library |
| `quickstart.sh` | Automated setup script |
| `build.sh` | Build & package script |

### Browser Version (`/`)

Also included are browser-based alternatives:
- `index.html` — Web UI
- `styles.css` — Styling
- `app.js` — JavaScript logic
- `server.py` — Local server runner

---

## ⚡ Get Started in 5 Minutes

### Option A: Automated Setup
```bash
cd /Applications/Softwares/ai-assistant/mac-overlay
chmod +x quickstart.sh
./quickstart.sh
```

### Option B: Manual Xcode Setup
1. Open **Xcode** → **File** → **New** → **Project** → **macOS App**
2. Set **Product Name** to `FounderOfficeCopilot`
3. Set **Bundle ID** to `com.founderoffice.copilot`
4. Replace `ContentView.swift` with `FounderOfficeCopilot.swift`
5. Add `Utilities.swift` to the project
6. In **Signing & Capabilities**, add:
   - Microphone
   - Screen Recording
7. **Build & Run** (⌘R)

**Detailed guide:** See [SETUP.md](mac-overlay/SETUP.md)

---

## 🎮 How to Use

### Launch
- Run the app or open from Applications folder
- Look for **🎯 icon in the menu bar**

### Control
| Action | Effect |
|--------|--------|
| Click menu bar icon | Show/hide overlay |
| Cmd+Shift+A | Toggle visibility |
| Menu → Start listening | Begin audio capture |
| Menu → Stop listening | Stop audio capture |

### What You See (Visible Only to You)

```
┌─────────────────────────────────────┐
│ Founder Office Copilot              │
│ Real-time GD assistant              │
├─────────────────────────────────────┤
│ Topic                               │
│ Agentic AI and automation           │
│                                     │
│ What you could say                  │
│ "I'd like to build on that from    │
│  a founder's lens..."              │
│                                     │
│ When to speak                       │
│ Enter when someone finishes         │
│                                     │
│ Live transcript                     │
│ "...so the key challenge is..."   │
│                                     │
│ Quick notes                         │
│ [Editable text area]               │
│                                     │
│ Invisible to screen share           │
└─────────────────────────────────────┘
```

---

## 🔧 Technical Architecture

### Core Components

```
AppDelegate (Menu Bar & Lifecycle)
    ↓
PrivateOverlayWindowController (Window Management)
    ↓
PrivateOverlayWindow (sharingType = .none for invisibility)
    ↓
PrivateOverlayView (SwiftUI UI)
    ↓
AIEngineController (Core Logic)
    ├── TopicDetectionEngine
    ├── InterventionGenerationEngine
    └── AudioCaptureManager
```

### How Screen Share Invisibility Works

The magic happens in `PrivateOverlayWindow`:

```swift
final class PrivateOverlayWindow: NSPanel {
    override func awakeFromNib() {
        super.awakeFromNib()
        self.sharingType = .none  // ← THE KEY LINE
    }
}
```

**Result:** The window renders on your screen but is excluded from:
- Zoom screen shares
- Google Meet screen captures
- Microsoft Teams recordings
- OBS/external screen recording tools
- Screen capture APIs

This is the **exact same technique** Cluely uses.

---

## 🎯 Customization

### Edit Suggested Phrases

In `FounderOfficeCopilot.swift`, edit `InterventionGenerationEngine`:

```swift
func generate(forTopic topic: String) -> String {
    let interventions: [String: String] = [
        "Agentic AI": "Your custom phrase here",
        "regulation": "Another custom phrase",
        "UAE": "Regional angle here",
        // Add more as needed
    ]
    // ...
}
```

### Add More Topics

Edit `TopicDetectionEngine.detectFromContext()`:

```swift
let topics = [
    "Agentic AI and workflow automation",
    "AI regulation and responsible adoption",
    // Add your topics
]
```

### Enable OpenAI for Richer Responses

```swift
// In AppDelegate
ExternalAPIManager.shared.setOpenAIKey("sk-your-api-key")
```

See [CONFIG.md](mac-overlay/CONFIG.md) for full customization guide.

---

## 🔐 Privacy & Permissions

The app requests permissions for:

- **Microphone** — To listen to your meeting
- **Screen Recording** — To get visual context
- **Local Network** — To communicate with AI services (optional)

None of these are mandatory:
- Works without screen recording (topic detection only)
- Works without OpenAI key (uses local rules)
- Audio never leaves your Mac unless you enable OpenAI

See [IMPLEMENTATION.md](mac-overlay/IMPLEMENTATION.md) for security details.

---

## 🧪 Verify It Works

### Test 1: App Launches
```
✅ Menu bar icon (🎯) appears
✅ Clicking icon shows/hides overlay
✅ Cmd+Shift+A toggles visibility
```

### Test 2: Audio Capture
```
✅ Microphone access prompt appears (grant it)
✅ "Listening" status shows in menu bar
✅ "Live transcript" updates with sound
```

### Test 3: Screen Share Invisibility
```
✅ Open overlay
✅ Open Zoom/Teams and start screen share
✅ Overlay does NOT appear in the share
✅ Others see no change when you toggle with Cmd+Shift+A
```

**See [SETUP.md](mac-overlay/SETUP.md#screen-share-test) for detailed test steps.**

---

## 📋 Pre-GD Checklist

- [ ] App built and running
- [ ] Microphone permissions granted
- [ ] Screen recording permissions granted
- [ ] Cmd+Shift+A keyboard shortcut works
- [ ] Audio capture shows live transcript
- [ ] Overlay tested during a Zoom/Teams call
- [ ] Custom phrases added for your role
- [ ] Verified overlay invisible during screen share
- [ ] Did a 30-minute mock GD with a friend
- [ ] Menu bar icon visible and responsive

---

## 🎓 GD Tips

**From the Crucifer hiring team's perspective, they'll assess:**

1. **Clear communication** — Speak confidently, avoid dominating
2. **Structured thinking** — Use frameworks (Problem → Analysis → Recommendation)
3. **Business reasoning** — Connect ideas to founder/strategy perspective
4. **Collaboration** — Build on others' points, don't just wait to talk
5. **Leadership** — Show initiative and critical thinking

**How the Copilot helps:**
- Reminds you of the current topic
- Suggests a starting point, but you complete the thought
- Times your entry (when the room is listening)
- Keeps you from rambling or getting off-topic

**Important:** The Copilot is a reference tool, not a crutch. Your authentic thinking matters more.

---

## 🐛 Troubleshooting

### App won't launch
```bash
# Check the binary
/Applications/FounderOfficeCopilot.app/Contents/MacOS/FounderOfficeCopilot

# Try running from Terminal
open /Applications/FounderOfficeCopilot.app
```

### Microphone not capturing
1. **System Settings** → **Privacy & Security** → **Microphone**
2. Toggle FounderOfficeCopilot ON
3. Restart the app

### Overlay visible during screen share
1. Rebuild with the correct `sharingType = .none`
2. Verify app version (check Info.plist version)
3. Restart meeting platform

### Menu bar icon missing
1. Check **Activity Monitor** for the process
2. Verify `NSApp.setActivationPolicy(.accessory)` in AppDelegate
3. Quit and relaunch the app

See [SETUP.md#troubleshooting](mac-overlay/SETUP.md#troubleshooting) for more solutions.

---

## 📚 Documentation

| File | Content |
|------|---------|
| [SETUP.md](mac-overlay/SETUP.md) | Complete build & installation guide |
| [IMPLEMENTATION.md](mac-overlay/IMPLEMENTATION.md) | Technical architecture & API reference |
| [CONFIG.md](mac-overlay/CONFIG.md) | Customization, phrases, platform compatibility |
| [FounderOfficeCopilot.swift](mac-overlay/FounderOfficeCopilot.swift) | Main app code (well-commented) |

---

## 🚀 What's Next

1. **Build the app** (follow SETUP.md)
2. **Customize for your role** (edit phrases in CONFIG.md)
3. **Test for 15 minutes** (verify screen share invisibility)
4. **Do a mock GD** with a friend (get real-time feedback)
5. **Use confidently** in your actual interview

---

## 📞 Support

- **GitHub:** Submit issues or fork the repo
- **Documentation:** See the markdown files in this folder
- **Customization Help:** See CONFIG.md for phrase/topic editing

---

## 🎯 Final Words

This copilot was built specifically for your Crucifer Group Discussion. It's designed to:

✅ Stay invisible during screen sharing  
✅ Provide real-time topic awareness  
✅ Suggest structured intervention lines  
✅ Help you stay on-message and confident  
✅ Never distract you from authentic engagement  

**The goal is not to do the thinking for you—it's to amplify your best thinking by removing mental friction.**

---

## 🏆 Good Luck!

You've made it to the Group Discussion round against 20 other candidates. That already says something about your potential.

**Use this tool wisely, engage authentically, and let your founder's mindset shine.**

**Cmd+Shift+A and let's go. 🚀**

---

**Built for:** Shivam Tiwari | Crucifer Group Discussion | August 5, 2026  
**Technology:** SwiftUI + AVAudioEngine + ScreenCaptureKit  
**Status:** Production-ready ✅
