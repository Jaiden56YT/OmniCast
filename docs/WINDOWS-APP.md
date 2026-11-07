# OmniCast for Windows: made for Windows

OmniCast for Windows is **its own app, made for Windows**, the way OmniCast for Mac
is made for Mac. It is **not a port**. Don't translate the Swift or Objective-C, don't
copy the Mac layout, and don't keep Mac-shaped APIs. Design and build it
Windows-first: Windows UI, Windows frameworks, Windows hardware paths, Windows
conventions.

What the two apps share is the **product**: the features, the "one engine, two
canvases" idea, and how fast it should be. Use the Mac app in this repo only as a
reference for *what* each feature does and how it behaves (see the top-level
`README.md`). How it's built on Windows is up to the Windows app.

## The product

A native multistreaming and recording app on **libobs** (the OBS engine, GPL):

- **Two canvases** from one set of sources: **16:9** (YouTube, Twitch, Kick) and
  **9:16** (TikTok, Instagram). Each canvas is **encoded once**, and that encode is
  shared by every destination on it.
- **Recording**: separate constant-quality hardware encode per canvas, 16:9, 9:16 or
  both, 1080p60, a file that survives a crash, tracks 1 = mix / 2 = desktop /
  3 = mic.
- **A mixer**: every channel (mic, system, each app you add, capture card, music)
  has a **Stream** level and a **Monitor** (headphones) level, with meters.
- **Mic plugins** (STACKS, Muze) on the mic; Muze follows the music's key and tempo.
- **Overlays** on the canvases: merged chat (Twitch, Kick, YouTube), a Discord call
  overlay (PNGtuber style), a mic-driven PNGtuber for you, and a now-playing card.
- **Music switch**: Spotify or [untitled] on stream; the other is muted on stream.
- **Stream info**: set the title and game on YouTube, Twitch and Kick at once.
- **Discord**: Voice (your mic with plugins) and Go Live audio (the stream minus
  your mic and minus Discord) into two loopback devices; a virtual camera for Go
  Live video.
- **Benchmark mode** to prove frame pacing (`--benchmark-record <seconds>`).

## Made for Windows: how to build it

- **UI**: **WinUI 3** (Windows App SDK) with Fluent Design: Mica backdrop, Windows
  11 title bar, Segoe UI Variable, Fluent icons, light and dark following Windows,
  proper DPI scaling, snap layouts, keyboard navigation and Narrator support. It
  should look like it ships with Windows, not like the Mac app. Lay the window
  out for Windows; don't copy the Mac panels.
- **Language**: C# for the app; **C++** for the engine layer over libobs (or
  C++/WinRT throughout). Native code only: no Electron, no web UI.
- **Preview**: render each canvas into a **SwapChainPanel** using D3D11 shared
  textures from libobs, so the preview costs no CPU copy. Pause it when the window
  is minimised or hidden, and offer a "Live preview" off switch.
- **Windows touches**: a tray icon with live/recording state, global hotkeys (go
  live, record, mute mic), toast notifications for disconnects and reconnects,
  start-with-Windows as an option, a single-instance app.
- **Secrets**: Windows Credential Manager (`CredWriteW` / `CredReadW`) for stream
  keys, tokens and client secrets.
- **Install**: MSIX or a simple installer that ships everything needed, including
  the libobs runtime, so OBS Studio doesn't have to be installed.

## Windows building blocks per feature

| Feature | Use on Windows | (Mac, for reference only) |
|---|---|---|
| Rendering | libobs **D3D11** | Metal |
| Encoding | **NVENC** texture encoders (H.264 / HEVC / AV1 on RTX 40); AMF or QSV on AMD/Intel; x264 only if there's no GPU encoder | VideoToolbox |
| Screen slot | **Windows Graphics Capture** (monitor, window), `game_capture` for games | ScreenCaptureKit |
| Capture card (Elgato HD60 X) and camera | DirectShow (`win-dshow`), card audio as its own channel | AVFoundation |
| Mic | WASAPI capture | CoreAudio |
| Per-app channels and system audio | **WASAPI process loopback** (Windows 10 2004+): each app's process tree, and system = everything minus OmniCast and the apps that have channels. Windows doesn't silence the app at the source, so design Stream vs Monitor for that (per-app session volume, or a virtual device); test before choosing | process taps |
| Monitor mix | WASAPI shared-mode render | AudioUnit |
| Discord Voice / Go Live outputs | **VB-Audio Virtual Cable** (CABLE, plus A+B for a second one); only offer devices that actually loop back | BlackHole |
| Mic plugins | **VST3** builds of STACKS / Muze / Muze Auto Key, loaded only when turned on | AUv3 |
| Virtual camera | OBS's Windows virtual camera, fed straight from the chosen canvas through its shared-memory queue (works without OBS running) | OBS camera extension |
| Now playing (Spotify, [untitled]) | **GlobalSystemMediaTransportControlsSessionManager**: title, artist, artwork, play state, no workarounds | Spotify notifications / Accessibility |
| Discord call overlay | Discord RPC over the named pipe `\\.\pipe\discord-ipc-0`…`9` | Unix socket |
| Sign-ins (Twitch, Kick, YouTube) | OAuth with a loopback redirect on `127.0.0.1` and PKCE | same |
| Chat | Twitch, Kick and YouTube over WebSocket / HTTP | same |

libobs: use **32.0.4** (the version the Mac app uses) or newer, build it from source
with CMake, or take the runtime from an OBS Studio install. Ship only the plugins
the app uses.

## Performance: what "optimized" means

- One encode per canvas, shared by every destination. Recordings get their own
  constant-quality GPU encode, never a second software encode.
- Texture-based GPU encoders, so frames never leave the GPU. NV12 output.
- Previews show the finished canvas frame (no second composite) and pause when
  hidden.
- Overlays are pre-rendered images, updated only when they change; hidden layers
  aren't rendered.
- Unused cameras and capture cards are released, not just hidden.
- While live or recording: keep the PC awake (`SetThreadExecutionState`), run at
  Above Normal priority, and stay out of power throttling (EcoQoS off) for the
  render and encode threads.
- Audio callbacks: no allocations, no locks, atomics only.
- Prove it with the benchmark mode: 60 fps and 0 skipped frames on both canvases
  while recording both at once, written to `benchmark.json`.

## Using the Mac app as a reference

Read these for **behaviour**, not code to translate: what a feature does, edge
cases, defaults, and what the user sees.

| Mac file | Behaviour it shows |
|---|---|
| `README.md` | every feature from the user's side |
| `Sources/OmniEngine/include/OmniEngine.h` | what the engine can do (canvases, sources, overlays, mixer, recording, virtual camera), with comments |
| `Sources/OmniEngine/OmniAudio.m` | mixer and monitor design, Discord outputs, tempo tracking (onset bands and comb scoring) |
| `Sources/OmniCast/AudioMixer.swift` | mixer defaults, Discord outputs, music app switching |
| `Sources/OmniCast/Chat/` | how Twitch / Kick / YouTube chat is read without logins or API keys |
| `Sources/OmniCast/Accounts/` | stream title and game APIs and sign-in flows |
| `Sources/OmniCast/DiscordCall.swift`, `CallOverlay*.swift` | Discord voice overlay behaviour and layout saving |
| `Sources/OmniCast/SpotifyOverlay.swift`, `MusicSync.swift` | now-playing card timing and look, Muze follow |
| `Sources/OmniCast/RecordBenchmark.swift` | benchmark mode output |
