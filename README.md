# ClipToast

[![Windows 11](https://img.shields.io/badge/Platform-Windows%2011%20%7C%2010-0078D6?logo=windows&logoColor=white)](https://github.com/2harshpandey/ClipToast)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version 1.1.1](https://img.shields.io/badge/Version-1.1.1-blue.svg)](https://github.com/2harshpandey/ClipToast/releases)
[![GitHub Stars](https://img.shields.io/github/stars/2harshpandey/ClipToast?style=flat&logo=github)](https://github.com/2harshpandey/ClipToast/stargazers)
[![Powered by yt-dlp](https://img.shields.io/badge/Engine-yt--dlp-red.svg)](https://github.com/yt-dlp/yt-dlp)
[![Media Processing](https://img.shields.io/badge/Converter-FFmpeg-green.svg)](https://ffmpeg.org/)

ClipToast is a media downloader for Windows 10 and 11. Copy any video or music link from your browser or chat, press a shortcut or click the tray icon, and ClipToast downloads the media in the background with interactive Windows toast notifications.

<div align="center">
  <img src=".github/assets/demo.gif" alt="ClipToast Live Download Progress in Windows Toast" width="680" />
  <p><em>Real-time download progress, transfer speed, estimated time remaining, and controls inside native Windows toast notifications.</em></p>
</div>

---

## Features

- **Keyboard Shortcuts**:
  - **Ctrl + Alt + G**: Downloads video and saves it as a universal MP4 file ready for playback and messaging.
  - **Ctrl + Alt + A** or **Ctrl + Alt + M**: Extracts 320kbps MP3 audio with embedded artwork and track tags.
- **System Tray Integration**:
  - Left click to download the current link in your clipboard.
  - Right click to open the menu for video, audio, downloads folder, settings, and exit.
- **Interactive Windows Toasts**:
  - Shows progress, speed, remaining time, and media title.
  - Includes a cancel button to stop an active download at any moment.
  - Provides play and open folder buttons once the file finishes.
- **Automatic Caption Handling**: Downloads synchronized srt subtitles when provided by the site. If captions are not available or blocked by server rate limits, the video still downloads completely without failing.
- **Error Diagnostics**: When an unhandled error occurs, the notification provides a report button that opens a prefilled GitHub issue with sanitized diagnostic details and no private data.
- **Tray Auto-Restore**: If you close the tray process, it reopens automatically when you trigger your next download shortcut, or you can start it from the settings window.
- **Universal MP4 Compatibility**: Videos are converted to H.264 video with AAC audio and faststart flags so they play across WhatsApp, web browsers, mobile phones, and TV players without codec errors.
- **SDR Color Preservation**: Prefers SDR formats over raw HDR to prevent washed out colors on standard computer displays.
- **Per-User Setup**: Installs under local user application data without requiring administrator privileges or User Account Control prompts.
- **Signed Auto-Updates**: Checks for updates from GitHub releases using RSA signature verification to ensure packages are authentic.
- **Browser Cookies**: Can import session cookies from Chrome, Edge, Firefox, or Brave through settings for links requiring login.

---

## Supported Platforms

ClipToast uses [yt-dlp](https://github.com/yt-dlp/yt-dlp) as its extraction engine, which supports media from more than one thousand sites.

| Platform | Capabilities |
| :--- | :--- |
| **YouTube** | Up to 8K resolution, Shorts, YouTube Music, and srt captions |
| **Instagram** | High resolution Reels, video posts, and carousel items |
| **TikTok** | Direct video downloads without watermarks |
| **Reddit** | Merges separated video and audio tracks into a unified MP4 file |
| **Twitter and X** | Direct extraction of video clips and embedded animations |
| **Facebook and Pinterest** | Public video posts, reels, and clips |
| **SoundCloud and Bandcamp** | Audio extraction saved directly as tagged MP3 files |
| **Twitch and Vimeo** | Clips, broadcasts, and high bitrate video streams |

---

## Installation

### Installer Setup

1. Open the [Releases](https://github.com/2harshpandey/ClipToast/releases) page.
2. Download [ClipToastSetup-v1.1.1.exe](https://github.com/2harshpandey/ClipToast/releases/latest/download/ClipToastSetup-v1.1.1.exe).
3. Run the installer. No administrator rights are needed.
4. Select your preferred download directory.
5. ClipToast sets up required tools and places an icon in your notification area.

If Windows SmartScreen shows a warning on first run because the project is independent and not signed with an expensive commercial certificate, click More info and then Run anyway.

### Portable Version

If you prefer to run ClipToast without installing:

1. Download [ClipToast-v1.1.1-portable.zip](https://github.com/2harshpandey/ClipToast/releases/latest/download/ClipToast-v1.1.1-portable.zip) from the [Releases](https://github.com/2harshpandey/ClipToast/releases) page.
2. Extract the archive into a folder of your choice.
3. Run `ClipToast.exe` directly.

---

## Usage

1. Copy a video or music link to your clipboard.
2. Trigger the download using any of these methods:
   - Press **Ctrl + Alt + G** for video.
   - Press **Ctrl + Alt + A** or **Ctrl + Alt + M** for MP3 audio.
   - Click the ClipToast system tray icon near your clock.
3. A Windows notification will appear showing progress, speed, and time remaining. You can click Cancel at any point to stop the transfer.
4. When finished, use the Play button to watch or listen immediately, or use Open folder to view the file in File Explorer.

---

## Settings and System Tray

<div align="center">
  <img src=".github/assets/tray-menu.png" alt="ClipToast System Tray Menu" width="300" />
</div>

Right-click the notification area icon near the clock or open ClipToast Settings from the Start Menu to access options:

- **Download Video**: Downloads and converts the copied link to an MP4 file.
- **Download MP3 Audio Only**: Extracts audio directly to a 320kbps MP3 file.
- **Open Downloads Folder**: Opens the destination directory in File Explorer.
- **Settings**:
  - **Download folder**: Change destination path for completed files.
  - **Maximum video quality**: Choose 1080p, 720p, 1440p, or best available up to 4K and 8K.
  - **Subtitles**: Enable or disable automatic subtitle downloads.
  - **Startup**: Configure ClipToast to start when Windows boots, or click Start Tray Now to launch the tray icon immediately.
  - **Browser login cookies**: Select your primary browser to access links that require an active session.
  - **Updates**: Toggle background update checks or check manually at any time.
- **Exit**: Closes the tray program. It will reopen automatically the next time you press a download hotkey.

---

## Repository Structure

```
ClipToast/
├── .github/                  # Community templates and documentation assets
│   ├── assets/               # Screenshots and animations
│   │   ├── demo.gif          # Toast notification preview
│   │   └── tray-menu.png     # Tray menu screenshot
│   ├── ISSUE_TEMPLATE/       # Templates for bug reports and features
│   └── pull_request_template.md
├── app/                      # Application runtime scripts
│   ├── common.ps1            # Shared toast functions and configuration
│   ├── downloader.ps1        # Download orchestrator and media pipeline
│   ├── action.ps1            # Toast button event dispatcher
│   ├── tray.ps1              # Notification area icon and shortcut hooks
│   ├── install-tools.ps1     # Downloader for yt-dlp, FFmpeg, and Deno
│   ├── settings.ps1          # Settings interface
│   ├── update-public-key.xml # Public key for signature validation
│   ├── cliptoast.ico         # Application icon
│   ├── cliptoast.png         # Toast logo asset
│   └── version.txt           # Current version number
├── release/                  # Built release artifacts
│   ├── ClipToastSetup-v1.1.1.exe     # Installer executable
│   ├── ClipToast-v1.1.1-portable.zip # Portable zip package
│   ├── ClipToast-app-1.1.1.zip       # Signed update bundle
│   ├── latest.json                   # Update metadata manifest
│   └── RELEASE_NOTES_v1.1.1.md       # Formatted release notes
├── src/
│   └── launcher/
│       ├── Program.cs        # Source code for the launcher
│       └── ClipToast.exe     # Compiled launcher binary
├── cliptoast.ico             # Application icon
├── cliptoast.png             # Application logo
├── installer-sidebar.bmp     # Installer wizard graphic
├── installer.nsi             # NSIS installer script
├── make-update.ps1           # Packaging and signing script
├── CODE_OF_CONDUCT.md        # Code of conduct
├── CONTRIBUTING.md           # Development and contribution guide
├── SECURITY.md               # Security policy
├── LICENSE                   # MIT License
└── README.md
```

### Dependencies

Runtime tools including [yt-dlp](https://github.com/yt-dlp/yt-dlp), [FFmpeg](https://ffmpeg.org/), [ffprobe](https://ffmpeg.org/), and [Deno](https://deno.land/) are downloaded directly from their official releases and placed in local application data under the bin directory.

---

## SmartScreen and Security

ClipToast is an open source community project that does not use a paid enterprise code signing certificate. New releases may trigger a SmartScreen prompt because automated reputation systems take time to establish trust for newly compiled binaries.

### SmartScreen Steps

If Windows presents a blue protective prompt on first execution:

1. Click **More info**.
2. Click **Run anyway**.

### Security Practices

- **Antivirus Clean**: Scans clean across Microsoft Defender, Kaspersky, BitDefender, Avast, Sophos, and CrowdStrike.
- **Native Launcher**: ClipToast uses a compiled C# binary to launch background scripts rather than generic Windows script wrappers.
- **Clean Installer**: The NSIS installer writes configuration directly without running hidden command line bypasses.
- **On Demand Setup**: Tool downloads take place after installation so setup remains predictable and transparent.
- **Source Inspection**: The full source code is public and can be audited and built locally.

---

## Building from Source

To compile the launcher binary:

```cmd
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /win32icon:cliptoast.ico /optimize+ /platform:anycpu /out:src\launcher\ClipToast.exe src\launcher\Program.cs
```

To build the installer executable:

```cmd
makensis.exe installer.nsi
```

To create and sign an update package:

```powershell
.\make-update.ps1 -Version 1.1.1 -Notes "Release notes summary" -PrivateKey "C:\path\to\PRIVATE-update-signing-key.xml"
```

This generates the update zip, the portable zip, and the latest.json metadata file in the release folder. Existing installations check this manifest and verify the signature before updating.

---

## Community

- [Security Policy](SECURITY.md): Vulnerability disclosure and privacy details.
- [Contributing Guidelines](CONTRIBUTING.md): Build instructions and contribution standards.
- [Code of Conduct](CODE_OF_CONDUCT.md): Community standards.

---

## License

This project is licensed under the [MIT License](LICENSE). Built using [yt-dlp](https://github.com/yt-dlp/yt-dlp), [FFmpeg](https://ffmpeg.org/), and [Deno](https://deno.land/).
