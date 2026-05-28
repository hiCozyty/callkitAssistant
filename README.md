# callkitAssistant

A watchOS VoIP calling app with end-to-end encrypted audio streaming. Built with SwiftUI, CallKit, and a custom secure pipeline (mTLS + AES-GCM + Opus codec).

---

## Features

- **CallKit integration** — native call UI, system call handling
- **End-to-end encryption** — mTLS for auth, AES-GCM for audio payload encryption
- **Secure Enclave** — EC private key never leaves the device
- **Voice Activity Detection** — SoundAnalysis with pre-roll buffering and hangover timer
- **Opus codec** — low-latency VoIP audio encoding/decoding
- **UDP transport** — `NWConnection` with heartbeat and viability monitoring
- **Two-phase audio setup** — pre-warms ML models at launch to reduce call start latency

---

## Requirements

- Xcode 16.2+
- watchOS 26.0
- A compatible Bun server (see [server repo](#))

---

## Setup

### 1. Clone & Open

```bash
git clone https://github.com/hiCozyty/callkitAssistant.git
cd callkitAssistant
open callkitAssistant.xcodeproj
```

### 2. Configure Your Server

Open `test-Watch-App-Info.plist` and update these values to match your server:

| Key | Description |
|-----|-------------|
| `serverURL` | Your server's public URL (e.g. `https://your-domain.duckdns.org`) |
| `localHostname` | Your local network hostname for mDNS (e.g. `myserver.local`) |
| `enrollSecret` | The enrollment secret configured on your server |

The plist also contains:

- `NSAppTransportSecurity → NSAllowsArbitraryLoads` — required for local HTTP connections
- `NSBonjourServices → _watchapp-enroll._tcp` — for device enrollment discovery
- `UIBackgroundModes → voip` — for background call handling

### 3. Privacy Permissions

The project's build settings (`project.pbxproj`) include the following privacy descriptions, which Xcode merges into the Info.plist at build time (`GENERATE_INFOPLIST_FILE = YES`):

| Key | Value |
|-----|-------|
| `NSLocalNetworkUsageDescription` | Local network access for VoIP server discovery and audio streaming |
| `NSMicrophoneUsageDescription` | Microphone access for real-time calling |

To customize these messages, edit the `INFOPLIST_KEY_*` entries in Build Settings for the `callkitAssistant Watch App` target.

### 4. Build

Xcode will automatically resolve Swift Package dependencies on first build. No manual `swift package resolve` needed.

---

## Dependencies

Managed via Swift Package Manager (configured in Xcode):

| Package | Source |
|---------|--------|
| `swift-opus` | [github.com/alta/swift-opus](https://github.com/alta/swift-opus) ≥ 0.0.2 |
| `swift-certificates` | [github.com/apple/swift-certificates](https://github.com/apple/swift-certificates) ≥ 1.18.0 |

Transitive dependencies (auto-resolved): `swift-asn1`, `swift-crypto`.

---

## Architecture

### Call Flow

```
┌─────────────┐    ┌──────────────┐    ┌──────────────┐
│  ContentView│─▶ │ CallManager  │─▶ │  CallKit     │
│  (UI State) │    │ (CXProvider) │    │  (System)    │
└──────┬──────┘    └──────┬───────┘    └──────┬───────┘
       │                  │                   │
       ▼                  ▼                   ▼
┌─────────────────────────────────────────────────────┐
│              Audio Pipeline                          │
│                                                     │
│  AudioStreamManager  ◄── didActivate ──► AVAudioEngine
│  ├─ VAD (SoundAnalysis)                            │
│  ├─ Opus Encode/Decode                             │
│  └─ Pre-roll Buffer + Hangover Timer                │
│                                                     │
│  SecurityManager                                    │
│  ├─ mTLS (NWConnection + client cert)              │
│  ├─ Session Key Handshake                          │
│  └─ AES-GCM Encrypt/Decrypt                        │
│                                                     │
│  UDPManager                                         │
│  ├─ NWConnection (UDP)                             │
│  ├─ Heartbeat (10s)                                │
│  └─ Send/Receive Loop                              │
└─────────────────────────────────────────────────────┘
```

### Enrollment Flow

1. Device generates EC key in Secure Enclave
2. Creates CSR (Certificate Signing Request) via `swift-certificates`
3. POSTs CSR + `enrollSecret` to server `/enroll` endpoint
4. Server returns signed client certificate
5. Certificate stored in Keychain — used for mTLS on all subsequent connections

### Call Pipeline

1. User taps Start Call → CallKit creates outgoing call
2. `CXProvider` activates audio session → `didActivate` fires
3. `AVAudioEngine` starts with Voice Processing I/O
4. VAD detects speech → Opus encodes → AES-GCM encrypts → UDP sends
5. Incoming UDP packets → decrypt → Opus decode → `AVAudioPlayerNode` plays

---

## Project Structure

```
callkitAssistant App/
├── callkitAssistantApp.swift   # @main entry point
├── ContentView.swift           # UI: enrollment, call controls, server check
├── CallManager.swift           # CallKit: CXProvider, CXCallController
├── AudioStreamManager.swift    # Audio: AVAudioEngine, Opus, VAD, pre-roll
├── SecurityManager.swift       # Security: mTLS, enrollment, AES-GCM
├── UDPManager.swift            # Network: UDP transport, heartbeat
├── AppConfig.swift             # Server config, debug IP override
├── Models.swift                # Codable response models
├── Extensions.swift            # Notification.Name extensions
└── ca.crt                      # CA certificate for mTLS verify

test-Watch-App-Info.plist       # Info.plist overrides
callkitAssistant.xcodeproj/     # Xcode project (SPM configured)
```

---

## Debugging

- **Simulator mode** — bypasses CallKit, runs audio pipeline directly for testing
- **Debug hostname override** — `AppConfig.resolvedServerHostname` returns a hardcoded IP in `DEBUG` builds
- **Reset enrollment** — the UI includes a "Reset Enrollment (Debug)" button to delete the client cert from Keychain
- **Timing logs** — every major step logs `[timestamp] message T+Xms` for performance analysis

---


A few notes:

1. **`ca.crt`** is committed to the repo — replace with your actual CA cert.

2. **`DEVELOPMENT_TEAM`** (`M43W22ZRQV`) is hardcoded in `project.pbxproj`. Anyone cloning this will need to change it to their own team in Xcode. 
3. **`PRODUCT_BUNDLE_IDENTIFIER`** is `com.cozyty.callkitAssistant.watchkitapp` — need to change it to their own bundle ID.


## License

MIT — see [LICENSE](./LICENSE)
