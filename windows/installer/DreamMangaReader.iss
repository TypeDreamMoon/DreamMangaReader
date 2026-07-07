; Dream Manga Reader —— Windows 安装器(Inno Setup 6)
;
; 编译:iscc /DMyAppVersion=1.0.0-beta.1 windows\installer\DreamMangaReader.iss
; 前置:先 `flutter build windows --release`,并把 VC++ 运行时 DLL
;       (msvcp140/vcruntime140/vcruntime140_1)拷进 Release 目录(CI 会自动做)。
; 产物:dist\DreamMangaReader-windows-x64-setup.exe

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0-beta.1"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#define MyAppName "Dream Manga Reader"
#define MyAppExeName "dream_manga_reader.exe"
#define MyAppPublisher "TypeDreamMoon"
#define MyAppURL "https://github.com/TypeDreamMoon/DreamMangaReader"

[Setup]
AppId={{B7E9C3A2-4D5F-4A1B-9E8C-7F6A2D3B1C0E}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\DreamMangaReader
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
OutputDir=..\..\dist
OutputBaseFilename=DreamMangaReader-windows-x64-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 只支持 64 位(Flutter windows 产物是 x64)。
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; 默认无需管理员(装到用户目录);用户可在对话框里选择系统级安装。
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
; 简体中文是非官方翻译(Inno 不自带),随仓库一起放在 .iss 同目录。
Name: "cn"; MessagesFile: "ChineseSimplified.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 整个 Release 目录(exe + 各插件 DLL + libmpv + data\ + 已拷入的 VC 运行时)。
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
