; xlikemanage — Inno Setup 6 安装脚本
; 由 tool/build_windows.ps1 调用：ISCC.exe /DAppVersion=x.y.z /DSourceDir=...\Release xlikemanage.iss
; 注意：PowerShell 里同一行的 "\" 续行是脚本自己的语法，这里保持独立文件。

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

#define AppName "X Shelf"
#define AppExe "xlikemanage.exe"
#define AppPublisher "xlikemanage contributors"
#define AppUrl "https://github.com/Tonited/xshelf"

[Setup]
AppId={{7C4E1B52-9D3A-4E6B-9A1C-5F0D2B8E4A11}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
DefaultDirName={autopf}\XLikeManage
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=xlikemanage-{#AppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#AppExe}
; 安装包自己的图标（仓库里那份由 tool/gen_ico.ps1 生成，和 exe/Android 图标同源）。
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
; 官方只带部分语言，中文简体随仓库带着（tool/installer/langs/），避免依赖本机安装。
Name: "zh"; MessagesFile: "langs\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
