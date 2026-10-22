# settings.ps1 - small settings window
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$cfg = Read-Config

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ClipToast - Settings'
$form.ClientSize = New-Object System.Drawing.Size(520, 400)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

function Add-Label([string]$text, [int]$x, [int]$y, [int]$w = 480) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, 20)
    $form.Controls.Add($l); return $l
}

# Download folder
[void](Add-Label 'Download folder' 20 15)
$txtDir = New-Object System.Windows.Forms.TextBox
$txtDir.Location = New-Object System.Drawing.Point(20, 38); $txtDir.Size = New-Object System.Drawing.Size(390, 24)
$txtDir.Text = $cfg['DownloadDir']
$form.Controls.Add($txtDir)
$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Browse...'; $btnBrowse.Location = New-Object System.Drawing.Point(420, 36); $btnBrowse.Size = New-Object System.Drawing.Size(80, 27)
$btnBrowse.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.SelectedPath = $txtDir.Text
    $d.ShowNewFolderButton = $true
    if ($d.ShowDialog() -eq 'OK') { $txtDir.Text = $d.SelectedPath }
})
$form.Controls.Add($btnBrowse)

# Max quality
[void](Add-Label 'Maximum video quality (higher = bigger files and slower conversion for 4K)' 20 78)
$cmbQ = New-Object System.Windows.Forms.ComboBox
$cmbQ.DropDownStyle = 'DropDownList'
$cmbQ.Location = New-Object System.Drawing.Point(20, 101); $cmbQ.Size = New-Object System.Drawing.Size(260, 24)
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
[void](Add-Label 'Use my browser login (only needed when Instagram/YouTube asks you to sign in)' 20 140)
$cmbC = New-Object System.Windows.Forms.ComboBox
$cmbC.DropDownStyle = 'DropDownList'
$cmbC.Location = New-Object System.Drawing.Point(20, 163); $cmbC.Size = New-Object System.Drawing.Size(260, 24)
$cItems = @('', 'firefox', 'edge', 'chrome', 'brave')
foreach ($c in $cItems) { if ($c -eq '') { [void]$cmbC.Items.Add('None') } else { [void]$cmbC.Items.Add($c.Substring(0, 1).ToUpper() + $c.Substring(1)) } }
$sel = 0
for ($i = 0; $i -lt $cItems.Count; $i++) { if ($cItems[$i] -eq [string]$cfg['CookiesBrowser']) { $sel = $i } }
$cmbC.SelectedIndex = $sel
$form.Controls.Add($cmbC)
[void](Add-Label 'Tip: Firefox works most reliably. Chrome/Edge may fail on newer versions.' 20 190)

# Auto-update
$chkU = New-Object System.Windows.Forms.CheckBox
$chkU.Text = 'Install app updates automatically'
$chkU.Location = New-Object System.Drawing.Point(20, 225); $chkU.Size = New-Object System.Drawing.Size(300, 24)
$chkU.Checked = ([string]$cfg['AutoUpdate'] -ne '0')
$form.Controls.Add($chkU)

# Update source
[void](Add-Label 'Update source (set by whoever shared this app - leave as is)' 20 260)
$txtUrl = New-Object System.Windows.Forms.TextBox
$txtUrl.Location = New-Object System.Drawing.Point(20, 283); $txtUrl.Size = New-Object System.Drawing.Size(480, 24)
$txtUrl.Text = $cfg['UpdateUrl']
$form.Controls.Add($txtUrl)

# Buttons
$lblVer = Add-Label ('Version ' + $AppVersion) 20 368 150
$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = 'Check for updates'; $btnCheck.Location = New-Object System.Drawing.Point(20, 325); $btnCheck.Size = New-Object System.Drawing.Size(150, 30)
$form.Controls.Add($btnCheck)
$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save'; $btnSave.Location = New-Object System.Drawing.Point(330, 325); $btnSave.Size = New-Object System.Drawing.Size(80, 30)
$form.Controls.Add($btnSave)
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'; $btnCancel.Location = New-Object System.Drawing.Point(420, 325); $btnCancel.Size = New-Object System.Drawing.Size(80, 30)
$btnCancel.Add_Click({ $form.Close() })
$form.Controls.Add($btnCancel)

function Save-Fields {
    $c = Read-Config
    $dir = $txtDir.Text.Trim()
    if ($dir) { $c['DownloadDir'] = $dir; try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch {} }
    $c['MaxHeight']      = [string]$qItems[$cmbQ.SelectedIndex].Value
    $c['CookiesBrowser'] = [string]$cItems[$cmbC.SelectedIndex]
    $c['AutoUpdate']     = $(if ($chkU.Checked) { '1' } else { '0' })
    $c['UpdateUrl']      = $txtUrl.Text.Trim()
    Write-Config $c
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
