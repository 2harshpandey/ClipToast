# common.ps1 - shared helpers, dot-sourced by the other scripts
$AppDir     = $PSScriptRoot
$Root       = Split-Path -Parent $AppDir
$InstallDir = $Root
$Bin        = Join-Path $Root 'bin'
if (-not (Test-Path -LiteralPath $Bin) -and (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'ClipToast\bin'))) {
    $Bin    = Join-Path $env:LOCALAPPDATA 'ClipToast\bin'
}
$ConfigPath = Join-Path $Root 'config.txt'
$LogPath    = Join-Path $Root 'log.txt'

function Get-ClipToastLauncher {
    $candidates = @(
        (Join-Path $InstallDir 'ClipToast.exe'),
        (Join-Path $Root 'ClipToast.exe'),
        (Join-Path $Root 'src\launcher\ClipToast.exe'),
        (Join-Path $AppDir 'ClipToast.exe'),
        (Join-Path $env:LOCALAPPDATA 'ClipToast\ClipToast.exe')
    )
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) {
            return $c
        }
    }
    return $null
}
$ToastAppId = 'ClipToast'
$AppVersion = '1.1.0'
try { $AppVersion = (Get-Content -LiteralPath (Join-Path $AppDir 'version.txt') -Raw).Trim() } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'

# Safe unicode characters constructed at runtime to guarantee zero ANSI/mojibake issues (scoped for dot-sourcing)
$script:EmojiMusic  = [char]::ConvertFromUtf32(0x1F3B5)               # 🎵
$script:EmojiVideo  = [char]::ConvertFromUtf32(0x1F4E5)               # 📥
$script:EmojiFolder = [char]::ConvertFromUtf32(0x1F4C1)               # 📁
$script:EmojiGear   = [char]::ConvertFromUtf32(0x2699) + [char]0xFE0F # ⚙️
$script:EmojiExit   = [char]::ConvertFromUtf32(0x274C)               # ❌

try { if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 1MB)) { Remove-Item -LiteralPath $LogPath -Force } } catch {}

function Write-Log([string]$s) {
    try { Add-Content -LiteralPath $LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 's'), $s) -Encoding UTF8 } catch {}
}

function Get-UnixNow { return [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# ---------------- config (simple key=value file) ----------------
function Read-Config {
    $cfg = @{
        DownloadDir      = (Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'ClipToast')
        MaxHeight        = '0'
        CookiesBrowser   = ''
        AutoUpdate       = '1'
        UpdateUrl        = 'https://github.com/2harshpandey/ClipToast/releases/latest/download/latest.json'
        LastUpdateCheck  = '0'
        LastYtdlpUpdate  = '0'
        DownloadSubs     = '0'
        StartWithWindows = '1'
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

        # Register cliptoast:// protocol for toast actions (Cancel, Open, Play)
        try {
            $protoKey = 'HKCU:\Software\Classes\cliptoast'
            if (-not (Test-Path -LiteralPath $protoKey)) { New-Item -Path $protoKey -Force | Out-Null }
            Set-ItemProperty -Path $protoKey -Name '(Default)' -Value 'URL:ClipToast Protocol' -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $protoKey -Name 'URL Protocol' -Value '' -ErrorAction SilentlyContinue
            $cmdKey = Join-Path $protoKey 'shell\open\command'
            if (-not (Test-Path -LiteralPath $cmdKey)) { New-Item -Path $cmdKey -Force | Out-Null }
            $launcher = Get-ClipToastLauncher
            if ($launcher) {
                $cmdVal = '"{0}" --action "%1"' -f $launcher
            } else {
                $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $cmdVal = '"{0}" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f $ps, (Join-Path $AppDir 'action.ps1')
            }
            Set-ItemProperty -Path $cmdKey -Name '(Default)' -Value $cmdVal -ErrorAction SilentlyContinue
        } catch { Write-Log "Protocol registration notice: $_" }

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

function Show-Toast([string]$Title, [string]$Body, [string]$Tag = 'ct', [string]$FolderPath = '', [string]$FilePath = '', [string]$ReportTag = '') {
    if (-not $script:ToastOK) { return }
    if ([string]::IsNullOrWhiteSpace($Tag)) { $Tag = 'ct' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    try {
        $t = [Security.SecurityElement]::Escape($Title)
        $b = [Security.SecurityElement]::Escape($Body)
        $actionList = New-Object System.Collections.Generic.List[string]
        if ($ReportTag) {
            $actionList.Add("<action content='Report issue' arguments='cliptoast:report:$ReportTag' activationType='protocol'/>")
            if (Test-Path -LiteralPath $LogPath) {
                $fB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Item -LiteralPath $LogPath).FullName)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
                $actionList.Add("<action content='View log' arguments='cliptoast:open:$fB64' activationType='protocol'/>")
            }
        } elseif ($FilePath -and (Test-Path -LiteralPath $FilePath)) {
            $fPath = (Get-Item -LiteralPath $FilePath).FullName
            $fB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($fPath)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
            $actionList.Add("<action content='Play' arguments='cliptoast:play:$fB64' activationType='protocol'/>")
            $actionList.Add("<action content='Open folder' arguments='cliptoast:open:$fB64' activationType='protocol'/>")
        } elseif ($FolderPath) {
            $dPath = $FolderPath
            if (Test-Path -LiteralPath $FolderPath) {
                $dPath = (Get-Item -LiteralPath $FolderPath).FullName
            }
            $fB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($dPath)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
            $actionList.Add("<action content='Open folder' arguments='cliptoast:open:$fB64' activationType='protocol'/>")
        }
        $actions = ''
        if ($actionList.Count -gt 0) {
            $actions = '<actions>' + ($actionList -join '') + '</actions>'
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

function New-NotificationData([string]$Headline, [string]$Title, [string]$Value, [string]$ValueText, [string]$Status, [uint32]$Seq = 1) {
    $dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $dict['headline']   = [string]$Headline
    $dict['pTitle']     = [string]$Title
    $dict['pValue']     = [string]$Value
    $dict['pValueText'] = [string]$ValueText
    $dict['pStatus']    = [string]$Status
    return New-Object Windows.UI.Notifications.NotificationData ($dict, [uint32]$Seq)
}

# Progress toast: title line, progress bar, speed/ETA under the bar, with Cancel and Open folder buttons
function Show-ProgressToast([string]$Tag, [string]$Headline, [string]$Title, [string]$Value, [string]$ValueText, [string]$Status) {
    if (-not $script:ToastOK) { return }
    if ([string]::IsNullOrWhiteSpace($Tag)) { $Tag = 'ct' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    try {
        $img = ''
        if ($script:LogoUri) {
            $img = "<image placement='appLogoOverride' hint-crop='circle' src='$($script:LogoUri)' />"
        }
        $cancelUri = "cliptoast:cancel:$Tag"
        $c = Read-Config
        $dPath = [string]$c['DownloadDir']
        if (-not $dPath) { $dPath = Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'ClipToast' }
        if (-not (Test-Path -LiteralPath $dPath)) { try { New-Item -ItemType Directory -Force -Path $dPath | Out-Null } catch {} }
        $fB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($dPath)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
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
    <action content="Cancel" arguments="$cancelUri" activationType="protocol" />
    <action content="Open folder" arguments="cliptoast:open:$fB64" activationType="protocol" />
  </actions>
</toast>
"@
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        $toast.Tag = $Tag
        $toast.Group = 'ClipToast'
        $script:ToastSeq = 1
        $toast.Data = New-NotificationData $Headline $Title $Value $ValueText $Status 1
        $script:Notifier.Show($toast)
    } catch { Write-Log "Show-ProgressToast failed: $_" }
}

function Update-ProgressToast([string]$Tag, [string]$Headline, [string]$Title, [string]$Value, [string]$ValueText, [string]$Status) {
    if (-not $script:ToastOK -or [string]::IsNullOrWhiteSpace($Tag)) { return }
    try {
        $script:ToastSeq++
        $d = New-NotificationData $Headline $Title $Value $ValueText $Status $script:ToastSeq
        [void]$script:Notifier.Update($d, $Tag, 'ClipToast')
    } catch { Write-Log "Update-ProgressToast failed: $_" }
}

# ---------------- signed self-update ----------------
# Manifest (JSON at UpdateUrl): { "version": "1.1.0", "url": "https://.../ClipToast-app-1.1.0.zip", "signature": "<base64 RSA-SHA256 of the zip>", "notes": "..." }
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
        $txt = $null
        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($curl) {
            $raw = & $curl.Source -s -L --max-time 15 -H "Cache-Control: no-cache" $url
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $txt = ($raw -join "`n")
            }
        }
        if (-not $txt) {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -Headers @{ 'Cache-Control' = 'no-cache' }
            $txt = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
        }
        $m = $txt.TrimStart([char]0xFEFF) | ConvertFrom-Json
        $cfg = Read-Config
        $cfg['LastUpdateCheck'] = [string](Get-UnixNow)
        Write-Config $cfg

        if (-not $m.version -or -not $m.url -or -not $m.signature) { throw 'The update manifest is incomplete.' }
        if ([version][string]$m.version -le [version]$AppVersion) { return @{ Status = 'current'; Version = $AppVersion } }
        if ([string]$m.url -notlike 'https://*') { throw 'The update package URL must start with https://' }

        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $zip = Join-Path $tmp 'update.zip'
        $downloaded = $false
        if ($curl) {
            & $curl.Source -s -L --max-time 180 -o $zip ([string]$m.url)
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $zip)) {
                $downloaded = $true
            }
        }
        if (-not $downloaded) {
            Invoke-WebRequest -Uri ([string]$m.url) -OutFile $zip -UseBasicParsing -TimeoutSec 180
        }

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

function Start-ClipToastScript([string]$Script, [string[]]$ScriptArgs = @()) {
    $launcher = Get-ClipToastLauncher
    if ($launcher) {
        $a = @()
        if ($Script -eq 'tray.ps1') { $a += '--tray' }
        elseif ($Script -eq 'settings.ps1') { $a += '--settings' }
        elseif ($Script -eq 'action.ps1') { $a += '--action' }
        elseif ($Script -eq 'downloader.ps1') {
            if ($ScriptArgs -contains '-AudioOnly') { $a += '--audio' }
            else { $a += '--video' }
            foreach ($arg in $ScriptArgs) { if ($arg -ne '-AudioOnly') { $a += $arg } }
        }
        else {
            $a += $Script
            if ($ScriptArgs) { $a += $ScriptArgs }
        }
        Start-Process -FilePath $launcher -ArgumentList $a -ErrorAction SilentlyContinue
        return
    }
    $psArgs = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f (Join-Path $AppDir $Script)))
    if ($ScriptArgs) { $psArgs += $ScriptArgs }
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $psArgs -ErrorAction SilentlyContinue
}

