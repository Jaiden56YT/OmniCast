# OmniCast on Windows: porting guide

This is the brief for building OmniCast for Windows. The macOS app in this repo is
the reference: same features, same layout, same "one engine, two canvases" design.
Read the top-level `README.md` first for what each feature does from the user's side;
this file says how each piece maps to Windows.

## What OmniCast is

A native multistreaming / recording app on **libobs** (the OBS engine, GPL):

- Two canvases from one set of sources: **16:9** (YouTube, Twitch, Kick) and **9:16**
  (TikTok, Instagram). Each canvas is **encoded once** and that encode is shared by
  every destination on it.
- Recording: separate constant-quality HEVC/H.264 encode per canvas, 16:9, 9:16 or
  both, 1080p60, hybrid/fragmented MP4, tracks 1 mix / 2 desktop / 3 mic.
- A Wave Link-style mixer: every channel (mic, system, per-app, capture card,
  Spotify) has a **Stream** level and a **Monitor** (headphones) level.
- Mic plugins (STACKS, Muze) on the mic; Muze follows the music's key and tempo.
- Overlays drawn by the app and pushed into libobs as image layers: merged chat
  (Twitch/Kick/YouTube), Discord call PNGtuber overlay, mic-driven PNGtuber for the
  streamer, now-playing card (Spotify or [untitled]).
- Stream info: set title/game on YouTube, Twitch, Kick via their official APIs.
- Discord outputs: Voice (mic with plugins) and Go Live audio (stream minus mic and
  minus Discord) into two loopback devices; virtual camera for Go Live video.

## Recommended architecture

Keep the split the Mac app has:

1. **`OmniEngine`**: a C library (C/C++ on Windows) over libobs exposing the **same
   C API** as `Sources/OmniEngine/include/OmniEngine.h` (64 `omni_*` functions).
   Port `OmniEngine.m` and `OmniAudio.m` function by function; most of
   `OmniEngine.m` is plain libobs calls and carries over almost unchanged.
2. **The UI**: a native Windows app that calls that C API. Recommended: **C# + WinUI 3**
   (or WPF) with P/Invoke into `OmniEngine.dll`. The Swift files under
   `Sources/OmniCast` are the spec for each screen and behaviour; the non-UI logic
   (chat clients, OAuth, stream info, Discord RPC, tempo smoothing, overlay drawing)
   ports file by file.

No Electron, no web UI: the point is low overhead.

## libobs on Windows

- Version: match the Mac build, **OBS 32.0.4**.
- Same approach as `scripts/obs-runtime.sh` on Mac: take `obs.dll`, the D3D11
  renderer, FFmpeg/x264/mbedTLS DLLs and **only the plugins OmniCast loads** from an
  installed OBS Studio (`C:\Program Files\obs-studio\bin\64bit`,
  `obs-plugins\64bit`, `data\`) into a git-ignored `vendor\obs-runtime`, and ship
  them inside the app folder so OBS can be uninstalled afterwards. Headers from the
  obs-studio source at tag `32.0.4`. An import library for `obs.dll` can be made with
  `dumpbin /exports` + `lib /def`, or build libobs from source with CMake (the
  official route).
- Plugins to load on Windows: `win-capture`, `win-dshow`, `win-wasapi`,
  `obs-nvenc` (and `obs-qsv11` / AMF via `obs-ffmpeg` if those GPUs matter),
  `obs-x264` (fallback only), `obs-ffmpeg` (AAC, MP4/hybrid MP4 output),
  `obs-outputs` (RTMP/RTMPS), `rtmp-services`, `image-source`, `obs-filters`
  (colour filter), `win-virtualcam` / virtualcam module.

## Mac → Windows mapping

| Piece | macOS (this repo) | Windows |
|---|---|---|
| Renderer | libobs-metal, OpenGL fallback | **libobs-d3d11** |
| Video encoder | VideoToolbox `ave.avc` / HEVC | **NVENC** (`obs_nvenc_h264_tex`, `obs_nvenc_hevc_tex`, AV1 on 40-series); AMF or QSV on AMD/Intel; x264 only if no hardware encoder |
| Screen slot | ScreenCaptureKit display / window / app | `win-capture`: `monitor_capture` and `window_capture` with **Windows Graphics Capture**, `game_capture` for games |
| Capture card (Elgato HD60 X) + its audio | AVFoundation device | `win-dshow` (`dshow_input`), audio from the same device |
| Camera | AVFoundation | `win-dshow` |
| Mic | CoreAudio input | `wasapi_input_capture` |
| System audio minus OmniCast and app channels | Core Audio process tap (excludes processes) | **WASAPI process loopback** (`AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS`, Windows 10 2004+): system = loopback *excluding* OmniCast's and each app channel's process trees |
| Per-app channels (Spotify, Discord, game...) | process taps, which also silence the app at source so it's only heard through the monitor mix | process loopback *including* the app's process tree. **Difference:** Windows doesn't silence the app at source. To keep Stream and Monitor independent, set the app's audio session volume via `ISimpleAudioVolume` or route the app to a virtual device. Test what process loopback captures relative to session volume before choosing. |
| Monitor (headphones) mix | AudioUnit output, ring buffer per channel | WASAPI shared-mode render, same ring-buffer design (see `OmniAudio.m`, `ring_write` / `ring_mix`) |
| Discord Voice / Go Live outputs | two loopback devices (BlackHole 2ch / 16ch) | **VB-Audio Virtual Cable** (CABLE plus CABLE A+B for a second one): OmniCast renders into "CABLE Input", Discord picks "CABLE Output". Only offer devices that really loop back. |
| Mic plugins STACKS, Muze, Muze Auto Key | AUv3, loaded by component ID only when on | **VST3** versions (check each vendor ships Windows VST3). Host with the VST3 SDK (dual GPLv3, compatible with OmniCast's GPL-2.0-or-later when distributed under GPLv3) as libobs audio filters, loaded only when turned on. Key Link and host tempo work as on Mac. |
| Virtual camera | OBS camera extension, fed directly | OBS's Windows virtual camera reads a **shared-memory queue** (`shared-memory-queue.c`, `OBSVirtualCamVideo`). Feed that queue directly from the chosen canvas (16:9 or 9:16 fitted into 1920×1080) so it works without OBS running. The DirectShow filter must be registered: OBS's installer does it, or register `obs-virtualcam-module64.dll` with `regsvr32`. |
| Spotify now playing | Spotify's distributed notifications | **GlobalSystemMediaTransportControlsSessionManager** (WinRT): title, artist, thumbnail and play state for Spotify, no hacks or extra permission |
| [untitled] now playing | Accessibility read of its player bar | If there's a Windows [untitled] app, try GSMTC first; it likely publishes media info |
| Discord RPC | Unix socket `$TMPDIR/discord-ipc-N` | named pipe `\\.\pipe\discord-ipc-0` … `9`, same framing (opcode + length + JSON) |
| Secrets (stream keys, tokens, client secrets) | Keychain | **Windows Credential Manager** (`CredWriteW` / `CredReadW`) or DPAPI |
| OAuth sign-ins | loopback redirect `http://localhost:39651/callback`, PKCE | same: `HttpListener` on `127.0.0.1` only |
| Chat (Twitch, Kick, YouTube) | URLSession / WebSocket | same protocols, `ClientWebSocket` / `HttpClient` |
| Permissions | TCC (Screen Recording, Mic, Camera, Accessibility) | Windows Settings → Privacy: Microphone / Camera for desktop apps; no screen permission needed |
| Signing | self-signed "OmniCast Local" | optional; unsigned is fine for personal use |

## Performance checklist ("make it optimized")

Carry over everything in the README's "Why it's fast" section, the Windows way:

- **One encode per canvas** shared by all destinations; recordings get their own
  constant-quality hardware encode (NVENC CQP), never a second software encode.
- Texture-based hardware encoders (`*_tex`): frames stay on the GPU, no CPU copy.
- **NV12** output format; D3D11 renderer.
- Previews draw each canvas's finished frame (no second composite) and **pause when
  the window is minimised or hidden**; a "Live preview" off switch.
- Overlays are pre-rendered images (PNG) pushed only when they change; nothing
  composited per frame in the UI layer; hidden layers aren't rendered at all.
- Unused cameras and capture cards are **released**, not just hidden.
- Keep the PC awake while live/recording: `SetThreadExecutionState(ES_SYSTEM_REQUIRED | ES_CONTINUOUS)`.
- Process priority **Above Normal** while live/recording (OBS's default on Windows).
- Use Windows Graphics Capture rather than DXGI duplication where possible; disable
  the capture's yellow border where Windows allows it.
- Audio callbacks: no allocation, no locks, atomics only (as `OmniAudio.m` does).
- Verify like the Mac build: a `--benchmark-record <seconds>` mode that records both
  canvases and writes `benchmark.json` (fps, render time, missed / skipped frames).
  Target: 60 fps, 0 skipped frames on both canvases while recording both at once.

## Where to look in this repo

| File | What it holds |
|---|---|
| `Sources/OmniEngine/include/OmniEngine.h` | the full engine API, with comments |
| `Sources/OmniEngine/OmniEngine.m` | canvases, scene, sources, encoders, outputs, recording, virtual camera, overlays |
| `Sources/OmniEngine/OmniAudio.m` | mixer, monitor and Discord outputs, process taps, AU plugin hosting, tempo tracking |
| `Sources/OmniCast/Engine.swift` | app-side engine lifetime, stats, recording |
| `Sources/OmniCast/AudioMixer.swift` | mixer model and UI, Discord outputs, mic settings |
| `Sources/OmniCast/ContentView.swift` | main window layout, Sources panel |
| `Sources/OmniCast/Destination*.swift` | destinations and stream keys |
| `Sources/OmniCast/Chat/` | Twitch / Kick / YouTube chat clients and the overlay |
| `Sources/OmniCast/Accounts/` | OAuth, account storage, stream title/game |
| `Sources/OmniCast/DiscordRPC.swift`, `DiscordCall.swift`, `CallOverlay*.swift` | Discord voice overlay |
| `Sources/OmniCast/SpotifyOverlay.swift`, `UntitledNowPlaying.swift`, `MusicSync.swift` | now-playing card, music switch, Muze follow |
| `Sources/OmniCast/RecordBenchmark.swift` | the benchmark mode |
