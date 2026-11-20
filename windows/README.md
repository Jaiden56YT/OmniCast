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

## Download

1. Open the [latest Windows release](https://github.com/Jaiden56YT/OmniCast/releases?q=windows&expanded=true)
   and download **OmniCast-Setup-x64.exe** (about 40 MB).
2. Run it. Pick **Install for me only** if you don't have admin rights.
3. If Windows says "Windows protected your PC", click **More info**, then
   **Run anyway**. The installer isn't code-signed yet, so Windows doesn't
   recognise it.
4. Open OmniCast from the Start menu and follow [First run](#first-run).

It needs Windows 10 version 2004 or later, or Windows 11, 64-bit, with a
Direct3D 11 graphics card (practically any from the last 12 years). Nothing
else to install: .NET, the Windows App SDK and libobs come with it, and you
don't need OBS Studio.

Want to build it yourself instead, or change the code? Read on.

## Requirements to build it

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

## Build from source

In PowerShell (the Windows app is on the `feature/windows-app` branch):

```powershell
git clone -b feature/windows-app https://github.com/Jaiden56YT/OmniCast.git
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

### Installer

`.\windows\build.ps1 -Installer` also makes
`windows\build\OmniCast-Setup-x64.exe` (about 40 MB), with
[Inno Setup 6](https://jrsoftware.org/isinfo.php)
(`winget install JRSoftware.InnoSetup`). It installs to Program Files (or
"for me only", without admin rights), adds Start menu and optional desktop
shortcuts, and uninstalls cleanly from Settings › Apps. If VB-CABLE isn't
installed, its last page offers to open VB-Audio's page for it (see Discord
audio). Settings in `%LOCALAPPDATA%\OmniCast` and stream keys in Credential
Manager are kept when you uninstall.

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

## Discord audio

Settings › Discord sends your **mic into Discord** through OmniCast: Discord
hears it with OmniCast's level, mute and scene mute. It plays into a virtual
audio cable, and Discord uses the cable's other end as its microphone:

1. Install **VB-CABLE**, a free virtual audio cable (donationware) from
   VB-Audio: click **Get VB-CABLE** in Settings › Discord (or tick it on the
   installer's last page), download the VB-CABLE Driver Pack, unzip it,
   right-click `VBCABLE_Setup_x64.exe` › **Run as administrator** › **Install
   Driver**, and restart the PC. OmniCast finds it on its own.
2. In OmniCast, set **Voice** to **CABLE Input**.
3. In Discord, set Settings › Voice & Video › **Input Device** to **CABLE
   Output**.

VB-CABLE's licence doesn't allow other apps' installers to install it without
VB-Audio's agreement, so OmniCast's installer only points you to it for now.

**Stream audio without your mic** plays desktop audio, the app channels and
the capture card (not Discord's own channel, so a call never hears itself)
into a second cable, for apps that take a microphone (a second Discord
account in a watch-party channel, say). It needs a second cable: VB-CABLE A+B
or Voicemeeter. Discord's own Go Live doesn't need it: on Windows, Go Live
takes sound from the window you share. Only virtual cables are offered (not
speakers), and one cable can't carry both outputs.

## Mixer: app channels and your headphones mix

Every channel in Studio › Audio has two levels, each with its own mute:

- **Stream** (the broadcast icon): what goes to the stream and recordings.
- **Monitor** (the headphones icon): what you hear in the **monitor mix**,
  played on the output picked with the headphones button at the top of the
  Audio card (Windows' default output unless you choose one).

The monitor mix is mostly for things you wouldn't hear otherwise: your mic
with its plugins, and the capture card (on by default). Mic and desktop audio
start off in it, so you don't hear yourself or your desktop twice.

**+** gives a running app its own channel (Windows 10 2004 or later): Spotify,
a game, Chrome, Discord. Its sound then comes out of desktop audio, so it's
never on stream twice, and you control it on its own. Desktop audio is
everything except OmniCast and the apps with their own channel, so OmniCast
never captures its own headphones mix. Unlike on a Mac, Windows can't silence
an app at its source while still letting OmniCast capture it, so apps keep
playing through your speakers as usual. Spotify gets a channel by itself the
first time OmniCast sees it installed; × removes a channel.

## Mic plugins

**FX** on the mic opens its plugin chain: up to 4 VST3 effects (STACKS and
Muze come first in the list when they're installed; any installed VST3 effect
works). Each one has **Open editor** (the plugin's own window), **On**, and
**Remove**. They run on the mic before its level, so the stream, recordings,
the monitor mix and the Discord voice output all get them. Plugins load only
while they're in the chain, and their settings are saved when OmniCast closes.
Plugins with tempo-synced effects see a running transport at the music's
tempo (120 BPM when nothing is being followed).

**Muze follows the music** (Settings › Music, on by default): when the music
app on stream (Spotify, or your browser for [untitled]) has its own channel,
OmniCast runs **Muze Auto Key** on that channel, which hands the song's key to
Muze (set Muze's Key Link to Follow), and tracks the beat itself to give Muze
the tempo. The status line shows what Muze is following, e.g. "A Natural
Minor · 128 BPM". It needs Muze Auto Key installed and Muze on the mic; a new
song starts the beat tracking afresh.

## Overlays

Overlays sit on top of whatever scene is on air and stay put through scene
transitions. They're drawn once as images and only redrawn when something
changes, so they cost next to nothing per frame.

- **Chat** (Settings › Chat): Twitch, Kick and YouTube chat merged into one,
  read without logging in (nothing is ever posted). Type your channel names
  and click **Save and reconnect**; YouTube connects once you're live. Lines
  show the platform, badges (owner, moderator, VIP, member, verified), the
  name in its colour and emotes, with a black outline so they read on any
  background. Text size, hiding old lines, and also showing it on 9:16 are in
  the same section; **Add test messages** shows how it looks.
- **Now playing** (Settings › Music): when a song starts in the music app on
  stream, a card with its cover, title and artist fades in for 30 seconds.
  It's read from Windows' media controls, so it needs no sign-in. Pick the
  corner and whether it's on 9:16 too; **Preview card** shows it now.
- **Discord call** (Settings › Discord call on stream): the people in your
  Discord voice call, with a green ring while they talk, along the top of the
  16:9 canvas. Discord only shares this with an app you register yourself:
  the section has the four steps (Client ID and Secret, then Authorize in
  Discord).
- **Your PNGtuber**: pick an idle and a talking image; it talks when your mic
  does (sensitivity High, Medium or Low). **When talking** picks whether the
  image just swaps (the default) or does one small, smooth hop as you start
  talking; the call's people do the same.

### Arrange

**Arrange** (top-right of the 16:9 preview) puts an outline on everything you
can place, on both previews: the camera, the chat, the now-playing card, your
PNGtuber and the people in your Discord call. Drag one to move it, drag its
corner to resize it, or select it and use the arrow keys (Shift for bigger
steps, Ctrl to resize). **Reset** on a selected item puts it back in its
default place. Changes show on the canvas as you drag and are saved; **Done**
leaves Arrange. The camera's place applies to every scene that shows it in a
corner (16:9) or split (9:16), and picking a card corner in Settings puts a
dragged card back in that corner.

## Music switch

Settings › Music › **Music on stream** picks Spotify or [untitled]. The other
one is muted on stream (if it has its own channel) but stays in your monitor
mix, and the now-playing card follows the one on stream. [untitled] has no
Windows app, so on Windows it means your browser.

## Stream info

**Stream info…** in Studio sets the title on every connected platform at once,
and the game on Twitch and Kick (YouTube's category can't be set by apps).
Connect accounts in Settings › Accounts first. Each platform needs an app you
register yourself, which takes a minute, and the steps are in that section:
Twitch needs only a Client ID; Kick and YouTube need a Client ID and Secret.
Secrets and sign-ins are kept in Windows Credential Manager.

## Virtual camera

**Start virtual camera** in Studio shows the 16:9 or 9:16 canvas (the menu on
the button) as a webcam in Zoom, Discord, Teams and browsers. It's the camera
OBS uses on Windows, so apps list it as "OBS Virtual Camera", and OBS Studio
doesn't need to be installed or running. Windows needs to register it once
with admin rights: the installer does it on a normal (admin) install, and
otherwise OmniCast asks the first time you start it. Uninstalling removes it
only if it was OmniCast's copy.

## Coming next

- Animated PNGtuber and call images (the first frame shows for now)
- Installing VB-CABLE automatically (waiting on VB-Audio's permission; see
  Discord audio above)

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
   `windows\vendor\obs-include`. It also gets Steinberg's VST3 plug-in
   interfaces 3.8.1 (MIT, headers only, for hosting mic plugins) from GitHub,
   checked the same way, into `windows\vendor\vst3`. All of it is
   git-ignored; `-Refresh` extracts it again.
2. Finds Visual Studio's C++ tools with `vswhere`.
3. Builds **OmniCore.dll** (`windows\core`) with CMake and Ninja. OBS doesn't
   ship an import library for `obs.dll`, so CMake makes one from its exports.
4. Publishes the app (`windows\app`) self-contained for x64, then copies
   OmniCore.dll and the libobs runtime (in an `obs` subfolder) next to it.
   The app draws its overlays with Win2D (a NuGet package, like the Windows
   App SDK).

Logs are in `%LOCALAPPDATA%\OmniCast\obs\logs` (Settings › About › Open logs);
settings in `%LOCALAPPDATA%\OmniCast\settings.json`.

To add an OBS plugin, add it to `$Plugins` in `windows\scripts\bootstrap.ps1`.
The script notices the list changed and extracts again.

## Project layout

- `windows\core`: **OmniCore**, a C++ DLL over libobs with a flat C API
  (`include\omnicore.h`): canvases, scenes and transitions, encoder choice, previews,
  streaming, recording, audio meters, the Discord outputs (`src\audio_out.cpp`),
  per-app and desktop audio (`src\proc_audio.cpp`), the monitor mix
  (`src\monitor.cpp`), overlay layers (`src\overlay.cpp`), the VST3 host
  (`src\vst3.cpp`), beat tracking (`src\tempo.cpp`) and the virtual camera
  (`src\vcam.cpp`).
- `windows\app`: the **WinUI 3** app in C#, calling OmniCore through
  P/Invoke (`Engine\Native.cs`). `Engine\EngineHost.cs` holds the app's state;
  `Pages\` are Studio, Destinations and Settings; `Services\` has settings,
  Credential Manager, the tray icon and hotkeys, notifications, start with
  Windows, and what's playing. `Chat\` reads Twitch, Kick and YouTube chat;
  `Discord\` talks to Discord's local RPC; `Accounts\` signs in for stream
  info; `Overlays\` draws the chat, now-playing card, call and PNGtuber.
- `windows\installer\OmniCast.iss`: the Inno Setup installer.
- `windows\scripts`: getting libobs, drawing the icons.
- `windows\build.ps1`: the one build command.

## License

OmniCast is free software under the GNU General Public License, version 2 or
later (see `LICENSE` at the top of the repository), because libobs is
GPL-2.0-or-later. OBS and OBS Studio are trademarks of the OBS Project;
OmniCast isn't affiliated with it. VST is a trademark of Steinberg Media
Technologies GmbH; the VST3 interfaces OmniCast builds against are MIT
licensed.
