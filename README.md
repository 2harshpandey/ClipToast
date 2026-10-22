# ClipToast - Seamless Windows Clipboard Media Downloader

[![Windows 11](https://img.shields.io/badge/Platform-Windows%2011%20%7C%2010-0078D6?logo=windows&logoColor=white)](https://github.com/2harshpandey/ClipToast)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Powered by yt-dlp](https://img.shields.io/badge/Engine-yt--dlp-red.svg)](https://github.com/yt-dlp/yt-dlp)
[![Media Processing](https://img.shields.io/badge/Converter-FFmpeg-green.svg)](https://ffmpeg.org/)
[![Toast Notifications](https://img.shields.io/badge/UI-Live%20WinRT%20Toasts-blueviolet.svg)](https://github.com/2harshpandey/ClipToast)

> **ClipToast** is a lightweight, background media downloader for Windows 11 and Windows 10. Copy any video link (YouTube, Instagram Reels, etc.), press `Ctrl+Alt+G`, and ClipToast downloads the highest quality stream directly to your PC with live native Windows toast notifications.

---

## ⚡ Highlights

- 📋 **Zero-Friction Trigger**: Copy a link and press <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>G</kbd> (or click **ClipToast** in the Start Menu). No terminal windows, no bulky browser extensions.
- 🔔 **Real-Time Toast Notifications**: Displays live download progress, download speed, ETA, and media title using native Windows WinRT Toast Notifications. Includes a 1-click **"Open folder"** button when finished.
- 📱 **WhatsApp & Universal Playback Guarantee**: Automatically remuxes or converts downloads to **MP4 (H.264 + AAC + yuv420p + faststart)** so videos play natively on WhatsApp Web/Desktop, iPhone, Android, and smart TVs without "unsupported format" errors.
- 🎨 **SDR Color Preservation**: Automatically avoids washed-out HDR-to-SDR conversions by preferring high-bitrate SDR streams.
- 🔒 **Zero-Admin Installer**: Installs entirely in user space (`%LOCALAPPDATA%\ClipToast`) with no UAC prompts and registers standard Windows Add/Remove programs integration.
- 🛡️ **Cryptographically Signed Auto-Updates**: Built-in RSA-SHA256 signature verification guarantees tamper-proof background updates directly from GitHub Releases.
- 🍪 **Login & Cookie Integration**: Easily pass cookies from Firefox, Chrome, Edge, or Brave via the Settings UI to download private or age-restricted content.

---

## 📥 Installation

1. Go to the [Releases](https://github.com/2harshpandey/ClipToast/releases) page.
2. Download **`ClipToastSetup-v1.0.exe`**.
3. Run the installer (no administrator privileges required).
4. Choose your preferred download directory (default: `Downloads\ClipToast`).
5. You're ready to go!

---

## 🚀 How to Use

1. **Copy any video link** to your clipboard (e.g., from YouTube, Instagram Reels/Posts, TikTok, Reddit, etc.).
2. Press **<kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>G</kbd>** or click **ClipToast** in the Windows Start menu.
3. A Windows Toast Notification will pop up tracking download speed, progress %, and conversion.
4. Click **"Open folder"** on the completion notification to jump straight to your downloaded MP4.

### Settings

Access settings via the Start Menu: **ClipToast Settings**.
- **Download folder**: Change destination path anytime.
- **Maximum video quality**: Cap resolutions at 1080p (recommended for speed) or leave unconstrained (up to 4K / 8K).
- **Browser login cookies**: Select your browser to access account-locked or Instagram-walled videos.
- **Update preferences**: Toggle auto-updates or click **Check for updates** anytime.

---

## 🛠️ Architecture

```
ClipToast/
├── app/
│   ├── common.ps1            # Shared WinRT toasts, config management, signed self-update
│   ├── downloader.ps1        # Clipboard reader, yt-dlp orchestrator, FFmpeg WhatsApp-safe pipeline
│   ├── install.ps1           # Initial configuration hook called by installer
│   ├── install-tools.ps1     # Automated downloader for yt-dlp, FFmpeg, ffprobe, and Deno
│   ├── run.vbs               # Silent VBScript wrapper preventing console window popups
│   ├── settings.ps1          # WinForms GUI for user preferences and manual updates
│   ├── update-public-key.xml # RSA public key for cryptographic update verification
│   └── version.txt           # App version manifest
├── cliptoast.ico             # High-resolution application icon
├── installer.nsi             # NSIS installer definition (builds ClipToastSetup-v1.0.exe)
├── make-update.ps1           # Release packaging and RSA signing tool
└── README.md
```

### Dependencies
Runtime tools (`yt-dlp`, `FFmpeg`, `ffprobe`, `Deno`) are fetched directly from their official GitHub releases at install time and reside in `%LOCALAPPDATA%\ClipToast\bin`.

---

## 🔐 Publishing Updates

Updates are signed with an RSA-2048 private key. To package and sign a new release:

```powershell
.\make-update.ps1 -Version 1.0.1 -Notes "What changed in this update" `
    -PrivateKey "C:\path\to\PRIVATE-update-signing-key.xml"
```

This generates `release\ClipToast-app-1.0.1.zip` and signed `release\latest.json`. Upload both to the corresponding GitHub Release tag `v1.0.1`. Existing client installations will automatically verify the signature against `update-public-key.xml` and install in the background.

---

## 📜 License

Distributed under the [MIT License](LICENSE). Built on top of [yt-dlp](https://github.com/yt-dlp/yt-dlp), [FFmpeg](https://ffmpeg.org/), and [Deno](https://deno.land/).
