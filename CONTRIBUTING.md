# Contributing to ClipToast

Thank you for your interest in contributing to ClipToast! We welcome bug reports, feature requests, documentation improvements, and pull requests.

---

## Code of Conduct

This project and everyone participating in it is governed by the [ClipToast Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

---

## How Can I Contribute?

### Reporting Bugs
Before creating bug reports, please check existing issues to avoid duplicates. When filing a bug report, please include:
* **Operating System & Version** (e.g. Windows 11 Build 22631).
* **ClipToast Version** (e.g. 1.1.0).
* **Steps to Reproduce** the issue clearly.
* **Expected vs. Actual Behavior**.
* Relevant snippets from `%LOCALAPPDATA%\ClipToast\log.txt` (ensure no private URLs/tokens are exposed).

### Suggesting Enhancements
Feature requests are tracked as GitHub Issues. Explain:
* The problem you are trying to solve.
* Why this feature would benefit ClipToast users.
* Any possible implementation ideas or examples from other tools.

---

## Development Setup

ClipToast is built with lightweight, zero-dependency tools native to Windows:
* **PowerShell 5.1+** (Windows built-in) for the core media pipeline and background tasks.
* **C# (.NET Framework 4.8 / `csc.exe`)** for the compiled native GUI launcher (`ClipToast.exe`).
* **NSIS 3.x** (`makensis.exe`) for building the standalone setup installer.

### 1. Repository Structure
```
ClipToast/
├── app/                      # Runtime PowerShell scripts and assets
│   ├── common.ps1            # Shared WinRT toasts, config management, auto-updater
│   ├── downloader.ps1        # Media downloader and WhatsApp-safe FFmpeg pipeline
│   ├── action.ps1            # Toast notification protocol dispatcher
│   ├── tray.ps1              # System tray notification area app & hotkeys
│   ├── install-tools.ps1     # Automated downloader for yt-dlp, FFmpeg, Deno
│   ├── settings.ps1          # WinForms GUI preferences window
│   ├── update-public-key.xml # RSA public key for cryptographic updates
│   ├── cliptoast.ico         # Notification & tray icon
│   ├── cliptoast.png         # Modern toast logo
│   └── version.txt           # App version manifest
├── release/                  # Built distribution assets
│   ├── ClipToastSetup-v1.1.exe   # Setup installer wizard
│   ├── ClipToast-v1.1.0-portable.zip # Zero-install portable package
│   ├── ClipToast-app-1.1.0.zip   # Signed auto-update bundle
│   └── latest.json           # Cryptographic signature manifest
├── src/
│   └── launcher/
│       ├── Program.cs        # C# source code for ClipToast.exe launcher
│       └── ClipToast.exe     # Compiled native GUI launcher
├── cliptoast.ico             # High-resolution application icon
├── cliptoast.png             # Modern notification logo
├── installer-sidebar.bmp     # Modern installer wizard sidebar branding
├── installer.nsi             # NSIS installer definition
├── make-update.ps1           # Packaging and RSA signing tool
├── LICENSE                   # MIT License
└── README.md
```

### 2. Building the Native Launcher (`ClipToast.exe`)
To recompile the C# launcher:
```cmd
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /win32icon:cliptoast.ico /reference:System.Windows.Forms.dll,System.Drawing.dll /optimize+ /platform:anycpu /out:src\launcher\ClipToast.exe src\launcher\Program.cs
```

### 3. Building the Installer (`ClipToastSetup-v1.1.exe`)
To build the setup installer using NSIS:
```cmd
makensis.exe installer.nsi
```
The output executable will be created in `release\ClipToastSetup-v1.1.exe`.

### 4. Testing Locally
To test without running the installer:
1. Run `src\launcher\ClipToast.exe --tray` to launch the system tray icon and global hotkeys.
2. Copy any video or audio link to your clipboard.
3. Press <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>G</kbd> for video or <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>A</kbd> for MP3 audio.
4. Verify the media engine downloads cleanly and sends native Windows Toast notifications.

---

## Pull Request Guidelines

1. Fork the repo and create your branch from `main`:
   ```bash
   git checkout -b feature/my-new-feature
   ```
2. Keep code style consistent:
   * PowerShell: 4 spaces indent, PascalCase function names, meaningful comments.
   * C#: Standard .NET conventions.
3. Test your changes thoroughly across edge cases (missing tools, offline mode, non-ASCII media titles, short links, subtitle extraction).
4. Do NOT commit personal configuration files (`config.txt`), log files (`log.txt`), or private signing keys (`PRIVATE-update-signing-key.xml`).
5. Open a Pull Request with a clear description of the problem solved and testing steps performed.
