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

Create a code-signing certificate named **OmniCast Local** once (Keychain Access →
Certificate Assistant → Create a Certificate…, Identity Type *Self Signed Root*,
Certificate Type *Code Signing*). `bundle.sh` signs with it, so macOS keeps the
Screen Recording / Camera / Mic permissions across rebuilds. Without it the app is
signed ad hoc and macOS asks again after every build.

OBS.app must stay installed: `OmniCast.app/Contents/Frameworks` and `PlugIns` link to it.

## Layout

- `Sources/OmniEngine`: C/Objective-C over libobs (canvases, scenes, encoders, RTMP outputs, previews).
- `Sources/OmniCast`: SwiftUI app. Stream keys are stored in the macOS keychain.

## License

libobs is GPL-2.0-or-later, so OmniCast is too.
