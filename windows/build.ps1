# Builds OmniCast for Windows into windows\build\OmniCast\OmniCast.exe.
#
#   .\windows\build.ps1            Release build (first run also gets libobs)
#   .\windows\build.ps1 -Debug     Debug build
#   .\windows\build.ps1 -Zip       also make windows\build\OmniCast-Windows-x64.zip
#   .\windows\build.ps1 -Installer also make windows\build\OmniCast-Setup-x64.exe
#                                  (needs Inno Setup 6: winget install JRSoftware.InnoSetup)
#
# Needs Visual Studio 2022 (or its Build Tools) with "Desktop development with
# C++", and the .NET 8 SDK. See windows\README.md.

param([switch]$Debug, [switch]$Zip, [switch]$Installer)
$ErrorActionPreference = 'Stop'
$Root   = $PSScriptRoot
$Config = if ($Debug) { 'Debug' } else { 'Release' }
$Out    = Join-Path $Root 'build\OmniCast'

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }

# --- 1. libobs (downloaded once, checked against its SHA-256)
Step 'libobs'
& (Join-Path $Root 'scripts\bootstrap.ps1')

# --- 2. The Visual Studio C++ tools (cl, link, cmake, ninja) on PATH
Step 'Visual Studio C++ tools'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw 'Visual Studio 2022 or its Build Tools is not installed. See windows\README.md.' }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual Studio is installed without "Desktop development with C++". Add that workload in the Visual Studio Installer.' }
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $env:PATH = "$env:PATH;$(Split-Path $vswhere)"   # the dev shell calls vswhere itself
    $here = Get-Location
    & "$vs\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Null
    Set-Location $here
}
Write-Host "  $vs"

# --- 3. OmniCore.dll (C++ engine)
Step "OmniCore ($Config)"
$coreBuild = Join-Path $Root "build\core-$Config"
cmake -S (Join-Path $Root 'core') -B $coreBuild -G Ninja "-DCMAKE_BUILD_TYPE=$Config" | Out-Host
if ($LASTEXITCODE) { throw 'CMake configure failed' }
cmake --build $coreBuild | Out-Host
if ($LASTEXITCODE) { throw 'OmniCore failed to build' }

# --- 4. The app (C# / WinUI 3), self-contained: no .NET or Windows App SDK install needed to run it
Step "OmniCast app ($Config)"
$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
if (-not $dotnet -and (Test-Path "$env:ProgramFiles\dotnet\dotnet.exe")) { $dotnet = "$env:ProgramFiles\dotnet\dotnet.exe" }
if (-not $dotnet) { throw 'The .NET 8 SDK is not installed. See windows\README.md.' }
Remove-Item -Recurse -Force $Out -ErrorAction SilentlyContinue
& $dotnet publish (Join-Path $Root 'app\OmniCast.csproj') -c $Config -r win-x64 --self-contained -o $Out -nologo | Out-Host
if ($LASTEXITCODE) { throw 'The app failed to build' }

# --- 5. Engine and libobs next to the exe
Step 'Bundle'
Copy-Item (Join-Path $coreBuild 'OmniCore.dll') $Out
Copy-Item -Recurse (Join-Path $Root 'vendor\obs-runtime') (Join-Path $Out 'obs')
# OBS's GPU-encoder checks (NVENC, AMF, Quick Sync) run these helpers from the
# folder of the running exe.
Get-ChildItem (Join-Path $Out 'obs\bin\64bit') -Filter '*-test.exe' | Copy-Item -Destination $Out
Copy-Item (Join-Path $Root '..\LICENSE') (Join-Path $Out 'LICENSE.txt')
$mb = [math]::Round(((Get-ChildItem $Out -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB)
Write-Host "  $Out ($mb MB)"

if ($Installer) {
    Step 'Installer'
    $iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
              "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $iscc) { throw 'Inno Setup 6 is not installed: winget install JRSoftware.InnoSetup' }
    $version = ([xml](Get-Content (Join-Path $Root 'app\OmniCast.csproj'))).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
    & $iscc /Q "/DAppVersion=$version" (Join-Path $Root 'installer\OmniCast.iss') | Out-Host
    if ($LASTEXITCODE) { throw 'The installer failed to build' }
    Write-Host "  $(Join-Path $Root 'build\OmniCast-Setup-x64.exe')"
}

if ($Zip) {
    $zipPath = Join-Path $Root 'build\OmniCast-Windows-x64.zip'
    Remove-Item $zipPath -ErrorAction SilentlyContinue
    Compress-Archive -Path $Out -DestinationPath $zipPath
    Write-Host "  $zipPath"
}
Write-Host "`nDone. Run: $Out\OmniCast.exe" -ForegroundColor Green
