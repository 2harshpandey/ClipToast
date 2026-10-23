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

$itemVideo = $menu.Items.Add(("{0}  Download Video" -f (Get-EmojiVideo)))
$itemVideo.Add_Click({
    try {
        $vbs = Join-Path $AppDir 'run.vbs'
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" downloader.ps1' -f $vbs) -ErrorAction SilentlyContinue
    } catch { Write-Log "Tray Download Video failed: $_" }
})

$itemAudio = $menu.Items.Add(("{0}  Download MP3 Audio Only" -f (Get-EmojiMusic)))
$itemAudio.Add_Click({
    try {
        $vbs = Join-Path $AppDir 'run.vbs'
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" downloader.ps1 -AudioOnly' -f $vbs) -ErrorAction SilentlyContinue
    } catch { Write-Log "Tray Download MP3 failed: $_" }
})

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$itemFolder = $menu.Items.Add(("{0}  Open Downloads Folder" -f (Get-EmojiFolder)))
$itemFolder.Add_Click({
    try {
        $cfg = Read-Config
        $dir = [string]$cfg['DownloadDir']
        if (-not $dir) { $dir = Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'ClipToast' }
        if (-not (Test-Path -LiteralPath $dir)) {
            try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch { $null = $_ }
        }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $dir) -ErrorAction SilentlyContinue
    } catch { Write-Log "Tray Open Folder failed: $_" }
})

$itemSettings = $menu.Items.Add(("{0}  Settings" -f (Get-EmojiGear)))
$itemSettings.Add_Click({
    try {
        $vbs = Join-Path $AppDir 'run.vbs'
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" settings.ps1' -f $vbs) -ErrorAction SilentlyContinue
    } catch { Write-Log "Tray Settings failed: $_" }
})

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$itemExit = $menu.Items.Add(("{0}  Exit" -f (Get-EmojiExit)))
$itemExit.Add_Click({
    try {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    } catch { $null = $_ }
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch { $null = $_ }
        $mutex.Dispose()
    }
    [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $menu

# Left-click immediately triggers download for clipboard link
$notifyIcon.Add_MouseClick({
    if ($args.Count -ge 2 -and $args[1].Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        try {
            $vbs = Join-Path $AppDir 'run.vbs'
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" downloader.ps1' -f $vbs) -ErrorAction SilentlyContinue
        } catch { Write-Log "Tray Click failed: $_" }
    }
})

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    try {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    } catch { $null = $_ }
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch { $null = $_ }
        $mutex.Dispose()
    }
}
