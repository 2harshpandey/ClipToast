# tray.ps1 - Windows system tray icon for ClipToast
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

# Single instance enforcement
$mutexCreated = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ClipToast_Tray_Mutex', [ref]$mutexCreated)
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

$itemVideo = $menu.Items.Add(("{0}  Download Video" -f $EmojiVideo))
$itemVideo.Add_Click({
    $vbs = Join-Path $AppDir 'run.vbs'
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" downloader.ps1' -f $vbs) -ErrorAction SilentlyContinue
})

$itemAudio = $menu.Items.Add(("{0}  Download MP3 Audio Only" -f $EmojiMusic))
$itemAudio.Add_Click({
    $vbs = Join-Path $AppDir 'run.vbs'
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" downloader.ps1 -AudioOnly' -f $vbs) -ErrorAction SilentlyContinue
})

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$itemFolder = $menu.Items.Add(("{0}  Open Downloads Folder" -f $EmojiFolder))
$itemFolder.Add_Click({
    $cfg = Read-Config
    $dir = [string]$cfg['DownloadDir']
    if (-not $dir) { $dir = Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'ClipToast' }
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch {}
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $dir) -ErrorAction SilentlyContinue
})

$itemSettings = $menu.Items.Add(("{0}  Settings" -f $EmojiGear))
$itemSettings.Add_Click({
    $vbs = Join-Path $AppDir 'run.vbs'
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" settings.ps1' -f $vbs) -ErrorAction SilentlyContinue
})

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$itemExit = $menu.Items.Add(("{0}  Exit" -f $EmojiExit))
$itemExit.Add_Click({
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
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
        $vbs = Join-Path $AppDir 'run.vbs'
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" downloader.ps1' -f $vbs) -ErrorAction SilentlyContinue
    }
})

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}
