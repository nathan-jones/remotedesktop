# Remote Desktop (proof of concept)

An iPhone, iPad and Mac client for macOS Screen Sharing's High Performance
mode: HEVC video over SRTP/UDP, negotiated through Apple's extended VNC control
channel. Nothing is installed on the Mac being controlled; it only needs Screen
Sharing turned on (Apple silicon, macOS 14 or later).

The protocol is undocumented by Apple.

<p>
  <img src="assets/screenshot-full.png" alt="A Mac desktop filling the screen, with the session controls floating in the top corner" width="58%">
  <img src="assets/screenshot-laptop.png" alt="A half-open folding phone: the Mac desktop on the upper half and a trackpad on the lower half" width="40%">
</p>

## Features

**Connecting**

- Macs with Screen Sharing turned on are found on the local network (Bonjour).
- Saved Macs appear as cards showing their screen as it was last seen, most
  recently used first, with a green dot when the Mac is on the network.
- Passwords are optional to save and are kept in the device keychain.
- Sign-in uses SRP, so the password never leaves the device. Accounts the Mac
  holds no SRP verifier for fall back to the older RSA-wrapped password login.

**Display**

- Hardware HEVC decoding, with each frame shown as soon as it arrives.
- Virtual display: the Mac creates a display sized for the device and rendered
  at its pixel density, and resizes it when the device rotates, folds or the
  window changes size. The Mac's own screen is hidden while connected.
- Or mirror the Mac's physical display instead.
- The pointer is drawn locally from the shape the Mac reports, so it follows
  your finger without waiting for video.
- On a folding device held half open, the video takes the upper half and the
  lower half becomes a trackpad.

**Touch input (iPhone and iPad)**

The screen behaves like a trackpad, so your finger never covers what you are
pointing at.

| Gesture | Action |
| --- | --- |
| Slide one finger | Move the pointer |
| Tap | Click |
| Touch and hold, then slide | Drag |
| Two-finger tap | Right click |
| Two-finger slide | Scroll |
| Three-finger swipe up / down | Mission Control / the app's windows |
| Three-finger swipe left / right | Next / previous Space |
| Slide in from the left edge | App switcher; keep sliding to move through apps |
| Two-finger touch and hold | Ring of Copy, Paste, Screenshot and Undo |

**Keyboard and text**

- On-screen keyboard, and hardware keyboards with modifier keys passed through.
- Write Text: compose with the device's own autocorrect and dictation, then
  send it to the Mac in one go, optionally followed by Return.
- Type Password: types the account password at the Mac's lock screen or an
  administrator prompt.

**Mac app**

- Built with Mac Catalyst. The mouse drives the remote pointer directly, the
  keyboard is always connected, and the session actions sit in the window
  toolbar.

## Layout

- `Sources/ScreenShareKit` – the protocol stack: SRP login, encrypted control
  channel, media negotiation, SRTP, HEVC reassembly and VideoToolbox decoding.
- `Sources/ssprobe` – command-line tool that connects to a Mac, prints what
  arrives and saves the first decoded frame as a PNG.
- `App` – the SwiftUI app for iOS, iPadOS and macOS (Mac Catalyst).
- `Tests` – unit tests (`swift test`).

## Running

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The app
targets iOS 17 and later.

```sh
swift test

# Probe a Mac from another Mac (password from a file or SS_PASSWORD):
swift run -c release ssprobe 192.168.1.20 username --password-file ~/pw.txt

# The app
cd App && xcodegen generate && open RemoteDesktop.xcodeproj
```

Set your own team and bundle identifier in `App/project.yml` (or in Xcode)
before running on a device. Choose the "My Mac (Mac Catalyst)" destination for
the Mac app. Use a Release build for quick logins; the login maths is slow
unoptimised.

## Notes

- The client must be able to bind UDP ports 5900 and 5901 locally, because the
  Mac sends media back to the same port numbers it listens on. A Mac running
  Screen Sharing itself already uses those ports, so test from a different
  machine or a real iPhone/iPad rather than against `localhost`.
- "Use a virtual display" hides the Mac's physical screen for the duration of
  the session; without it the physical display is mirrored.
- Not implemented yet: audio, clipboard sharing between the device and the Mac,
  multi-tile video, and choosing a session when another user is logged in.
