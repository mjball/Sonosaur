# Sonosaur 🦕🔊

> The old Sonos app is extinct. Long live the tiny menu-bar dino.

A native macOS menu bar app that shows one volume slider per Sonos device on your local network. No cloud. No login. No dinosaur of an official app.

## What it does

Click the speaker icon in your menu bar → see every Sonos room with a live volume slider. Drag a slider → that speaker changes volume within ~1 second. Works over your LAN directly via the Sonos UPnP/SOAP interface on port 1400 — nothing leaves your home network.

## Requirements

- macOS 13.0+
- Xcode 15+ (to build)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Sonos players on the same LAN subnet

## Build & run

```bash
xcodegen generate
open Sonosaur.xcodeproj
# Press ⌘R in Xcode
```

Or from the command line:

```bash
xcodegen generate
xcodebuild -project Sonosaur.xcodeproj -scheme Sonosaur -configuration Debug build
```

On first launch, macOS will ask for **Local Network** access — approve it so Sonosaur can find your speakers.

## How discovery works

No SSDP multicast (that requires an Apple provisioning entitlement). Instead:

1. Load cached player IPs from `UserDefaults`.
2. If any are reachable, ask one for the full household via `ZoneGroupTopology`.
3. If nothing cached, TCP-scan the local `/24` on port 1400 (concurrency-limited, 1-second timeout per host), then enumerate via topology.
4. Cache the discovered IPs for instant relaunch next time.

## Roadmap / not-yet-done

- [ ] Per-device mute toggle
- [ ] Now playing display
- [ ] Group/zone volume
- [ ] Launch at login
- [ ] Notarization / proper distribution
- [ ] Custom 🦕 app icon
