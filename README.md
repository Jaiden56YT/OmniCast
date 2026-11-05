# OmniCast

Multistreaming for Apple Silicon: one app sends a 16:9 canvas to YouTube, Twitch
and Kick and a 9:16 canvas to TikTok and Instagram at the same time.

It runs on libobs, the OBS engine, taken from the installed `/Applications/OBS.app`
(32.0.4), so every OBS source, filter and encoder is available.

## Why it's fast on an M4

- **Metal renderer** (OBS's new libobs-metal), with OpenGL as a fallback (see Settings).
- **Hardware H.264** through the VideoToolbox media engine (`ave.avc`), never x264.
- **One encode per canvas**: every destination on a canvas shares the same encoder,
  so adding a third horizontal platform costs upload bandwidth, not CPU/GPU.
- NV12 output and CoreAudio AAC: formats Apple's encoders take directly.
- Native arm64 SwiftUI app, no Electron, no Qt.
- Previews draw each canvas's finished frame (no second composite) and pause
  themselves when the window is hidden or minimised.
- App Nap and timer coalescing are held off for the render/encode threads, and
  the Mac can't idle-sleep while recording or live.

## Recording

- Separate constant-quality **HEVC** (or H.264) encode per canvas on the media
  engine, so recordings stay sharp even when the stream is 6 Mbps CBR.
- Record 16:9, 9:16, or both at once (two files), 1080p60.
- Hybrid MP4: the file stays playable even if the app is killed mid-recording.
- Track 1 = full mix, track 2 = desktop audio, track 3 = mic (toggle in Settings).
- Start/stop with the Record button or ⇧⌘R; go live with ⇧⌘L.

Measured on the M4 MacBook Air, recording both canvases at once for 30 s:
1800/1800 frames, every frame exactly 16.7 ms apart, 0 encoder drops.

## What the screen slot captures

Sources → Display has a picker: any **display**, a single **window**, a whole
**app** (all its windows), or a **capture device** such as a capture card
(with its audio). Capture devices are listed second so a capture card is one
click away. The choice is remembered; a window is found again by app and title
next launch, and anything that's gone falls back to the main display.

Only one of screen capture or the capture device runs at a time; the other is
disabled so it doesn't render in the background. A capture card's sound gets its
own mixer channel (stream + headphones) while it's in use. Cards like the Elgato
HD60 X that show up as a video device plus a separate audio input of the same
name are matched automatically.

Hidden or unused cameras and capture cards are closed, not just hidden: the light
goes off, no frames cross USB, and other apps can use them.

## Merged chat

YouTube, Twitch and Kick chat in one overlay, read only (nothing is ever posted):

- **Twitch**: Twitch's official chat connection, anonymously.
- **Kick**: the realtime feed kick.com itself uses (a guest token from Kick's
  realtime API, no login; unofficial).
- **YouTube**: the live-chat feed youtube.com's chat window uses, found from the
  channel's /live page once you're live. No API key or quota; unofficial.
- Instagram doesn't let apps read live chat, so it can't be included.

Lines are drawn in the sona's style: heavy rounded type with a thick black
outline, platform icons, role badges (crown for you, wrench for mods, diamond for
VIPs, star for members), Twitch/Kick name colours and palette colours for YouTube,
inline emotes. Channels, text size and how long lines stay up are in
Settings → Chat; move and resize the box with Arrange. Sources → Chat → ⋯ has
"Add test messages" for setting it up offline.

## Stream info (titles and games)

Controls → **Stream info…** sets one title on YouTube, Twitch and Kick at once,
and the game on Twitch and Kick (searchable, with recent picks and a "Same as
Twitch" button for Kick). It loads what's set now when it opens, and shows a
✓ or the error per platform.

It uses each platform's official API, so each needs a one-time sign-in from
Settings → Accounts, with a free developer app you register yourself:

- **Twitch**: a "Public" app's Client ID; sign in by entering a code at
  twitch.tv/activate.
- **Kick**: Client ID + Secret, redirect `http://localhost:39651/callback`.
- **YouTube**: a Google Cloud "Desktop app" OAuth client with the YouTube Data
  API v3 enabled. It renames the live (or next scheduled) broadcast; YouTube's
  game can't be set through the API.

Sign-ins use a loopback-only redirect (never reachable from the network) and
PKCE; tokens and secrets live in the keychain and refresh on their own.

## Muze follows Spotify

Mic → FX → "Muze follows Spotify's key and tempo" (on by default):

- **Key**: Muze Auto Key runs on the Spotify channel and publishes the song's key;
  Muze (Key Link: Follow) retunes to it. Needs Muze Auto Key installed.
- **Tempo**: OmniCast tracks the Spotify channel's beat (onsets in three bands,
  autocorrelation scored as a comb over 1–4 beats so syncopation like dembow
  isn't read as 4/3 tempo) and gives it to Muze as the host tempo, so its
  tempo-synced harmony, delay and LFOs lock to the song. It resets on each song
  and only moves Muze's tempo for changes of about a BPM or more.

Spotify's own tempo/key data isn't available to new apps (its API closed that
in 2024), so this listens to the audio instead. Very fast songs (~170+) can be
read wrong.

## Spotify now playing

Sources → Spotify: a card with the album art, song and artist fades in when a
song starts (or resumes), stays 30 seconds and fades out; pausing hides it. It
sits in a corner of the 16:9 canvas (and above the camera on 9:16), and isn't
rendered at all while faded out. It reads Spotify's own play/pause
announcements, so it needs no login. Spotify also gets its own mixer channel.

## Discord call overlay

Puts the people in your Discord voice call on the 16:9 canvas, PNGtuber style:
each person has an idle and a talking image (their Discord avatar by default,
dimmed while quiet, with a green ring and a small hop while talking), and you
can give anyone custom images.

- **Sources → Discord call → Arrange**: drag people on the preview, drag a corner
  to resize, click someone to flip them, set which way their image faces, or pick
  images. Auto-arrange lines everyone up facing right, left, or the middle.
  "Show sample people" lets you set this up without a call.
- Positions are saved per Discord user, so people land in the same spot each call.

Setup, once: Discord only shares voice events with an app you register yourself.
Create an app at https://discord.com/developers/applications, add the OAuth2
redirect `http://localhost`, paste its Client ID and Client Secret into
Settings → Discord, click Connect and then Authorize in Discord. OmniCast talks to
the Discord app on this Mac over its local RPC socket (regular, Canary and PTB),
follows whichever one you're in a call on, and keeps the secret and token in the
keychain.

## Virtual camera

Controls → Virtual Camera sends one canvas, 16:9 **or** 9:16, to the
"OBS Virtual Camera" device, so Zoom, Discord, FaceTime or a browser can use it.
Flip the 16:9 / 9:16 switch while it's on to move the camera to the other canvas.
The device is fixed at 1920×1080, so 9:16 appears centred with black side bars.

It uses the camera extension OBS.app installs (open OBS once and click Start
Virtual Camera if it isn't installed yet). OmniCast feeds the extension directly,
because OBS's own plugin only works inside OBS.app and only sends the main canvas.
The Camera source skips virtual cameras so the feed can't loop back into itself;
pick the camera under Sources → Camera.

9:16 is fitted into the 1920×1080 camera frame on the GPU (a small extra canvas),
so the camera never makes the vertical canvas, or a recording of it, skip frames.
Measured: 60 fps into the camera, 0 skipped frames on either canvas.

Screen Recording permission is requested once; after that, use "Allow screen
access…" under Display.

To check frame pacing yourself:

```sh
build/OmniCast.app/Contents/MacOS/OmniCast --benchmark-record 30 --folder ~/Desktop/bench --target both
```

It writes `benchmark.json` (fps, render time, missed frames) next to the recordings.

## Build

```sh
./scripts/bootstrap.sh   # libobs headers matching OBS.app, plus simde
./scripts/bundle.sh      # builds build/OmniCast.app
open build/OmniCast.app
```

Run `./scripts/make-signing-cert.sh` once. It creates a self-signed code-signing
certificate named **OmniCast Local** in your login keychain, and `bundle.sh` signs
with it, so macOS keeps the Screen Recording / Camera / Mic permissions across
rebuilds. Without it the app is signed ad hoc and macOS asks again after every
build (and a Screen Recording switch left on from an older build doesn't cover
the new one: remove OmniCast from the list and allow it again).

OBS.app must stay installed: `OmniCast.app/Contents/Frameworks` and `PlugIns` link to it.

## Layout

- `Sources/OmniEngine`: C/Objective-C over libobs (canvases, scenes, encoders, RTMP outputs, previews).
- `Sources/OmniCast`: SwiftUI app. Stream keys are stored in the macOS keychain.

## License

libobs is GPL-2.0-or-later, so OmniCast is too.
