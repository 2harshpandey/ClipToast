; ClipToast installer (NSIS). Per-user install: no admin rights, no UAC prompt.
; Build:  makensis -DUPDATE_URL=https://github.com/2harshpandey/ClipToast/releases/latest/download/latest.json installer.nsi
Unicode true
!define APP_NAME "ClipToast"
!define APP_VERSION "1.0.0"
!ifndef UPDATE_URL
  !define UPDATE_URL "https://github.com/2harshpandey/ClipToast/releases/latest/download/latest.json"
!endif
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipToast"

!include "MUI2.nsh"
!include "LogicLib.nsh"

Name "${APP_NAME}"
OutFile "ClipToastSetup-v1.0.exe"
InstallDir "$LOCALAPPDATA\ClipToast"
RequestExecutionLevel user
SetCompressor /SOLID lzma
BrandingText "${APP_NAME} ${APP_VERSION}"
VIProductVersion "1.0.0.0"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "FileDescription" "${APP_NAME} - Seamless Windows Clipboard Media Downloader"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "LegalCopyright" "ClipToast. Uses yt-dlp, FFmpeg, and Deno (downloaded separately from official releases)"

Var DownloadDir

!define MUI_ICON "cliptoast.ico"
!define MUI_UNICON "cliptoast.ico"
!define MUI_ABORTWARNING

!define MUI_WELCOMEPAGE_TITLE "Welcome to ${APP_NAME}"
!define MUI_WELCOMEPAGE_TEXT "Copy a YouTube or Instagram link, press Ctrl+Alt+G (or click $\"ClipToast$\" in the Start menu), and the video downloads in the background at highest quality, converted to an MP4 that plays everywhere (WhatsApp, iPhone, Android, TV).$\r$\n$\r$\nSetup takes a moment because it configures the media tools. No administrator rights are needed."
!insertmacro MUI_PAGE_WELCOME

!define MUI_PAGE_CUSTOMFUNCTION_PRE DirPre
!define MUI_PAGE_HEADER_TEXT "Choose your download folder"
!define MUI_PAGE_HEADER_SUBTEXT "Where should downloaded media be saved?"
!define MUI_DIRECTORYPAGE_TEXT_TOP "Downloaded media will be saved in this folder. Click Browse to choose a different one (you can change it later in Settings)."
!define MUI_DIRECTORYPAGE_TEXT_DESTINATION "Download folder"
!define MUI_DIRECTORYPAGE_VARIABLE $DownloadDir
!insertmacro MUI_PAGE_DIRECTORY

!insertmacro MUI_PAGE_INSTFILES

!define MUI_FINISHPAGE_TITLE "You're all set"
!define MUI_FINISHPAGE_TEXT "To download: copy any video/media link, then press Ctrl+Alt+G or click $\"ClipToast$\" in the Start menu.$\r$\n$\r$\nTip: right-click it in Start and choose $\"Pin to Start$\"."
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  StrCpy $DownloadDir "$PROFILE\Downloads\ClipToast"
FunctionEnd

; Skip folder prompt when upgrading existing install
Function DirPre
  IfFileExists "$INSTDIR\config.txt" 0 +2
  Abort
FunctionEnd

Section "Install"
  SetShellVarContext current

  SetOutPath "$INSTDIR"
  File "cliptoast.ico"
  SetOutPath "$INSTDIR\app"
  File /r "app\*.*"

  ; If migrating from legacy LinkGrab folder, reuse downloaded tools to save bandwidth
  ${If} ${FileExists} "$LOCALAPPDATA\LinkGrab\bin\yt-dlp.exe"
  ${AndIfNot} ${FileExists} "$INSTDIR\bin\yt-dlp.exe"
    CreateDirectory "$INSTDIR\bin"
    CopyFiles /SILENT "$LOCALAPPDATA\LinkGrab\bin\*.*" "$INSTDIR\bin"
  ${EndIf}

  ; Pass initial configuration via environment variables
  System::Call 'Kernel32::SetEnvironmentVariable(t "LG_DLDIR", t "$DownloadDir")i'
  System::Call 'Kernel32::SetEnvironmentVariable(t "LG_UPDATEURL", t "${UPDATE_URL}")i'

  DetailPrint "Setting up ClipToast and media tools..."
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\app\install.ps1"'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONINFORMATION "Setup finished, but some tools could not be downloaded (offline?).$\r$\n$\r$\nDon't worry: ClipToast will retry automatically the first time you use it."
  ${EndIf}

  SetOutPath "$INSTDIR"
  ; Create Start menu shortcuts (with Ctrl+Alt+G global hotkey)
  CreateShortCut "$SMPROGRAMS\ClipToast.lnk" "$WINDIR\System32\wscript.exe" '"$INSTDIR\app\run.vbs" downloader.ps1' "$INSTDIR\cliptoast.ico" 0 SW_SHOWNORMAL CONTROL|ALT|G "ClipToast - Download the media link in your clipboard"
  CreateShortCut "$SMPROGRAMS\ClipToast Settings.lnk" "$WINDIR\System32\wscript.exe" '"$INSTDIR\app\run.vbs" settings.ps1' "$INSTDIR\cliptoast.ico" 0 SW_SHOWNORMAL "" "Settings and updates for ClipToast"

  ; Clean up legacy shortcuts if upgrading
  Delete "$SMPROGRAMS\Link Downloader.lnk"
  Delete "$SMPROGRAMS\Link Downloader Settings.lnk"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "ClipToast"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\cliptoast.ico"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Delete "$SMPROGRAMS\ClipToast.lnk"
  Delete "$SMPROGRAMS\ClipToast Settings.lnk"
  Delete "$SMPROGRAMS\Link Downloader.lnk"
  Delete "$SMPROGRAMS\Link Downloader Settings.lnk"
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\LinkGrab"
  SetOutPath "$TEMP"
  RMDir /r "$INSTDIR"
SectionEnd
