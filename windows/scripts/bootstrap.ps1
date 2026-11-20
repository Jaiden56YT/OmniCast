# Gets libobs and the VST3 interfaces for OmniCast for Windows. Run by
# build.ps1; safe to run again.
#
# Downloads, once, into windows/vendor/downloads (each checked against its SHA-256):
#   - OBS Studio 32.0.4's Windows x64 zip: obs.dll and the plugins OmniCast uses
#   - OBS Studio 32.0.4's source tarball: the libobs headers OmniCore compiles against
#   - Steinberg's VST3 plug-in interfaces 3.8.1 (MIT): headers for hosting mic plugins
# OBS Studio doesn't need to be installed.
#
#   -Refresh   extract again even if vendor/ is already set up

param([switch]$Refresh)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is ~10x faster without the progress bar

$ObsVersion = '32.0.4'
$Files = @{
    Runtime = @{
        Name   = "OBS-Studio-$ObsVersion-Windows-x64.zip"
        Sha256 = 'fd367a7f156319426f1a600720c1288ad0011da168dff41e0f94dbb18cc1dc0f'
    }
    Sources = @{
        Name   = "OBS-Studio-$ObsVersion-Sources.tar.gz"
        Sha256 = 'd9e62ea24305fbfe14c69a6422de1525fe84da232df2cc0d7e4601a840bdbba8'
    }
}

$Vst3Tag = 'v3.8.1_build_84'
$Vst3 = @{
    Name   = "vst3_pluginterfaces-$Vst3Tag.tar.gz"
    Url    = "https://codeload.github.com/steinbergmedia/vst3_pluginterfaces/tar.gz/refs/tags/$Vst3Tag"
    Sha256 = '19e88e225b6ecb4a3c429d3ff2fd511be9c6c8b8b1c7e86b05949b45c0553e2d'
}

# The OBS plugins OmniCast loads. Everything else in the zip is left out.
$Plugins = @(
    'win-capture',     # Windows Graphics Capture (screen, window), game capture
    'win-dshow',       # cameras and capture cards (DirectShow)
    'win-wasapi',      # mic, desktop audio, per-app audio (WASAPI)
    'obs-x264',        # CPU encoder, used when the PC has no GPU encoder
    'obs-nvenc',       # NVIDIA GPU encoder
    'obs-qsv11',       # Intel GPU encoder
    'obs-ffmpeg',      # AMD GPU encoder (AMF), AAC audio
    'obs-outputs',     # RTMP(S) and MP4 outputs
    'rtmp-services',
    'image-source',
    'obs-transitions', # scene transitions: fade, fade to black, slide, swipe
    'obs-filters'
)

$Root     = Split-Path -Parent $PSScriptRoot           # windows/
$Vendor   = Join-Path $Root 'vendor'
$Download = Join-Path $Vendor 'downloads'
$Runtime  = Join-Path $Vendor 'obs-runtime'
$Headers  = Join-Path $Vendor 'obs-include'
$Stamp    = Join-Path $Vendor ".obs-$ObsVersion.stamp"
New-Item -ItemType Directory -Force $Download | Out-Null

function Get-Pinned($file) {
    $path = Join-Path $Download $file.Name
    if (Test-Path $path) {
        if ((Get-FileHash $path -Algorithm SHA256).Hash -eq $file.Sha256) { return $path }
        Write-Host "  $($file.Name) doesn't match its checksum; downloading it again"
        Remove-Item $path
    }
    $url = if ($file.Url) { $file.Url } else { "https://github.com/obsproject/obs-studio/releases/download/$ObsVersion/$($file.Name)" }
    Write-Host "  downloading $url"
    $tmp = "$path.part"
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    $hash = (Get-FileHash $tmp -Algorithm SHA256).Hash
    if ($hash -ne $file.Sha256) {
        Remove-Item $tmp
        throw "$($file.Name): SHA-256 is $hash, expected $($file.Sha256). Not using it."
    }
    Move-Item $tmp $path
    return $path
}

# VST3 interfaces -> vendor/vst3/pluginterfaces (headers and the few .cpp
# files that define the interface ids).
$Vst3Dir = Join-Path $Vendor 'vst3'
$Vst3Stamp = Join-Path $Vendor ".vst3-$Vst3Tag.stamp"
if ($Refresh -or -not (Test-Path $Vst3Stamp)) {
    Write-Host "Getting the VST3 interfaces $Vst3Tag"
    $tgz = Get-Pinned $Vst3
    Remove-Item -Recurse -Force $Vst3Dir -ErrorAction SilentlyContinue
    $tmpV = Join-Path $Vendor 'vst3-tmp'
    Remove-Item -Recurse -Force $tmpV -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $tmpV | Out-Null
    & "$env:SystemRoot\System32\tar.exe" -xzf $tgz -C $tmpV
    if ($LASTEXITCODE) { throw 'Could not extract the VST3 interfaces' }
    New-Item -ItemType Directory -Force $Vst3Dir | Out-Null
    Move-Item (Get-ChildItem $tmpV -Directory | Select-Object -First 1).FullName (Join-Path $Vst3Dir 'pluginterfaces')
    Remove-Item -Recurse -Force $tmpV
    Set-Content -Encoding ascii $Vst3Stamp $Vst3Tag
}

$want = ($Plugins -join ',')
if (-not $Refresh -and (Test-Path $Stamp) -and ((Get-Content $Stamp -Raw).Trim() -eq $want)) {
    Write-Host "libobs $ObsVersion is ready (windows/vendor). Use -Refresh to extract again."
    exit 0
}

Write-Host "Getting libobs $ObsVersion"
$zip = Get-Pinned $Files.Runtime
$src = Get-Pinned $Files.Sources

# --- Runtime: obs.dll, its DLLs, the renderer, the chosen plugins and their data.
Write-Host "  extracting the runtime"
$tmpRt = Join-Path $Vendor 'obs-runtime.tmp'
Remove-Item -Recurse -Force $tmpRt, $Runtime -ErrorAction SilentlyContinue
Expand-Archive -Path $zip -DestinationPath $tmpRt
$bin = Join-Path $tmpRt 'bin\64bit'
New-Item -ItemType Directory -Force "$Runtime\bin\64bit", "$Runtime\obs-plugins\64bit", "$Runtime\data\obs-plugins" | Out-Null

# Every DLL next to obs64.exe (libobs, the D3D11 renderer, FFmpeg, x264, ...),
# but not the OBS Studio app itself, its Qt UI, its browser, scripting, the
# OpenGL renderer (Windows uses D3D11) or WebRTC.
Get-ChildItem $bin -File | Where-Object {
    ($_.Extension -in '.dll', '.exe') -and
    ($_.Name -notmatch '^(obs64\.exe|Qt6|obs-frontend-api|obs-browser|libcef|chrome_|vk_swiftshader|vulkan-1|libEGL|libGLESv2|d3dcompiler_47_cef|snapshot_blob|v8_|obs-scripting|lua51|libobs-opengl|datachannel)')
} | Copy-Item -Destination "$Runtime\bin\64bit"
# obs-ffmpeg-mux.exe etc. live next to obs.dll; win-capture's hook helpers too.
Copy-Item -Recurse "$tmpRt\data\libobs" "$Runtime\data\libobs"
foreach ($p in $Plugins) {
    $dll = "$tmpRt\obs-plugins\64bit\$p.dll"
    if (-not (Test-Path $dll)) { throw "The OBS zip has no plugin $p" }
    Copy-Item $dll "$Runtime\obs-plugins\64bit"
    if (Test-Path "$tmpRt\data\obs-plugins\$p") {
        Copy-Item -Recurse "$tmpRt\data\obs-plugins\$p" "$Runtime\data\obs-plugins\$p"
    }
}
# NVENC and AMF test helpers OBS runs to check the GPU encoders.
Get-ChildItem "$tmpRt\bin\64bit" -Filter '*-test.exe' | Copy-Item -Destination "$Runtime\bin\64bit"
Copy-Item "$tmpRt\LICENSE" "$Runtime\OBS-LICENSE.txt" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $tmpRt

# --- Headers: libobs/ from the source tarball (tar ships with Windows 10+).
Write-Host "  extracting the libobs headers"
$tmpSrc = Join-Path $Vendor 'obs-src.tmp'
Remove-Item -Recurse -Force $tmpSrc, $Headers -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tmpSrc | Out-Null
& "$env:SystemRoot\System32\tar.exe" -xzf $src -C $tmpSrc '*/libobs/*'
if ($LASTEXITCODE -ne 0) { throw 'tar could not read the OBS sources' }
$libobs = Get-ChildItem $tmpSrc -Recurse -Directory -Filter 'libobs' | Select-Object -First 1
New-Item -ItemType Directory -Force $Headers | Out-Null
Get-ChildItem $libobs.FullName -Recurse -Include '*.h', '*.hpp' | ForEach-Object {
    $rel = $_.FullName.Substring($libobs.FullName.Length + 1)
    $dest = Join-Path $Headers $rel
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Copy-Item $_.FullName $dest
}
# obsconfig.h is generated by OBS's CMake; OmniCore only needs these values.
@"
#pragma once
#define OBS_DATA_PATH "../../data"
#define OBS_PLUGIN_PATH "../../obs-plugins/64bit"
#define OBS_PLUGIN_DESTINATION "obs-plugins/64bit"
#define OBS_INSTALL_PREFIX ""
#define OBS_RELEASE_CANDIDATE 0
#define OBS_BETA 0
"@ | Set-Content -Encoding ascii (Join-Path $Headers 'obsconfig.h')
Remove-Item -Recurse -Force $tmpSrc

Set-Content -Encoding ascii $Stamp $want
$mb = [math]::Round(((Get-ChildItem $Runtime -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB)
Write-Host "libobs $ObsVersion ready: runtime $mb MB in windows/vendor/obs-runtime, headers in windows/vendor/obs-include"
