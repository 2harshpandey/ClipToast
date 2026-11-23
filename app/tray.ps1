# tray.ps1 - Windows system tray icon for ClipToast
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

# Single instance enforcement with WaitOne timeout resilience for seamless auto-update restarts
$mutex = $null
$hasLock = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\ClipToast_Tray_Mutex')
    $hasLock = $mutex.WaitOne(3000) # Wait up to 3 seconds for any exiting instance to release
} catch [System.Threading.AbandonedMutexException] {
    $hasLock = $true
} catch {
    $hasLock = $false
}
if (-not $hasLock) {
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Clean up any leftover temporary files or orphaned folders from previous sessions immediately
Clear-ClipToastOrphans

# Global low-level keyboard hook to capture Ctrl+Alt+G (Video) and Ctrl+Alt+A / Ctrl+Alt+M (Audio)
# This guarantees 100% reliable hotkey delivery even if another app called RegisterHotKey or Explorer didn't refresh
if (-not ([System.Management.Automation.PSTypeName]'ClipToastHotkeys').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public class ClipToastHotkeys {
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int VK_MENU = 0x12;    // Alt
    private const int VK_CONTROL = 0x11; // Ctrl
    private const int VK_A = 0x41;
    private const int VK_G = 0x47;
    private const int VK_M = 0x4D;

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    public delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
    public delegate void HotkeyActionHandler(string action);

    public static event HotkeyActionHandler OnHotkeyAction;

    private static IntPtr _hookId = IntPtr.Zero;
    private static LowLevelKeyboardProc _proc = HookCallback;
    private static long _lastTick = 0;

    public static bool Start() {
        if (_hookId != IntPtr.Zero) return true;
        try {
            using (Process curProcess = Process.GetCurrentProcess())
            using (ProcessModule curModule = curProcess.MainModule) {
                _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(curModule.ModuleName), 0);
            }
            return _hookId != IntPtr.Zero;
        } catch {
            return false;
        }
    }

    public static void Stop() {
        if (_hookId != IntPtr.Zero) {
            try {
                UnhookWindowsHookEx(_hookId);
            } catch {}
            _hookId = IntPtr.Zero;
        }
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            int msg = wParam.ToInt32();
            if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN || msg == WM_KEYUP || msg == WM_SYSKEYUP) {
                int vkCode = Marshal.ReadInt32(lParam);
                bool ctrl = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
                bool alt  = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;

                if (ctrl && alt) {
                    if (vkCode == VK_G) {
                        if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
                            long now = DateTime.UtcNow.Ticks;
                            if ((now - _lastTick) > 12000000L) {
                                _lastTick = now;
                                if (OnHotkeyAction != null) {
                                    OnHotkeyAction("video");
                                }
                            }
                        }
                        return (IntPtr)1; // Consume keystroke so Windows Explorer does not launch a second instance
                    } else if (vkCode == VK_A || vkCode == VK_M) {
                        if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
                            long now = DateTime.UtcNow.Ticks;
                            if ((now - _lastTick) > 12000000L) {
                                _lastTick = now;
                                if (OnHotkeyAction != null) {
                                    OnHotkeyAction("audio");
                                }
                            }
                        }
                        return (IntPtr)1; // Consume keystroke
                    }
                }
            }
        }
        return CallNextHookEx(_hookId, nCode, wParam, lParam);
    }
}
"@
}

try {
    [ClipToastHotkeys]::add_OnHotkeyAction({
        param($action)
        try {
            if ($action -eq 'audio') {
                Start-ClipToastScript 'downloader.ps1' @('-AudioOnly')
            } else {
                Start-ClipToastScript 'downloader.ps1'
            }
        } catch { Write-Log "Tray hotkey dispatch failed: $_" }
    })
    [void][ClipToastHotkeys]::Start()
} catch {
    Write-Log "Failed to register tray hotkey listener: $_"
}

# Locate application icon
$ico = Join-Path $AppDir 'cliptoast.ico'
if (-not (Test-Path -LiteralPath $ico)) { $ico = Join-Path $Root 'cliptoast.ico' }

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
if (Test-Path -LiteralPath $ico) {
    try {
        $notifyIcon.Icon = New-Object System.Drawing.Icon($ico)
    } catch {
        $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
    }
} else {
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
}

$notifyIcon.Text = 'ClipToast - Clipboard Media Downloader'
$notifyIcon.Visible = $true

# Context Menu
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$itemVideo = $menu.Items.Add(("{0}  Download Video" -f $EmojiVideo))
$itemVideo.Add_Click({
    try {
        Start-ClipToastScript 'downloader.ps1'
    } catch { Write-Log "Tray Download Video failed: $_" }
})

$itemAudio = $menu.Items.Add(("{0}  Download MP3 Audio Only" -f $EmojiMusic))
$itemAudio.Add_Click({
    try {
        Start-ClipToastScript 'downloader.ps1' @('-AudioOnly')
    } catch { Write-Log "Tray Download MP3 failed: $_" }
})

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$itemFolder = $menu.Items.Add(("{0}  Open Downloads Folder" -f $EmojiFolder))
$itemFolder.Add_Click({
    try {
        $cfg = Read-Config
        $dir = [string]$cfg['DownloadDir']
        if (-not $dir) { $dir = Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'ClipToast Downloads' }
        if (-not (Test-Path -LiteralPath $dir)) {
            try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch {}
        }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $dir) -ErrorAction SilentlyContinue
    } catch { Write-Log "Tray Open Folder failed: $_" }
})

$itemSettings = $menu.Items.Add(("{0}  Settings" -f $EmojiGear))
$itemSettings.Add_Click({
    try {
        Start-ClipToastScript 'settings.ps1'
    } catch { Write-Log "Tray Settings failed: $_" }
})

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$itemExit = $menu.Items.Add(("{0}  Exit" -f $EmojiExit))
$itemExit.Add_Click({
    try { [ClipToastHotkeys]::Stop() } catch {}
    try {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    } catch {}
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
    [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $menu

# Left-click immediately triggers download for clipboard link
$notifyIcon.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        try {
            Start-ClipToastScript 'downloader.ps1'
        } catch { Write-Log "Tray Click failed: $_" }
    }
})

$script:exitEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\ClipToast_Tray_Exit')
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 500
$pollTimer.Add_Tick({
    try {
        if ($script:exitEvent.WaitOne(0)) {
            $pollTimer.Stop()
            $pollTimer.Dispose()
            if ($cleanTimer) { $cleanTimer.Stop(); $cleanTimer.Dispose() }
            if ($updateTimer) { $updateTimer.Stop(); $updateTimer.Dispose() }
            if ($initUpdateTimer) { $initUpdateTimer.Stop(); $initUpdateTimer.Dispose() }
            try { [ClipToastHotkeys]::Stop() } catch {}
            try {
                $notifyIcon.Visible = $false
                $notifyIcon.Dispose()
            } catch {}
            if ($mutex) {
                try { $mutex.ReleaseMutex() } catch {}
                $mutex.Dispose()
            }
            Clear-ClipToastOrphans
            [System.Windows.Forms.Application]::Exit()
        }
    } catch {}
})
$pollTimer.Start()

# Periodic background orphan cleaner (runs every 10 minutes)
$cleanTimer = New-Object System.Windows.Forms.Timer
$cleanTimer.Interval = 600000
$cleanTimer.Add_Tick({
    Clear-ClipToastOrphans
})
$cleanTimer.Start()

# Periodic background idle auto-updater (checks every 30 minutes; triggers when elapsed > 6h for app, > 72h for yt-dlp)
$script:CheckIdleUpdates = {
    try {
        $cfg = Read-Config
        $nowUnix = Get-UnixNow
        $lastAppCheck = [int64]0
        $lastYtdlpCheck = [int64]0
        [void][int64]::TryParse([string]$cfg['LastUpdateCheck'], [ref]$lastAppCheck)
        [void][int64]::TryParse([string]$cfg['LastYtdlpUpdate'], [ref]$lastYtdlpCheck)

        $needsAppCheck = ($cfg['AutoUpdate'] -ne '0' -and ($nowUnix - $lastAppCheck) -gt 21600)
        $needsYtdlpCheck = (($nowUnix - $lastYtdlpCheck) -gt 259200)

        if ($needsAppCheck -or $needsYtdlpCheck) {
            if ($needsAppCheck) { $cfg['LastUpdateCheck'] = [string]$nowUnix }
            if ($needsYtdlpCheck) { $cfg['LastYtdlpUpdate'] = [string]$nowUnix }
            Write-Config $cfg

            $bgCmds = New-Object System.Collections.Generic.List[string]
            $safeAppDir = $AppDir.Replace("'", "''")
            if ($needsAppCheck) {
                $bgCmds.Add(". (Join-Path '$safeAppDir' 'common.ps1'); [void](Invoke-AppUpdate)")
            }
            if ($needsYtdlpCheck) {
                $ytBin = Join-Path $Bin 'yt-dlp.exe'
                if (Test-Path -LiteralPath $ytBin) {
                    $safeYtBin = $ytBin.Replace("'", "''")
                    $bgCmds.Add("try { & '$safeYtBin' -U 2>&1 | Out-Null } catch {}")
                }
            }
            if ($bgCmds.Count -gt 0) {
                Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ($bgCmds -join '; ')
                ) -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Log "Tray idle update check failed: $_"
    }
}

$updateTimer = New-Object System.Windows.Forms.Timer
$updateTimer.Interval = 1800000 # 30 minutes
$updateTimer.Add_Tick({
    & $script:CheckIdleUpdates
})
$updateTimer.Start()

# Initial update check shortly after tray startup (delayed 30s to allow system boot to settle)
$initUpdateTimer = New-Object System.Windows.Forms.Timer
$initUpdateTimer.Interval = 30000 # 30 seconds
$initUpdateTimer.Add_Tick({
    try {
        $initUpdateTimer.Stop()
        $initUpdateTimer.Dispose()
    } catch {}
    & $script:CheckIdleUpdates
})
$initUpdateTimer.Start()

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    try { if ($cleanTimer) { $cleanTimer.Stop(); $cleanTimer.Dispose() } } catch {}
    try { if ($updateTimer) { $updateTimer.Stop(); $updateTimer.Dispose() } } catch {}
    try { if ($initUpdateTimer) { $initUpdateTimer.Stop(); $initUpdateTimer.Dispose() } } catch {}
    try { [ClipToastHotkeys]::Stop() } catch {}
    try {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    } catch {}
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
    Clear-ClipToastOrphans
}
