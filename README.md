# OmniCast

A streaming and recording app made for Mac. One app sends a **16:9** canvas to
YouTube, Twitch and Kick and a **9:16** canvas to TikTok and Instagram at the same
time, records either or both, and replaces the usual pile of streaming tools: an
audio mixer with per-app channels, merged chat, stream alerts, a Discord call overlay, a
now-playing card, a virtual camera, and Discord audio routing.

It's built on libobs, the engine inside OBS Studio, with a native SwiftUI app on
top: no Electron, no Qt.

## Requirements

- A Mac with **Apple silicon** (M1 or later) on **macOS 14.2** or later. (14.0
  works, but per-app audio channels need 14.2.)
- **Xcode 15.3** or later, or its Command Line Tools (Swift 5.10).
- **[Homebrew](https://brew.sh)**, used once for the `simde` headers.

Optional, for specific features:

| Feature | Needs |
|---|---|
| Sending your mic or stream audio to Discord | [BlackHole](https://existential.audio/blackhole/) loopback devices (free) |
| Mic effects | STACKS and/or Muze (Audio Unit plugins, sold separately); Muze Auto Key for key following |
| Discord call overlay | the Discord app and a free Discord developer app (see below) |
| Setting stream titles and games | free developer apps on Twitch, Kick and Google (see below) |
| Virtual camera | OBS's camera extension, installed once by OBS Studio (see below) |

## Quick start

```sh
git clone https://github.com/Jaiden56YT/OmniCast.git
cd OmniCast
./scripts/make-signing-cert.sh   # once: a local signing certificate, so macOS remembers permissions
./scripts/bootstrap.sh           # once: gets libobs (OBS doesn't need to be installed)
./scripts/bundle.sh              # builds build/OmniCast.app
open build/OmniCast.app
```

## First run

1. **Permissions.** macOS asks for the microphone and camera; allow both. Screen
   Recording is asked for once: turn OmniCast on in System Settings → Privacy &
   Security → Screen & System Audio Recording, then reopen OmniCast (or use "Allow
   screen access…" under Display).
2. **Destinations.** Click **+** in Destinations, pick the platform, paste your
   stream key (from the platform's creator dashboard), and choose 16:9 or 9:16.
   Keys are stored in the macOS keychain. Turn on the ones you want.
3. **Sources.** Pick what the screen slot shows (a display, window, app or capture
   card) and your camera. Turn on Chat, Music or the Discord call overlay if you
   want them.
4. **Audio.** The mic and system audio are there from the start. Use **+** to give
   an app (a game, Spotify, Discord) its own channel with separate Stream and
   Monitor (headphones) levels.
5. **Go live** with Go Live (⇧⌘L) or **record** with Start Recording (⇧⌘R).
   Recording settings (folder, 16:9 / 9:16 / both, separate audio tracks) are in
   Settings → Recording.

Everything else is optional and explained below.

# Features

## Recording

- Separate constant-quality **HEVC** (or H.264) encode per canvas on the media
  engine, so recordings stay sharp even when the stream is 6 Mbps CBR.
- Record 16:9, 9:16, or both at once (two files), 1080p60.
- Hybrid MP4: the file stays playable even if the app is killed mid-recording.
- Track 1 = full mix, track 2 = desktop audio, track 3 = mic (toggle in Settings).
- Start/stop with the Record button or ⇧⌘R; go live with ⇧⌘L.

Measured on an M4 MacBook Air, recording both canvases at once for 30 s:
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

## Merged chat

YouTube, Twitch and Kick chat in one overlay, read only (nothing is ever posted):

- **Twitch**: Twitch's official chat connection, anonymously.
- **Kick**: the realtime feed kick.com itself uses (a guest token from Kick's
  realtime API, no login; unofficial).
- **YouTube**: the live-chat feed youtube.com's chat window uses, found from the
  channel's /live page once you're live. No API key or quota; unofficial.
- Instagram doesn't let apps read live chat, so it can't be included.

Lines are drawn with heavy rounded type and a thick black outline, platform icons, role badges (crown for you, wrench for mods, diamond for
VIPs, star for members), Twitch/Kick name colours and palette colours for YouTube,
inline emotes. Channels and text size are in Settings → Chat; move and resize
the box with Arrange. Sources → Chat → ⋯ (or Settings → Chat → Show test
messages) adds test messages for setting it up offline.

**Fading.** Each message fades out once it has been on screen for 5 minutes, and
the whole chat fades out after 5 minutes with no new messages, then fades back
in with the next one. Both times are set in Settings → Chat (30 seconds to 15
minutes, or Never).

## Stream alerts

Follows, subs, tips and raids pop up on both canvases as a short card ("deku_vt
cheered 500 bits"), one at a time from a queue: each slides in, stays 5 seconds
(3 to 12 in Settings) and fades out. Nothing is ever posted to any platform.

| Platform | Alerts | Comes from |
|---|---|---|
| Twitch | subs, resubs, gift subs (one alert per bundle), bits, raids | the chat connection |
| Twitch | follows | EventSub, with your Twitch sign-in (Settings → Accounts) |
| YouTube | Super Chats, Super Stickers, new members, member milestones, gifted memberships, YouTube gifts | the chat feed |
| YouTube | new subscribers | the Data API with your YouTube sign-in, checked once a minute while you're live (1 quota unit per check); only people whose subscriptions are public |
| Kick | subs, resubs, gifted subs, Kicks, hosts | the chat feed |

Not available: **Kick follows** (Kick only sends them to apps with a public
webhook URL, which a desktop app doesn't have) and third-party tips
(Streamlabs/StreamElements aren't connected). Twitch accounts signed in before
alerts existed need to sign in again once to allow follows (the
`moderator:read:followers` scope); Settings → Alerts says so if needed.

Turn alerts on or off with the bell in Sources → Alerts or in Settings → Alerts,
where each kind (follows, subs, gifts, bits/tips, raids) can be switched off on
its own, and each source's status is shown. **Show a test alert** (there or in
Sources → Alerts → ⋯) plays a sample; move and resize the card with Arrange.

## Muze follows the music

Mic → FX → "Muze follows Spotify's key and tempo" (on by default; it follows
[untitled] instead when Sources → Music is set to it):

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

## Music: Spotify, Apple Music, YouTube Music or [untitled]

Sources → Music has a menu for which app's music is on stream: **Spotify**,
**Apple Music**, **YouTube Music** or **[untitled]** (the ones you have installed).
The selected app gets a mixer channel if it has none, is unmuted on stream, and
the other music apps are muted on stream (so also in Discord's Go Live audio).
Muze follows the selected app's key and tempo.

YouTube Music has no Mac app of its own: it plays in Chrome (as a tab or an
installed Chrome app), so its channel is **Google Chrome**, which means all of
Chrome's sound. Switching to another music app mutes Chrome on stream.

The now-playing card shows the selected app's song: album art, song and artist
fade in when a song starts (or resumes), stay 30 seconds and fade out; pausing
hides it. It sits in a corner of the 16:9 canvas (and above the camera on 9:16),
and isn't rendered at all while faded out. "Now playing" takes each app's colour.

- **Spotify**: read from Spotify's own play/pause announcements, so it needs no
  login; art from Spotify's public oEmbed.
- **Apple Music**: read from Music's own play/pause announcements, no
  permission needed; art from Apple's public iTunes Search.
- **YouTube Music**: read from its window title ("Artist - Song | YouTube
  Music"), with Chrome's "Audio playing" marker telling playing from paused.
  Needs Accessibility (below). An upload whose title doesn't split into artist
  and song is shown whole, with "YouTube Music" underneath. Art comes from
  iTunes Search, which finds released songs; uploads get a ♪ placeholder.
- **[untitled]**: it doesn't announce its songs, and macOS keeps Now Playing to
  Apple's own apps, so OmniCast reads [untitled]'s player bar through
  Accessibility. The art is grabbed from [untitled]'s window: the big cover when
  the playing album's page is open, otherwise the player bar's thumbnail.
  [untitled]'s window has to stay open (it can be behind other windows).

Accessibility, for YouTube Music and [untitled]: allow OmniCast once in System
Settings → Privacy & Security → Accessibility. The Music row links there.

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

## Discord: your voice and Go Live

The speech-bubble button in the Audio panel sends two things to Discord, each into
a loopback audio device:

- **Voice**: your mic with STACKS and Muze. In Discord, set Settings → Voice &
  Video → Input Device to that device. Leave it off to give Discord your mic
  directly, without the plugins.
- **Go Live audio**: everything else the stream hears (game, Spotify, apps),
  without your mic, so friends don't hear you twice. In Discord, start Go Live →
  Devices → OBS Virtual Camera, then the gear → Audio Device → that device.
  Discord's own channel is left out so the call doesn't hear itself back; if
  Discord has no channel yet, turning this on gives it one.

Both follow the Stream faders and mutes, like the stream. Voice and Go Live audio
each need their own loopback device (e.g. BlackHole 2ch and BlackHole 16ch).

Install BlackHole with `brew install --cask blackhole-2ch` (and `blackhole-16ch`
for a second device); each asks for your password. The new device shows up after a
restart, or right away after `sudo killall coreaudiod` (Mac audio cuts out for a
second; reopen OmniCast afterwards). Pro Tools Audio Bridge, Steam
Streaming Microphone and Zoom's device aren't offered, because they only carry
audio while their own app drives them. Turn off Discord's noise suppression
(Krisp) if it smears Muze's harmonies.

## Virtual camera

Controls → Virtual Camera sends one canvas, 16:9 **or** 9:16, to the
"OBS Virtual Camera" device, so Zoom, Discord, FaceTime or a browser can use it.
Flip the 16:9 / 9:16 switch while it's on to move the camera to the other canvas.
The device is fixed at 1920×1080, so 9:16 appears centred with black side bars.

It uses the camera extension OBS.app installs. OmniCast feeds the extension directly,
because OBS's own plugin only works inside OBS.app and only sends the main canvas.
The extension stays installed after OBS.app is deleted (macOS runs it from its own
copy in `/Library/SystemExtensions`), so the camera keeps working without OBS.
If it isn't installed yet (`systemextensionsctl list` doesn't show
`com.obsproject.obs-studio.mac-camera-extension`), install OBS, open it once, click
Start Virtual Camera, quit it, then delete OBS again. To remove the camera for
good: System Settings → General → Login Items & Extensions → Camera Extensions.
The Camera source skips virtual cameras so the feed can't loop back into itself;
pick the camera under Sources → Camera.

9:16 is fitted into the 1920×1080 camera frame on the GPU (a small extra canvas),
so the camera never makes the vertical canvas, or a recording of it, skip frames.
Measured: 60 fps into the camera, 0 skipped frames on either canvas.

# How it's built

## Why it's fast

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

## Checking performance

To check frame pacing on your Mac (records both canvases for 30 seconds):

```sh
build/OmniCast.app/Contents/MacOS/OmniCast --benchmark-record 30 --folder ~/Desktop/bench --target both
```

It writes `benchmark.json` (fps, render time, missed frames) next to the recordings.

## Building in detail

OBS doesn't need to be installed. `scripts/obs-runtime.sh` (run by both scripts)
copies libobs.framework, the Metal and OpenGL renderers, the FFmpeg / x264 /
mbedTLS / SRT / RIST libraries they link, and the nine OBS plugins OmniCast loads
(capture, VideoToolbox, x264, AAC, RTMP/MP4 outputs, RTMP service, image source,
colour filter) into `vendor/obs-runtime` (about 75 MB, git-ignored). It takes
them from `/Applications/OBS.app` if that's there; otherwise it downloads the
official OBS 32.0.4 disk image from GitHub (about 190 MB, once, checked against
its SHA-256) and reads them from it without installing OBS.

The build links against that copy, and `bundle.sh` copies it into
`OmniCast.app/Contents/Frameworks` and `PlugIns`, then signs every library,
plugin and the app. Every library uses an `@rpath/…` install name and
`@executable_path/../Frameworks` as its rpath, so they load from inside the app
as they are.

To take the files from another copy of OBS, or to refresh them after updating OBS
(delete `vendor/obs-studio` too so the headers match):

```sh
OBS_APP=/path/to/OBS.app ./scripts/obs-runtime.sh --refresh
```

To add a plugin (say OmniCast starts using a source from `obs-transitions`), add
it to `plugins` in `scripts/obs-runtime.sh`. The script notices the list
changed and copies it again.

Run `./scripts/make-signing-cert.sh` once. It creates a self-signed code-signing
certificate named **OmniCast Local** in your login keychain, and `bundle.sh` signs
with it, so macOS keeps the Screen Recording / Camera / Mic permissions across
rebuilds. Without it the app is signed ad hoc and macOS asks again after every
build (and a Screen Recording switch left on from an older build doesn't cover
the new one: remove OmniCast from the list and allow it again).

## Project layout

- `Sources/OmniEngine`: a C API (`include/OmniEngine.h`) in C/Objective-C over
  libobs: canvases, sources, encoders, outputs, recording, overlays, the audio
  mixer and the virtual camera.
- `Sources/OmniCast`: the SwiftUI app. Stream keys, tokens and secrets are stored
  in the macOS keychain.
- `scripts/`: getting libobs, building and signing the app.
- `docs/WINDOWS-APP.md`: the brief for OmniCast for Windows, a separate app made
  for Windows.

## License

OmniCast is free software under the GNU General Public License, version 2 or
later (see `LICENSE`), because libobs is GPL-2.0-or-later. OBS and OBS Studio
are trademarks of the OBS Project; OmniCast isn't affiliated with it.
