#define MyAppName "Codex Token Bar"
#define MyAppVersion "1.3.1"
#define MyAppPublisher "333.dev"
#define MyAppExeName "CodexTokenBar.exe"

[Setup]
AppId={{7BD8622D-D214-4A7C-B9D6-D7F4BFE3F431}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\Codex Token Bar
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=CodexTokenBar-Windows-x64-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=CodexTokenBar.Windows\app.ico

[Files]
Source: "..\dist\windows-x64\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent
