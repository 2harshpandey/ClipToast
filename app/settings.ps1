# settings.ps1 - settings and configuration window for ClipToast
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$cfg = Read-Config

# Set AppUserModelID so Windows taskbar groups and displays this window under ClipToast
try {
    Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;
    public class ClipToastShell {
        [DllImport("shell32.dll", SetLastError = true)]
        public static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
    }
"@ -ErrorAction SilentlyContinue
    [ClipToastShell]::SetCurrentProcessExplicitAppUserModelID("ClipToast")
} catch {}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ClipToast - Settings'
$form.ClientSize = New-Object System.Drawing.Size(520, 440)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# High-quality icon for titlebar, taskbar, and Alt+Tab
$iconPath = Join-Path $Root 'cliptoast.ico'
if (-not (Test-Path -LiteralPath $iconPath)) { $iconPath = Join-Path $AppDir 'cliptoast.ico' }
if (-not (Test-Path -LiteralPath $iconPath)) { $iconPath = Join-Path $PSScriptRoot 'cliptoast.ico' }
if (Test-Path -LiteralPath $iconPath) {
    try {
        $form.Icon = New-Object System.Drawing.Icon($iconPath)
    } catch {}
}

function Add-Label([string]$text, [int]$x, [int]$y, [int]$w = 480) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, 18)
    $form.Controls.Add($l); return $l
}

# Download folder
[void](Add-Label 'Download folder' 20 12)
$txtDir = New-Object System.Windows.Forms.TextBox
$txtDir.Location = New-Object System.Drawing.Point(20, 32); $txtDir.Size = New-Object System.Drawing.Size(390, 24)
$txtDir.Text = $cfg['DownloadDir']
$form.Controls.Add($txtDir)
$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Browse...'; $btnBrowse.Location = New-Object System.Drawing.Point(420, 30); $btnBrowse.Size = New-Object System.Drawing.Size(80, 27)
$btnBrowse.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.SelectedPath = $txtDir.Text
    $d.ShowNewFolderButton = $true
    if ($d.ShowDialog() -eq 'OK') { $txtDir.Text = $d.SelectedPath }
})
$form.Controls.Add($btnBrowse)

# Max quality
[void](Add-Label 'Maximum video quality (higher = larger file size)' 20 68)
$cmbQ = New-Object System.Windows.Forms.ComboBox
$cmbQ.DropDownStyle = 'DropDownList'
$cmbQ.Location = New-Object System.Drawing.Point(20, 88); $cmbQ.Size = New-Object System.Drawing.Size(260, 24)
$qItems = @(
    @{ Text = 'Best available (up to 4K / 8K)'; Value = '0' },
    @{ Text = '1440p';                           Value = '1440' },
    @{ Text = '1080p (fast, recommended)';       Value = '1080' },
    @{ Text = '720p';                            Value = '720' }
)
foreach ($q in $qItems) { [void]$cmbQ.Items.Add($q.Text) }
$sel = 0
for ($i = 0; $i -lt $qItems.Count; $i++) { if ($qItems[$i].Value -eq [string]$cfg['MaxHeight']) { $sel = $i } }
$cmbQ.SelectedIndex = $sel
$form.Controls.Add($cmbQ)

# Cookies
[void](Add-Label 'Browser login cookies (for account-locked Instagram or YouTube links)' 20 122)
$cmbC = New-Object System.Windows.Forms.ComboBox
$cmbC.DropDownStyle = 'DropDownList'
$cmbC.Location = New-Object System.Drawing.Point(20, 142); $cmbC.Size = New-Object System.Drawing.Size(260, 24)
$cItems = @('', 'firefox', 'edge', 'chrome', 'brave')
foreach ($c in $cItems) { if ($c -eq '') { [void]$cmbC.Items.Add('None') } else { [void]$cmbC.Items.Add($c.Substring(0, 1).ToUpper() + $c.Substring(1)) } }
$sel = 0
for ($i = 0; $i -lt $cItems.Count; $i++) { if ($cItems[$i] -eq [string]$cfg['CookiesBrowser']) { $sel = $i } }
$cmbC.SelectedIndex = $sel
$form.Controls.Add($cmbC)

# Feature Checkboxes
$chkSubs = New-Object System.Windows.Forms.CheckBox
$chkSubs.Text = 'Save subtitles (.srt) alongside video when available'
$chkSubs.Location = New-Object System.Drawing.Point(20, 178); $chkSubs.Size = New-Object System.Drawing.Size(460, 22)
$chkSubs.Checked = ([string]$cfg['DownloadSubs'] -eq '1')
$form.Controls.Add($chkSubs)

$chkTray = New-Object System.Windows.Forms.CheckBox
$chkTray.Text = 'Run ClipToast in system tray (on Windows startup)'
$chkTray.Location = New-Object System.Drawing.Point(20, 204); $chkTray.Size = New-Object System.Drawing.Size(350, 22)
$chkTray.Checked = ([string]$cfg['StartWithWindows'] -ne '0')
$form.Controls.Add($chkTray)

$btnStartTray = New-Object System.Windows.Forms.Button
$btnStartTray.Text = 'Start Tray Now'
$btnStartTray.Location = New-Object System.Drawing.Point(380, 201); $btnStartTray.Size = New-Object System.Drawing.Size(120, 26)
$btnStartTray.Add_Click({
    $vbs = Join-Path $AppDir 'run.vbs'
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" tray.ps1' -f $vbs) -ErrorAction SilentlyContinue
    [void][System.Windows.Forms.MessageBox]::Show("ClipToast tray icon is now running near your Windows clock.", "ClipToast", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
})
$form.Controls.Add($btnStartTray)

$chkU = New-Object System.Windows.Forms.CheckBox
$chkU.Text = 'Install app updates automatically'
$chkU.Location = New-Object System.Drawing.Point(20, 230); $chkU.Size = New-Object System.Drawing.Size(460, 22)
$chkU.Checked = ([string]$cfg['AutoUpdate'] -ne '0')
$form.Controls.Add($chkU)

# Quick Shortcuts Banner
$lblHotkeys = Add-Label 'Shortcuts: Ctrl+Alt+G (Video)  |  Ctrl+Alt+A (320k MP3 Audio)' 20 262 480
$lblHotkeys.ForeColor = [System.Drawing.Color]::FromArgb(30, 90, 180)
$lblSites = Add-Label 'Supports 1,000+ sites: YouTube, Instagram, TikTok, Reddit, Twitter/X, Pinterest...' 20 282 480
$lblSites.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)

# Update source
[void](Add-Label 'Update source URL' 20 310)
$txtUrl = New-Object System.Windows.Forms.TextBox
$txtUrl.Location = New-Object System.Drawing.Point(20, 330); $txtUrl.Size = New-Object System.Drawing.Size(480, 24)
$txtUrl.Text = $cfg['UpdateUrl']
$form.Controls.Add($txtUrl)

# Bottom Bar
[void](Add-Label ('Version ' + $AppVersion) 20 405 120)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = 'Check for updates'; $btnCheck.Location = New-Object System.Drawing.Point(20, 368); $btnCheck.Size = New-Object System.Drawing.Size(140, 28)
$form.Controls.Add($btnCheck)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save'; $btnSave.Location = New-Object System.Drawing.Point(330, 368); $btnSave.Size = New-Object System.Drawing.Size(80, 28)
$form.Controls.Add($btnSave)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'; $btnCancel.Location = New-Object System.Drawing.Point(420, 368); $btnCancel.Size = New-Object System.Drawing.Size(80, 28)
$btnCancel.Add_Click({ $form.Close() })
$form.Controls.Add($btnCancel)

function Save-Fields {
    $c = Read-Config
    $dir = $txtDir.Text.Trim()
    if ($dir) { $c['DownloadDir'] = $dir; try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch {} }
    $c['MaxHeight']        = if ($cmbQ.SelectedIndex -ge 0) { [string]$qItems[$cmbQ.SelectedIndex].Value } else { '0' }
    $c['CookiesBrowser']   = if ($cmbC.SelectedIndex -ge 0) { [string]$cItems[$cmbC.SelectedIndex] } else { '' }
    $c['DownloadSubs']     = $(if ($chkSubs.Checked) { '1' } else { '0' })
    $c['StartWithWindows'] = $(if ($chkTray.Checked) { '1' } else { '0' })
    $c['AutoUpdate']       = $(if ($chkU.Checked) { '1' } else { '0' })
    $upd = $txtUrl.Text.Trim()
    if ($upd) { $c['UpdateUrl'] = $upd }
    Write-Config $c

    # Windows Startup integration for System Tray
    $regRun = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($chkTray.Checked) {
        $trayTarget = '"{0}" "{1}" tray.ps1' -f (Join-Path $env:WINDIR 'System32\wscript.exe'), (Join-Path $AppDir 'run.vbs')
        try { Set-ItemProperty -Path $regRun -Name 'ClipToastTray' -Value $trayTarget -ErrorAction SilentlyContinue } catch {}
        # Launch tray icon immediately
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" tray.ps1' -f (Join-Path $AppDir 'run.vbs')) -ErrorAction SilentlyContinue
    } else {
        try { Remove-ItemProperty -Path $regRun -Name 'ClipToastTray' -ErrorAction SilentlyContinue } catch {}
        try {
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*tray.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
}

$btnSave.Add_Click({ Save-Fields; $form.Close() })

$btnCheck.Add_Click({
    Save-Fields
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $r = Invoke-AppUpdate -Force
    $form.Cursor = [System.Windows.Forms.Cursors]::Default
    switch ($r.Status) {
        'updated'  { [void][System.Windows.Forms.MessageBox]::Show("Updated to version $($r.Version).`n`n$($r.Notes)`n`nReopen Settings to see the new version.", 'ClipToast'); $form.Close() }
        'current'  { [void][System.Windows.Forms.MessageBox]::Show("You already have the latest version ($AppVersion).", 'ClipToast') }
        'disabled' { [void][System.Windows.Forms.MessageBox]::Show($r.Message, 'ClipToast') }
        default    { [void][System.Windows.Forms.MessageBox]::Show("Could not check for updates.`n`n$($r.Message)", 'ClipToast') }
    }
})

[void]$form.ShowDialog()
