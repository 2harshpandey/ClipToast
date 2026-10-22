# common.ps1 - shared helpers, dot-sourced by the other scripts
$AppDir     = $PSScriptRoot
$Root       = Split-Path -Parent $AppDir
$Bin        = Join-Path $Root 'bin'
$ConfigPath = Join-Path $Root 'config.txt'
$LogPath    = Join-Path $Root 'log.txt'
$ToastAppId = 'ClipToast'
$AppVersion = '0.0.0'
try { $AppVersion = (Get-Content -LiteralPath (Join-Path $AppDir 'version.txt') -Raw).Trim() } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'

try { if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 1MB)) { Remove-Item -LiteralPath $LogPath -Force } } catch {}

function Write-Log([string]$s) {
    try { Add-Content -LiteralPath $LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 's'), $s) -Encoding UTF8 } catch {}
}

function Get-UnixNow { return [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# ---------------- config (simple key=value file) ----------------
function Read-Config {
    $cfg = @{
        DownloadDir     = (Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'ClipToast')
        MaxHeight       = '0'
        CookiesBrowser  = ''
        AutoUpdate      = '1'
        UpdateUrl       = 'https://github.com/2harshpandey/ClipToast/releases/latest/download/latest.json'
        LastUpdateCheck = '0'
        LastYtdlpUpdate = '0'
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        foreach ($line in (Get-Content -LiteralPath $ConfigPath -Encoding UTF8)) {
            $i = $line.IndexOf('=')
            if ($i -gt 0 -and -not $line.StartsWith('#')) {
                $cfg[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
            }
        }
    }
    return $cfg
}

function Write-Config($cfg) {
    $lines = @()
    foreach ($k in ($cfg.Keys | Sort-Object)) { $lines += ('{0}={1}' -f $k, $cfg[$k]) }
    Set-Content -LiteralPath $ConfigPath -Value $lines -Encoding UTF8
}

function Test-Tools {
    foreach ($n in 'yt-dlp.exe', 'ffmpeg.exe', 'ffprobe.exe', 'deno.exe') {
        if (-not (Test-Path -LiteralPath (Join-Path $Bin $n))) { return $false }
    }
    return $true
}

# ---------------- formatting ----------------
function ConvertTo-Num([string]$s) {
    $d = 0.0
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return 0.0
}
function Format-Size([double]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    return ('{0:N0} KB' -f ($b / 1KB))
}
function Format-Eta([double]$sec) {
    $ts = [TimeSpan]::FromSeconds([Math]::Max(0, $sec))
    if ($ts.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds) }
    return ('{0}:{1:00}' -f [int][Math]::Floor($ts.TotalMinutes), $ts.Seconds)
}
function Limit-Text([string]$s, [int]$n) {
    if ($null -eq $s) { return '' }
    if ($s.Length -gt $n) { return $s.Substring(0, $n - 3) + '...' }
    return $s
}
function Format-Fraction([double]$f) {
    return ([Math]::Max(0.0, [Math]::Min(1.0, $f))).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
}

# ---------------- toast notifications ----------------
$script:ToastOK  = $false
$script:Notifier = $null
$script:ToastSeq = 1
$script:LogoPath = ''
$script:LogoUri  = ''

function Initialize-Toast {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.UI.Notifications.NotificationData, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

        # Locate ClipToast PNG logo
        foreach ($candidate in @(
            (Join-Path $Root 'cliptoast.png'),
            (Join-Path $AppDir 'cliptoast.png'),
            (Join-Path $env:LOCALAPPDATA 'ClipToast\cliptoast.png'),
            (Join-Path $Root 'cliptoast.ico')
        )) {
            if (Test-Path -LiteralPath $candidate) {
                $script:LogoPath = (Get-Item -LiteralPath $candidate).FullName
                $script:LogoUri  = [Security.SecurityElement]::Escape(([Uri]$script:LogoPath).AbsoluteUri)
                break
            }
        }

        # Ensure AppUserModelId is registered in HKCU so Windows displays "ClipToast" as app title
        try {
            $regKey = 'HKCU:\Software\Classes\AppUserModelId\ClipToast'
            if (-not (Test-Path -LiteralPath $regKey)) { New-Item -Path $regKey -Force | Out-Null }
            Set-ItemProperty -Path $regKey -Name 'DisplayName' -Value 'ClipToast' -ErrorAction SilentlyContinue
            if ($script:LogoPath) {
                Set-ItemProperty -Path $regKey -Name 'IconUri' -Value $script:LogoPath -ErrorAction SilentlyContinue
            }
            Set-ItemProperty -Path $regKey -Name 'ShowInSettings' -Value 1 -Type DWord -ErrorAction SilentlyContinue
        } catch { Write-Log "AppUserModelId registration notice: $_" }

        try {
            $script:Notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAppId)
            $script:ToastOK = $true
        } catch {
            # Graceful fallback to PowerShell AUMID if custom registration fails
            $script:Notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe')
            $script:ToastOK = $true
        }
    } catch { $script:ToastOK = $false; Write-Log "Toast init failed: $_" }
}

function Show-Toast([string]$Title, [string]$Body, [string]$Tag = 'ct', [string]$FolderPath = '') {
    if (-not $script:ToastOK) { return }
    try {
        $t = [Security.SecurityElement]::Escape($Title)
        $b = [Security.SecurityElement]::Escape($Body)
        $actions = ''
        if ($FolderPath) {
            $uri = [Security.SecurityElement]::Escape(([Uri]$FolderPath).AbsoluteUri)
            $actions = "<actions><action content='Open folder' arguments='$uri' activationType='protocol'/></actions>"
        }
        $img = ''
        if ($script:LogoUri) {
            $img = "<image placement='appLogoOverride' hint-crop='circle' src='$($script:LogoUri)' />"
        }
        $xml = "<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text>$img</binding></visual>$actions</toast>"
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        $toast.Tag = $Tag
        $toast.Group = 'ClipToast'
        $script:Notifier.Show($toast)
    } catch { Write-Log "Show-Toast failed: $_" }
}

# Progress toast: title line, progress bar, "42.1 MB / 118 MB (36%)" on the right, "5.2 MB/s - ETA 0:14" under the bar.
function Show-ProgressToast([string]$Tag, [string]$Headline, [string]$Title, [string]$Value, [string]$ValueText, [string]$Status) {
    if (-not $script:ToastOK) { return }
    try {
        $img = ''
        if ($script:LogoUri) {
            $img = "<image placement='appLogoOverride' hint-crop='circle' src='$($script:LogoUri)' />"
        }
        $xml = @"
<toast scenario="reminder">
  <visual>
    <binding template="ToastGeneric">
      <text>ClipToast</text>
      <text>{headline}</text>
      <progress title="{pTitle}" value="{pValue}" valueStringOverride="{pValueText}" status="{pStatus}" />
      $img
    </binding>
  </visual>
  <actions>
    <action content="Hide" arguments="dismiss" activationType="system" />
  </actions>
</toast>
"@
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        $toast.Tag = $Tag
        $toast.Group = 'ClipToast'
        $d = New-Object Windows.UI.Notifications.NotificationData
        $script:ToastSeq = 1
        $d.SequenceNumber = [uint32]1
        $d.Values['headline']   = $Headline
        $d.Values['pTitle']     = $Title
        $d.Values['pValue']     = $Value
        $d.Values['pValueText'] = $ValueText
        $d.Values['pStatus']    = $Status
        $toast.Data = $d
        $script:Notifier.Show($toast)
    } catch { Write-Log "Show-ProgressToast failed: $_" }
}

function Update-ProgressToast([string]$Tag, [string]$Headline, [string]$Title, [string]$Value, [string]$ValueText, [string]$Status) {
    if (-not $script:ToastOK) { return }
    try {
        $d = New-Object Windows.UI.Notifications.NotificationData
        $script:ToastSeq++
        $d.SequenceNumber = [uint32]$script:ToastSeq
        $d.Values['headline']   = $Headline
        $d.Values['pTitle']     = $Title
        $d.Values['pValue']     = $Value
        $d.Values['pValueText'] = $ValueText
        $d.Values['pStatus']    = $Status
        [void]$script:Notifier.Update($d, $Tag, 'ClipToast')
    } catch { Write-Log "Update-ProgressToast failed: $_" }
}

# ---------------- signed self-update ----------------
# Manifest (JSON at UpdateUrl): { "version": "1.0.1", "url": "https://.../ClipToast-app-1.0.1.zip", "signature": "<base64 RSA-SHA256 of the zip>", "notes": "..." }
# The zip is only installed if its signature verifies against app\update-public-key.xml, so nobody
# without your private key can push code to users - even if your hosting account is compromised.
function Invoke-AppUpdate {
    param([switch]$Force)
    $cfg = Read-Config
    $url = [string]$cfg['UpdateUrl']
    if ([string]::IsNullOrWhiteSpace($url) -or $url -like '*YOUR-GITHUB-USERNAME*') {
        return @{ Status = 'disabled'; Message = 'No update source is configured in this copy.' }
    }
    if (-not $Force) {
        $last = [int64]0
        [void][int64]::TryParse([string]$cfg['LastUpdateCheck'], [ref]$last)
        if (((Get-UnixNow) - $last) -lt 21600) { return @{ Status = 'skipped' } }
    }
    $tmp = Join-Path $env:TEMP ('cliptoast_upd_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        if ($url -notlike 'https://*') { throw 'The update URL must start with https://' }
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 -Headers @{ 'Cache-Control' = 'no-cache' }
        $txt = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
        $m = $txt.TrimStart([char]0xFEFF) | ConvertFrom-Json
        $cfg = Read-Config
        $cfg['LastUpdateCheck'] = [string](Get-UnixNow)
        Write-Config $cfg

        if (-not $m.version -or -not $m.url -or -not $m.signature) { throw 'The update manifest is incomplete.' }
        if ([version][string]$m.version -le [version]$AppVersion) { return @{ Status = 'current'; Version = $AppVersion } }
        if ([string]$m.url -notlike 'https://*') { throw 'The update package URL must start with https://' }

        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $zip = Join-Path $tmp 'update.zip'
        Invoke-WebRequest -Uri ([string]$m.url) -OutFile $zip -UseBasicParsing -TimeoutSec 180

        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.FromXmlString((Get-Content -LiteralPath (Join-Path $AppDir 'update-public-key.xml') -Raw))
        $bytes = [IO.File]::ReadAllBytes($zip)
        $sig = [Convert]::FromBase64String([string]$m.signature)
        if (-not $rsa.VerifyData($bytes, 'SHA256', $sig)) { throw 'Signature check FAILED - update rejected.' }

        $new = Join-Path $tmp 'new'
        Expand-Archive -LiteralPath $zip -DestinationPath $new -Force
        $newVer = (Get-Content -LiteralPath (Join-Path $new 'version.txt') -Raw).Trim()
        if ($newVer -ne [string]$m.version) { throw 'Version inside the package does not match the manifest.' }
        if (-not (Test-Path -LiteralPath (Join-Path $new 'downloader.ps1'))) { throw 'Update package is incomplete.' }

        $bak = Join-Path $Root 'app.bak'
        if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Recurse -Force }
        Copy-Item -LiteralPath $AppDir -Destination $bak -Recurse
        try {
            Copy-Item -Path (Join-Path $new '*') -Destination $AppDir -Recurse -Force
        } catch {
            Copy-Item -Path (Join-Path $bak '*') -Destination $AppDir -Recurse -Force
            throw
        }
        $post = Join-Path $AppDir 'post-update.ps1'
        if (Test-Path -LiteralPath $post) {
            try { & $post } catch { Write-Log "post-update failed: $_" }
            Remove-Item -LiteralPath $post -Force -ErrorAction SilentlyContinue
        }
        try { Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipToast' -Name DisplayVersion -Value $newVer -ErrorAction Stop } catch {}
        Write-Log "Updated $AppVersion -> $newVer"
        return @{ Status = 'updated'; Version = $newVer; Notes = [string]$m.notes }
    } catch {
        Write-Log "Update check failed: $_"
        return @{ Status = 'error'; Message = [string]$_ }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
