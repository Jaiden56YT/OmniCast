# OmniCast for Windows

A streaming and recording app made for Windows. One app sends a **16:9** canvas
to YouTube, Twitch and Kick and a **9:16** canvas to TikTok and Instagram at the
same time, and records either or both.

It's built on libobs, the engine inside OBS Studio, with a native WinUI 3 app
on top: Fluent design, Mica, the Windows 11 title bar, light and dark mode,
Narrator support. No Electron, no Qt, no web UI. It's made to run well on
low-end PCs: 720p60 by default, 1080p60 when you want it.

This is the Windows sibling of OmniCast for Mac (the rest of this repository).
It's its own app, not a port: same idea and features, built the Windows way.

## Requirements

**To run it:** Windows 10 version 2004 or later, or Windows 11, 64-bit, with a
Direct3D 11 graphics card (practically any from the last 12 years). No .NET,
Windows App SDK or OBS Studio install is needed; the app folder has everything.

**To build it:**

- **Visual Studio 2022** (Community is free) or just its **Build Tools**, with
  the **Desktop development with C++** workload. It includes CMake and the
  Windows SDK.
- The **.NET 8 SDK**.

With winget, both are one line each (the Build Tools install takes a while
and asks for admin rights):

```powershell
winget install Microsoft.DotNet.SDK.8
winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

## Quick start

In PowerShell:

```powershell
git clone https://github.com/Jaiden56YT/OmniCast.git
cd OmniCast
.\windows\build.ps1
.\windows\build\OmniCast\OmniCast.exe
```

The first build downloads libobs (OBS Studio 32.0.4, about 200 MB, once) from
the official GitHub release and checks it against its SHA-256. If PowerShell
says running scripts is disabled, run
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once, or start the build
with `powershell -ExecutionPolicy Bypass -File .\windows\build.ps1`.

The finished app is the folder `windows\build\OmniCast`. Copy it anywhere, or
add `-Zip` to the build for `windows\build\OmniCast-Windows-x64.zip`.

## First run

1. **Screen.** The main display shows in both previews straight away, in
   **Scene 1**. In the Scene card, under **Screen**, pick a **Display**, a
   single **Window**, a **Game** (DirectX/OpenGL/Vulkan game capture) or a
   **Capture card**.
2. **Camera.** Pick your camera in the Scene card. By default it sits in the
   corner of 16:9 and fills the bottom half of 9:16; change that with the
   layout boxes.
3. **More scenes (optional).** Click **+ Scene** for another preset, say
   "Just chatting" with the camera full screen, and switch between them
   (see Scenes below).
4. **Audio.** Your mic and desktop audio are already there, with meters, a
   level slider and mute. Choose other devices in **Settings › Audio**.
5. **Destinations.** Open **Destinations › Add destination**, pick the
   platform, paste the stream key (the dialog says where to find it), and
   choose 16:9 or 9:16. YouTube and Twitch fill in their server for you; Kick,
   TikTok and Instagram give you a server URL along with the key.
6. **Go live** or **Start recording** in the Studio, from the tray icon, or
   with **Ctrl+Alt+L** / **Ctrl+Alt+R** from any app.

Closing the window keeps OmniCast in the notification area (so a stream isn't
cut by accident); quit from the tray icon's menu. Settings › App can change
that.

# Features

## Scenes and transitions

A scene is a preset of what's on screen, and switching scenes switches all of
it at once, on both canvases. Each scene has its own:

- **Screen:** a display, window, game or capture card
- **Camera:** any camera, or none
- **16:9 layout:** screen with the camera in a corner (pick the corner),
  screen only, or camera only
- **9:16 layout:** screen on top and camera below, screen only (the sides of
  a 16:9 screen are cropped), or camera only
- **Mute mic in this scene** (optional), for a "Be right back" scene

The Scene card always edits the scene on air, and changes go out live.

**Switching:** click a scene in the bar above the previews, press
**Ctrl+Alt+1** to **Ctrl+Alt+9** from any app, or pick it from the tray
icon's menu. The switch uses the transition on the right of the bar: **Cut**,
**Fade**, **Fade to black**, **Slide** or **Swipe**, from 50 ms to 5 s.
Right-click a scene to **cut** to it instantly, rename, duplicate, reorder or
delete it. The scene on air can't be deleted; switch away first.

**+ Scene** starts a new scene as a copy of the one on air, so you only
change what's different. Scenes that aren't on air cost nothing: two scenes
showing the same display or camera share one capture, and captures in scenes
that aren't on air stop (a camera's light goes off). A transition briefly runs
both scenes; on a GeForce GT 710 that's about 0.9 ms of GPU per frame instead
of 0.7, with no dropped frames.

## Two canvases, one encode each

The 16:9 and 9:16 canvases share one set of sources. Each canvas is encoded
once, and every destination on that canvas shares the encode, so adding a
third 16:9 platform costs upload bandwidth, not CPU or GPU.

## Picks the right encoder for your PC

OmniCast looks at what your graphics card can do and uses the best encoder
it has, with frames staying on the GPU:

| Your GPU | Encoder |
|---|---|
| NVIDIA GTX 900 series or newer | NVENC |
| AMD Radeon RX 400 or newer | AMF |
| Intel with Quick Sync | Quick Sync |
| Anything else (e.g. GeForce GT 710) | x264 on the CPU |

Settings › Video shows which one is in use. With x264, 720p uses the
`veryfast` preset and 1080p the lighter `superfast` one, so both canvases keep
60 fps on a 6-core CPU.

## Recording

- Record 16:9, 9:16 or both at once (one MP4 per canvas), at the stream's
  resolution and frame rate.
- MP4s stay playable even if the PC crashes mid-recording (hybrid MP4).
- Track 1 = full mix, track 2 = desktop audio only, track 3 = mic only (on by
  default, Settings › Recording).
- With a GPU encoder, each recording gets its own constant-quality encode,
  sharp even when the stream is at a low bitrate. With x264, recordings share
  the stream's encode, so recording while live costs no extra CPU.

## What the screen slot captures

- **Display:** a whole monitor, through Windows' own capture.
- **Window:** one window, even when it's behind others.
- **Game:** hooks DirectX, OpenGL and Vulkan games for the lowest overhead.
- **Capture card:** any DirectShow video device (Elgato, AVerMedia, ...). Its
  sound gets its own mixer channel. Cards like the Elgato HD60 X that show up
  as a video device plus an audio device of the same name are matched
  automatically.

Only one runs at a time; the old one is released. Hidden cameras and unused
capture cards are closed, not just hidden: the light goes off, nothing crosses
USB, and other apps can use them.

## Windows integration

- **Tray icon** showing live and recording state, with Go live, Record, Mute
  mic, the scenes and Quit.
- **Global hotkeys:** Ctrl+Alt+L go live / end stream, Ctrl+Alt+R record,
  Ctrl+Alt+M mute mic, Ctrl+Alt+1 to 9 switch scenes. If another app already
  owns one, Settings says so.
- **Notifications** when a destination disconnects, reconnects or stops, and
  when a recording stops with an error (only when the window isn't in front).
- **Stream keys in Windows Credential Manager**, never in a settings file.
  They show up as `OmniCast/stream-key/...` under Windows Credentials.
- **Start with Windows** (Settings › App): opens in the tray when you sign in.
- **One OmniCast at a time:** opening it again brings the window to the front.
- Automatic reconnects (up to 20 tries) when a connection drops.

## Coming next

These OmniCast for Mac features aren't in the Windows app yet:

- Per-app audio channels and a separate headphones (monitor) mix
- Mic plugins (VST3 builds of STACKS and Muze), Muze following the music
- Overlays: merged Twitch/Kick/YouTube chat, Discord call overlay, now playing
- Spotify / [untitled] music switch
- Setting stream titles and games on all platforms at once
- Discord voice and Go Live audio outputs (via VB-Audio Virtual Cable)
- Virtual camera
- An installer (today it's a folder or zip)

# How it's built

## Why it's light

- **Previews cost almost nothing.** libobs renders each canvas once; the
  preview copies that finished frame into the window's swap chain on the GPU
  (no second composite of the scene, no CPU copy) and stops when the window
  is minimised, hidden or on another page.
- **One encode per canvas**, GPU texture encoders when the GPU has one, NV12
  produced on the GPU.
- Canvases are composited at their output size (no extra rescale pass) with a
  bilinear filter, the cheapest on low-end GPUs.
- Audio meters are lock-free (atomics only) and drawn with a GPU transform, no
  layout work.
- While live or recording: the PC is kept awake, OmniCast runs at Above
  Normal priority, and Windows' power throttling (EcoQoS) is turned off for
  it. Back to normal when you stop.
- Trimmed, ReadyToRun-compiled .NET for a quick start.

## Checking performance

To check frame pacing on your PC (records the main display on both canvases
for 30 seconds, without opening the window):

```powershell
.\windows\build\OmniCast\OmniCast.exe --benchmark-record 30 --target both --height 720
```

It prints the results and writes `benchmark.json` (fps, render time, frames
late or skipped per canvas, CPU use) next to the recordings, in
`Videos\OmniCast benchmark` unless you pass `--folder`. Options: `--target
wide|tall|both`, `--height 720|1080`, `--fps 30|60`. The exit code is 0 when
it held the frame rate with nothing skipped.

Measured on a Ryzen 5 3600 with a GeForce GT 710 (no GPU encoder, so x264),
recording both canvases for 30 s with full-screen motion on the display:

| | fps | frames late / skipped | GPU per frame | CPU (all cores) |
|---|---|---|---|---|
| 720p60 | 60.00 | 0 / 0 | 0.85 ms | 22% |
| 1080p60 | 60.00 | 0 / 0 | 1.37 ms | 23% |

## Building in detail

`windows\build.ps1` runs four steps:

1. `windows\scripts\bootstrap.ps1` downloads two official OBS Studio 32.0.4
   files from GitHub, checked against their SHA-256: the Windows x64 zip (for
   `obs.dll`, the D3D11 renderer, FFmpeg, x264 and the 12 plugins OmniCast
   loads) and the source tarball (for the libobs headers). It keeps only what
   OmniCast uses in `windows\vendor\obs-runtime` (about 60 MB) and
   `windows\vendor\obs-include`. Both are git-ignored; `-Refresh` extracts them
   again.
2. Finds Visual Studio's C++ tools with `vswhere`.
3. Builds **OmniCore.dll** (`windows\core`) with CMake and Ninja. OBS doesn't
   ship an import library for `obs.dll`, so CMake makes one from its exports.
4. Publishes the app (`windows\app`) self-contained for x64, then copies
   OmniCore.dll and the libobs runtime (in an `obs` subfolder) next to it.

Logs are in `%LOCALAPPDATA%\OmniCast\obs\logs` (Settings › About › Open logs);
settings in `%LOCALAPPDATA%\OmniCast\settings.json`.

To add an OBS plugin, add it to `$Plugins` in `windows\scripts\bootstrap.ps1`.
The script notices the list changed and extracts again.

## Project layout

- `windows\core`: **OmniCore**, a C++ DLL over libobs with a flat C API
  (`include\omnicore.h`): canvases, scenes and transitions, encoder choice, previews,
  streaming, recording, audio meters.
- `windows\app`: the **WinUI 3** app in C#, calling OmniCore through
  P/Invoke (`Engine\Native.cs`). `Engine\EngineHost.cs` holds the app's state;
  `Pages\` are Studio, Destinations and Settings; `Services\` has settings,
  Credential Manager, the tray icon and hotkeys, notifications, start with
  Windows.
- `windows\scripts`: getting libobs, drawing the icons.
- `windows\build.ps1`: the one build command.

## License

OmniCast is free software under the GNU General Public License, version 2 or
later (see `LICENSE` at the top of the repository), because libobs is
GPL-2.0-or-later. OBS and OBS Studio are trademarks of the OBS Project;
OmniCast isn't affiliated with it.
