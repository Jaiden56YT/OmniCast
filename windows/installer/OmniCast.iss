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
Filename: "https://vb-audio.com/Cable/"; Description: "Get VB-CABLE, the free virtual audio cable for sending your mic to Discord (opens VB-Audio's website)"; Flags: shellexec postinstall skipifsilent runasoriginaluser; Check: not VBCableInstalled

[Code]
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
