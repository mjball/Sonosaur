# Sonosaur 🦕🔊

> The old Sonos app is extinct. Long live the tiny menu-bar dino.

A native macOS menu bar app that shows one volume slider per Sonos device on your local network. No cloud. No login. No dinosaur of an official app.

## What it does

Click the dino icon in your menu bar → see every Sonos room with a live volume slider. Drag a slider → that speaker changes volume within ~1 second. Works over your LAN directly via the Sonos UPnP/SOAP interface on port 1400 — nothing leaves your home network.

## Install

Download `Sonosaur.app.zip` from [Releases](https://github.com/mjball/Sonosaur/releases), double-click to extract, and drag `Sonosaur.app` to `/Applications`.

Then remove the macOS quarantine flag (required for unsigned apps):

```bash
xattr -cr /Applications/Sonosaur.app
open /Applications/Sonosaur.app
```

> macOS quarantines apps downloaded from the internet that aren't notarized. `xattr -cr` removes that quarantine flag.

## Requirements

- macOS 13.0+
- Sonos players on the same LAN subnet

## How it works

- **Discovery**: reads the kernel ARP table (`arp -a`) to get all recently-seen LAN hosts, fires `ZoneGroupTopology` at them concurrently — finds and enumerates the whole household in one round trip. Caches IPs in `UserDefaults` so relaunch is instant.
- **No SSDP**: avoids multicast (requires an Apple provisioning entitlement). Pure unicast.
- **Volume control**: `RenderingControl#SetVolume` SOAP call to port 1400 on each device, debounced during slider drags.
- **Background refresh**: re-discovers devices every 5 minutes silently.
- **Launch at login**: toggle in the footer of the popover.

## Build from source

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open Sonosaur.xcodeproj   # ⌘R to run
```

## Release

```bash
./Scripts/build-release.sh --release v0.2.0
```

Builds a Release `.app`, packages it as `Sonosaur.app.tar.gz`, and publishes to GitHub Releases. The app is unsigned — see install instructions above for the `xattr` step.
