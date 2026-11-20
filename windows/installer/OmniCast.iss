; OmniCast for Windows installer (Inno Setup 6).
; Built by: .\windows\build.ps1 -Installer  ->  windows\build\OmniCast-Setup-x64.exe
;
; Installs the app folder windows\build\OmniCast (self-contained: .NET, the
; Windows App SDK and libobs are inside), Start menu and optional desktop
; shortcuts, and an uninstaller.
;
; VB-CABLE (the virtual audio cable the Discord outputs use) is VB-Audio's
; donationware, and its licence doesn't allow including it in another app's
; installation without VB-Audio's agreement. So this installer doesn't install
; it: when it's missing, the last page offers to open VB-Audio's own page, and
; OmniCast's Settings > Discord walks through it.

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

[Setup]
AppId={{D6021906-6741-4703-AF6B-1BBB9682A424}
AppName=OmniCast
AppVersion={#AppVersion}
AppVerName=OmniCast {#AppVersion}
AppPublisher=OmniCast contributors
AppPublisherURL=https://github.com/Jaiden56YT/OmniCast
AppSupportURL=https://github.com/Jaiden56YT/OmniCast/issues
DefaultDirName={autopf}\OmniCast
DisableProgramGroupPage=yes
; Program Files by default; "Install for me only" (no admin) is offered too.
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
LicenseFile=..\..\LICENSE
SetupIconFile=..\app\Assets\OmniCast.ico
UninstallDisplayIcon={app}\OmniCast.exe
UninstallDisplayName=OmniCast
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
OutputDir=..\build
OutputBaseFilename=OmniCast-Setup-x64
; Close a running OmniCast before replacing its files.
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\OmniCast\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\OmniCast"; Filename: "{app}\OmniCast.exe"
Name: "{autodesktop}\OmniCast"; Filename: "{app}\OmniCast.exe"; Tasks: desktopicon

[Registry]
; "Start with Windows" is a per-user setting the app writes; remove it on uninstall.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "OmniCast"; Flags: uninsdeletevalue dontcreatekey

[Run]
Filename: "{app}\OmniCast.exe"; Description: "Open OmniCast"; Flags: nowait postinstall skipifsilent runasoriginaluser
; The virtual camera (OBS's DirectShow camera, shipped in the app folder).
; Registered only on admin installs, and only when OBS Studio hasn't already
; registered its own copy. Per-user installs set it up from the app instead.
Filename: "{sys}\regsvr32.exe"; Parameters: "/s ""{app}\obs\data\obs-plugins\win-dshow\obs-virtualcam-module64.dll"""; Flags: runhidden; Check: IsAdminInstallMode and not VCamRegistered(True)
Filename: "{syswow64}\regsvr32.exe"; Parameters: "/s ""{app}\obs\data\obs-plugins\win-dshow\obs-virtualcam-module32.dll"""; Flags: runhidden; Check: IsAdminInstallMode and not VCamRegistered(False)
Filename: "https://vb-audio.com/Cable/"; Description: "Get VB-CABLE, the free virtual audio cable for sending your mic to Discord (opens VB-Audio's website)"; Flags: shellexec postinstall skipifsilent runasoriginaluser; Check: not VBCableInstalled

[UninstallRun]
; Unregister the virtual camera only when it's this install's copy (not OBS Studio's).
Filename: "{sys}\regsvr32.exe"; Parameters: "/u /s ""{app}\obs\data\obs-plugins\win-dshow\obs-virtualcam-module64.dll"""; Flags: runhidden; RunOnceId: "VCam64"; Check: VCamIsOurs(True)
Filename: "{syswow64}\regsvr32.exe"; Parameters: "/u /s ""{app}\obs\data\obs-plugins\win-dshow\obs-virtualcam-module32.dll"""; Flags: runhidden; RunOnceId: "VCam32"; Check: VCamIsOurs(False)

[Code]
const
  VCamKey = 'CLSID\{A3FCE0F5-3493-419F-958A-ABA1250EC20B}\InprocServer32';

// The DLL the 64-bit or 32-bit virtual camera is registered to, or ''.
function VCamPath(Is64: Boolean): String;
var
  Root: Integer;
begin
  if Is64 then Root := HKCR64 else Root := HKCR32;
  if not RegQueryStringValue(Root, VCamKey, '', Result) then
    Result := '';
end;

function VCamRegistered(Is64: Boolean): Boolean;
begin
  Result := (VCamPath(Is64) <> '') and FileExists(VCamPath(Is64));
end;

function VCamIsOurs(Is64: Boolean): Boolean;
begin
  Result := Pos(Lowercase(ExpandConstant('{app}')), Lowercase(VCamPath(Is64))) = 1;
end;

// True when a VB-Audio virtual cable is installed: Windows lists an audio
// output whose driver is VB-Audio's.
function VBCableInstalled: Boolean;
var
  Base, Name: String;
  Keys: TArrayOfString;
  I: Integer;
begin
  Result := False;
  Base := 'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render';
  if not RegGetSubkeyNames(HKLM64, Base, Keys) then
    Exit;
  for I := 0 to GetArrayLength(Keys) - 1 do
    if RegQueryStringValue(HKLM64, Base + '\' + Keys[I] + '\Properties',
         '{b3f8fa53-0004-438e-9003-51a46e139bfc},6', Name) and
       (Pos('VB-Audio', Name) > 0) then
    begin
      Result := True;
      Exit;
    end;
end;
