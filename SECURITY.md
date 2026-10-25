# Security Policy

ClipToast is a free, open-source Windows clipboard media downloader. We take the security, integrity, and privacy of our software and users seriously.

---

## Supported Versions

Only the latest stable release of ClipToast receives security updates and vulnerability patches.

| Version | Supported          |
| ------- | ------------------ |
| 1.1.x   | :white_check_mark: |
| < 1.1.0 | :x:                |

We strongly encourage all users to enable **Install app updates automatically** in ClipToast Settings, or check for updates regularly.

---

## Reporting a Vulnerability

If you discover a security vulnerability, flaw, or bug that could compromise user safety, please report it responsibly:

1. **Do NOT open a public GitHub issue** for undisclosed security vulnerabilities.
2. Email your findings directly to the project maintainer:
   * **Contact:** `harshpandey` (via GitHub profile / Security Advisories tab)
   * Or use the private [GitHub Security Advisory](https://github.com/2harshpandey/ClipToast/security/advisories/new) feature on this repository.
3. Please include:
   * A clear description of the vulnerability.
   * Step-by-step reproduction instructions or proof-of-concept.
   * Impact assessment (what an attacker could achieve).

We will acknowledge your report within 48 hours and work with you to validate, fix, and publish a patched release before any public disclosure.

---

## Security Architecture & Privacy Principles

ClipToast is designed with a defense-in-depth security model:

* **Zero Telemetry & Zero Tracking:** ClipToast collects no personally identifiable information (PII), browsing history, or clipboard contents. Download history is stored exclusively on your local machine.
* **Opt-In Anonymous Error Reporting:** If a download or tool configuration fails, users may click an explicit "Report issue" button. The error payload contains only sanitized technical details (site domain, HTTP status code, OS version) and zero user identity.
* **Cryptographically Signed Auto-Updates:** Update archives (`.zip`) are cryptographically verified using **RSA SHA-256** signatures against the embedded `update-public-key.xml` before any file is extracted or replaced. Tampered or unsigned packages are immediately discarded.
* **No Administrative Privileges Required:** ClipToast runs entirely within per-user scope (`%LOCALAPPDATA%\ClipToast`). It never requests Windows UAC Administrator rights or alters protected system files.
* **Native Win32 Launcher (`ClipToast.exe`):** Background routines are dispatched through a compiled C# Windows GUI launcher with embedded application metadata, avoiding Living-off-the-Land (LOLBIN) script hosts (`wscript.exe`).
* **Official Upstream Tool Dependencies:** Third-party dependencies (`yt-dlp`, `FFmpeg`, `Deno`) are fetched exclusively from their official verified GitHub release repositories.

---

## Antivirus & Heuristic False Positives

Because ClipToast is an independent open-source project without a paid corporate EV code-signing certificate ($400+/year), automated machine-learning scanners (e.g. SmartScreen, generic AI heuristics) may initially classify newly compiled binaries as "Anomalous" or "Unknown Publisher".

* **Clean Verifications:** ClipToast is verified clean against major antivirus engines including Microsoft Defender, Kaspersky, BitDefender, Avast, AVG, and CrowdStrike.
* **SHA-256 Checksums:** Cryptographic SHA-256 checksums are published with every official release. Users can verify the integrity of their download independently:
  ```powershell
  Get-FileHash ClipToastSetup-v1.1.1.exe -Algorithm SHA256
  ```
* **Source Transparency:** Every line of code is open source and available for inspection in this repository.
