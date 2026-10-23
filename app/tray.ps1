# tray.ps1 - Windows system tray icon for ClipToast
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

# Single instance enforcement with AbandonedMutex resilience
$mutexCreated = $false
try {
    $mutex = New-Object System.Threading.Mutex($true, 'Local\ClipToast_Tray_Mutex', [ref]$mutexCreated)
} catch [System.Threading.AbandonedMutexException] {
    $mutexCreated = $true
} catch {
    $mutexCreated = $false
}
if (-not $mutexCreated) {
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

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
    private const int WM_SYSKEYDOWN = 0x0104;
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
        if (nCode >= 0 && (wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN)) {
            int vkCode = Marshal.ReadInt32(lParam);
            bool ctrl = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
            bool alt  = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;

            if (ctrl && alt) {
                long now = DateTime.UtcNow.Ticks;
                // 1.2 second debounce to prevent rapid fire
                if ((now - _lastTick) > 12000000L) {
                    if (vkCode == VK_G) {
                        _lastTick = now;
                        if (OnHotkeyAction != null) {
                            OnHotkeyAction("video");
                        }
                    } else if (vkCode == VK_A || vkCode == VK_M) {
                        _lastTick = now;
                        if (OnHotkeyAction != null) {
                            OnHotkeyAction("audio");
                        }
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
            $vbs = Join-Path $AppDir 'run.vbs'
            if ($action -eq 'audio') {
                Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" downloader.ps1 -AudioOnly' -f $vbs) -ErrorAction SilentlyContinue
            } else {
                Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" downloader.ps1' -f $vbs) -ErrorAction SilentlyContinue
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
        $vbs = Join-Path $AppDir 'run.vbs'
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" downloader.ps1' -f $vbs) -ErrorAction SilentlyContinue
    } catch { Write-Log "Tray Download Video failed: $_" }
})

$itemAudio = $menu.Items.Add(("{0}  Download MP3 Audio Only" -f $EmojiMusic))
$itemAudio.Add_Click({
    try {
        $vbs = Join-Path $AppDir 'run.vbs'
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" downloader.ps1 -AudioOnly' -f $vbs) -ErrorAction SilentlyContinue
    } catch { Write-Log "Tray Download MP3 failed: $_" }
})

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$itemFolder = $menu.Items.Add(("{0}  Open Downloads Folder" -f $EmojiFolder))
$itemFolder.Add_Click({
    try {
        $cfg = Read-Config
        $dir = [string]$cfg['DownloadDir']
        if (-not $dir) { $dir = Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'ClipToast' }
        if (-not (Test-Path -LiteralPath $dir)) {
            try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch {}
        }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $dir) -ErrorAction SilentlyContinue
    } catch { Write-Log "Tray Open Folder failed: $_" }
})

$itemSettings = $menu.Items.Add(("{0}  Settings" -f $EmojiGear))
$itemSettings.Add_Click({
    try {
        $vbs = Join-Path $AppDir 'run.vbs'
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" settings.ps1' -f $vbs) -ErrorAction SilentlyContinue
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
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        try {
            $vbs = Join-Path $AppDir 'run.vbs'
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" downloader.ps1' -f $vbs) -ErrorAction SilentlyContinue
        } catch { Write-Log "Tray Click failed: $_" }
    }
})

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    try { [ClipToastHotkeys]::Stop() } catch {}
    try {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    } catch {}
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}
