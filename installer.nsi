; ClipToast installer (NSIS). Per-user install: no admin rights, no UAC prompt.
; Build:  makensis -DUPDATE_URL=https://github.com/2harshpandey/ClipToast/releases/latest/download/latest.json installer.nsi
Unicode true
!define APP_NAME "ClipToast"
!define APP_VERSION "1.1.0"
!ifndef UPDATE_URL
  !define UPDATE_URL "https://github.com/2harshpandey/ClipToast/releases/latest/download/latest.json"
!endif
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipToast"

!include "MUI2.nsh"
!include "LogicLib.nsh"

Name "${APP_NAME}"
OutFile "release\ClipToastSetup-v1.1.exe"
InstallDir "$LOCALAPPDATA\ClipToast"
RequestExecutionLevel user
SetCompressor zlib
BrandingText "${APP_NAME} ${APP_VERSION}"
VIProductVersion "1.1.0.0"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "FileDescription" "${APP_NAME} - Seamless Windows Clipboard Media Downloader"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "ProductVersion" "${APP_VERSION}"
VIAddVersionKey "LegalCopyright" "Copyright (C) 2026 ClipToast"
VIAddVersionKey "CompanyName" "ClipToast"
VIAddVersionKey "OriginalFilename" "ClipToastSetup-v1.1.exe"

Var DownloadDir

!define MUI_ICON "cliptoast.ico"
!define MUI_UNICON "cliptoast.ico"
!define MUI_ABORTWARNING

!define MUI_WELCOMEPAGE_TITLE "Welcome to ${APP_NAME}"
!define MUI_WELCOMEPAGE_TEXT "Copy any video or audio link from YouTube, Instagram, TikTok, Reddit, Twitter/X, or 1,000+ supported sites:$\r$\n$\r$\n  * Ctrl+Alt+G               -  Download WhatsApp-ready MP4 Video$\r$\n  * Ctrl+Alt+A / Ctrl+Alt+M  -  Download 320kbps MP3 Audio with cover art$\r$\n  * System Tray              -  Click the ClipToast icon near your clock$\r$\n$\r$\nFast, lightweight, open-source. No administrator rights needed."
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
!define MUI_FINISHPAGE_TEXT "To download: copy any media link, then:$\r$\n$\r$\n  * Press Ctrl+Alt+G for Video (MP4)$\r$\n  * Press Ctrl+Alt+A (or Ctrl+Alt+M) for Audio (320k MP3)$\r$\n  * Or click the ClipToast tray icon near your clock!$\r$\n$\r$\nClipToast runs quietly in the background with live toast notifications."
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
  File "cliptoast.png"
  File "/oname=ClipToast.exe" "src\launcher\ClipToast.exe"
  SetOutPath "$INSTDIR\app"
  File /r "app\*.*"

  ; If migrating from legacy LinkGrab folder, reuse downloaded tools to save bandwidth
  ${If} ${FileExists} "$LOCALAPPDATA\LinkGrab\bin\yt-dlp.exe"
  ${AndIfNot} ${FileExists} "$INSTDIR\bin\yt-dlp.exe"
    CreateDirectory "$INSTDIR\bin"
    CopyFiles /SILENT "$LOCALAPPDATA\LinkGrab\bin\*.*" "$INSTDIR\bin"
  ${EndIf}

  ; Create default config if not existing (native NSIS, no PowerShell execution)
  ${IfNot} ${FileExists} "$INSTDIR\config.txt"
    FileOpen $0 "$INSTDIR\config.txt" w
    FileWrite $0 "DownloadDir=$DownloadDir$\r$\n"
    FileWrite $0 "UpdateUrl=${UPDATE_URL}$\r$\n"
    FileWrite $0 "AudioOnly=0$\r$\n"
    FileWrite $0 "DownloadSubs=0$\r$\n"
    FileWrite $0 "StartWithWindows=1$\r$\n"
    FileWrite $0 "AutoUpdate=1$\r$\n"
    FileWrite $0 "LastYtdlpUpdate=0$\r$\n"
    FileClose $0
  ${EndIf}

  CreateDirectory "$DownloadDir"

  SetOutPath "$INSTDIR"
  ; Create Start menu shortcuts (pointing directly to ClipToast.exe launcher)
  CreateShortCut "$SMPROGRAMS\ClipToast.lnk" "$INSTDIR\ClipToast.exe" "" "$INSTDIR\cliptoast.ico" 0 SW_SHOWNORMAL CONTROL|ALT|G "ClipToast - Download video from clipboard (MP4)"
  CreateShortCut "$SMPROGRAMS\ClipToast Audio.lnk" "$INSTDIR\ClipToast.exe" "--audio" "$INSTDIR\cliptoast.ico" 0 SW_SHOWNORMAL CONTROL|ALT|A "ClipToast - Download audio only as 320kbps MP3 (Ctrl+Alt+A)"
  CreateShortCut "$SMPROGRAMS\ClipToast Audio (M).lnk" "$INSTDIR\ClipToast.exe" "--audio" "$INSTDIR\cliptoast.ico" 0 SW_SHOWNORMAL CONTROL|ALT|M "ClipToast - Download audio only as 320kbps MP3 (Ctrl+Alt+M)"
  CreateShortCut "$SMPROGRAMS\ClipToast Tray.lnk" "$INSTDIR\ClipToast.exe" "--tray" "$INSTDIR\cliptoast.ico" 0 SW_SHOWNORMAL "" "ClipToast System Tray Icon"
  CreateShortCut "$SMPROGRAMS\ClipToast Settings.lnk" "$INSTDIR\ClipToast.exe" "--settings" "$INSTDIR\cliptoast.ico" 0 SW_SHOWNORMAL "" "Settings and updates for ClipToast"

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

  ; Register AppUserModelId so Windows displays ClipToast name and icon for toast notifications
  WriteRegStr HKCU "Software\Classes\AppUserModelId\ClipToast" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "Software\Classes\AppUserModelId\ClipToast" "IconUri" "$INSTDIR\cliptoast.png"
  WriteRegDWORD HKCU "Software\Classes\AppUserModelId\ClipToast" "ShowInSettings" 1

  ; Register cliptoast:// protocol for toast actions (Cancel, Open, Play)
  WriteRegStr HKCU "Software\Classes\cliptoast" "" "URL:ClipToast Protocol"
  WriteRegStr HKCU "Software\Classes\cliptoast" "URL Protocol" ""
  WriteRegStr HKCU "Software\Classes\cliptoast\shell\open\command" "" '"$INSTDIR\ClipToast.exe" --action "%1"'

  ; Register Startup Run key for System Tray
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "ClipToastTray" '"$INSTDIR\ClipToast.exe" --tray'

  ; Launch System Tray immediately
  Exec '"$INSTDIR\ClipToast.exe" --tray'
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  ; Stop running tray instances cleanly via exit event
  ExecWait '"$INSTDIR\ClipToast.exe" --stop'
  Sleep 600

  Delete "$SMPROGRAMS\ClipToast.lnk"
  Delete "$SMPROGRAMS\ClipToast Audio.lnk"
  Delete "$SMPROGRAMS\ClipToast Audio (M).lnk"
  Delete "$SMPROGRAMS\ClipToast Tray.lnk"
  Delete "$SMPROGRAMS\ClipToast Settings.lnk"
  Delete "$SMPROGRAMS\Link Downloader.lnk"
  Delete "$SMPROGRAMS\Link Downloader Settings.lnk"
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\LinkGrab"
  DeleteRegKey HKCU "Software\Classes\AppUserModelId\ClipToast"
  DeleteRegKey HKCU "Software\Classes\cliptoast"
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "ClipToastTray"
  SetOutPath "$TEMP"
  RMDir /r "$INSTDIR"
SectionEnd
