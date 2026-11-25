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
$AppVersion = '1.1.4'
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

function Remove-WorkDirectoryRobust([string]$WorkDir, [int]$ParentPid = 0) {
    if ([string]::IsNullOrWhiteSpace($WorkDir)) { return $false }
    try {
        $WorkDir = [System.IO.Path]::GetFullPath($WorkDir).TrimEnd('\', '/')
        $tempBase = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar

        # Security check: workDir must strictly reside inside TEMP and start with cliptoast_
        if (-not $WorkDir.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -or
            ([System.IO.Path]::GetFileName($WorkDir) -notlike 'cliptoast_*')) {
            Write-Log "Remove-WorkDirectoryRobust rejected unsafe path: $WorkDir"
            return $false
        }

        if (-not (Test-Path -LiteralPath $WorkDir)) { return $true }

        # 1. If a ParentPid is provided, terminate the process tree
        if ($ParentPid -gt 0) {
            try {
                & taskkill.exe /F /T /PID $ParentPid 2>$null | Out-Null
            } catch {}
        }

        # 2. Terminate any residual helper processes (yt-dlp, ffmpeg, ffprobe) associated with this work directory
        try {
            $binDir = [System.IO.Path]::GetFullPath($Bin)
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                ($ParentPid -gt 0 -and $_.ParentProcessId -eq $ParentPid) -or
                ($_.Name -in @('yt-dlp.exe', 'ffmpeg.exe', 'ffprobe.exe') -and (
                    ($_.CommandLine -and $_.CommandLine -like "*$WorkDir*") -or
                    ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($binDir, [System.StringComparison]::OrdinalIgnoreCase) -and ($_.CommandLine -like "*$WorkDir*"))
                ))
            } | ForEach-Object {
                try { & taskkill.exe /F /PID $_.ProcessId 2>$null | Out-Null } catch {}
            }
        } catch {}

        # 3. Retry loop with progressive backoff to allow OS to release file locks (e.g. in1.mp4, streams)
        $deleted = $false
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            try {
                if (-not (Test-Path -LiteralPath $WorkDir)) {
                    $deleted = $true
                    break
                }
                # Remove ReadOnly attributes on any files inside
                Get-ChildItem -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        if ($_.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                            $_.Attributes = [System.IO.FileAttributes]::Normal
                        }
                    } catch {}
                }
                Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction Stop
                $deleted = $true
                break
            } catch {
                Start-Sleep -Milliseconds (100 * $attempt)
            }
        }

        if ($deleted) {
            Write-Log "Successfully wiped work directory: $WorkDir"
        } else {
            Write-Log "Warning: Could not completely remove work directory $WorkDir after 10 attempts."
        }
        return $deleted
    } catch {
        Write-Log "Remove-WorkDirectoryRobust error: $_"
        return $false
    }
}

function Clear-ClipToastOrphans {
    try {
        $tempDir = [System.IO.Path]::GetFullPath($env:TEMP)
        $now = [DateTime]::UtcNow

        # 1. Inspect all task files and collect active work directories
        $activeWorkDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $taskFiles = Get-ChildItem -Path $tempDir -Filter 'cliptoast_task_*.json' -File -ErrorAction SilentlyContinue
        foreach ($tf in $taskFiles) {
            $isAlive = $false
            $taskWork = $null
            try {
                $task = Get-Content -LiteralPath $tf.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                if ($task.work) { $taskWork = [string]$task.work }
                if ($task.pid -and [int]$task.pid -gt 0) {
                    $p = Get-Process -Id $task.pid -ErrorAction SilentlyContinue
                    if ($p -and $p.ProcessName -like '*powershell*') {
                        $isAlive = $true
                        if ($taskWork) { [void]$activeWorkDirs.Add([System.IO.Path]::GetFullPath($taskWork).TrimEnd('\', '/')) }
                    }
                }
            } catch {}

            # If task process is dead, clean up both the dead task file and its work directory
            if (-not $isAlive) {
                if ($taskWork -and (Test-Path -LiteralPath $taskWork)) {
                    [void](Remove-WorkDirectoryRobust $taskWork 0)
                }
                Remove-Item -LiteralPath $tf.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        # 2. Inspect all cliptoast_* work directories in TEMP
        $workDirs = Get-ChildItem -Path $tempDir -Filter 'cliptoast_*' -Directory -ErrorAction SilentlyContinue
        foreach ($wd in $workDirs) {
            $fullWd = [System.IO.Path]::GetFullPath($wd.FullName).TrimEnd('\', '/')
            if ($activeWorkDirs.Contains($fullWd)) { continue }

            # If it's not currently tracked by an active living process, and has been idle for >= 2 minutes
            $ageMinutes = [Math]::Min(($now - $wd.CreationTimeUtc).TotalMinutes, ($now - $wd.LastWriteTimeUtc).TotalMinutes)
            if ($ageMinutes -ge 2) {
                Write-Log "Cleaning up orphaned work directory ($([int]$ageMinutes) min old): $fullWd"
                [void](Remove-WorkDirectoryRobust $fullWd 0)
            }
        }

        # 3. Clean up any stale error or update temporary directories older than 1 hour
        Get-ChildItem -Path $tempDir -Filter 'cliptoast_upd_*' -Directory -ErrorAction SilentlyContinue | Where-Object {
            ($now - $_.LastWriteTimeUtc).TotalMinutes -ge 60
        } | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Get-ChildItem -Path $tempDir -Filter 'cliptoast_err_*.json' -File -ErrorAction SilentlyContinue | Where-Object {
            ($now - $_.LastWriteTimeUtc).TotalDays -ge 1
        } | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "Clear-ClipToastOrphans error: $_"
    }
}


# ---------------- config (simple key=value file) ----------------
function Read-Config {
    $cfg = @{
        DownloadDir      = (Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'ClipToast Downloads')
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
        $lines = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $lines = Get-Content -LiteralPath $ConfigPath -Encoding UTF8 -ErrorAction Stop
                break
            } catch {
                Start-Sleep -Milliseconds (30 * $attempt)
            }
        }
        if ($lines) {
            foreach ($line in $lines) {
                $i = $line.IndexOf('=')
                if ($i -gt 0 -and -not $line.StartsWith('#')) {
                    $cfg[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
                }
            }
        }
    }
    return $cfg
}

function Write-Config($cfg) {
    $lines = @()
    foreach ($k in ($cfg.Keys | Sort-Object)) { $lines += ('{0}={1}' -f $k, $cfg[$k]) }
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Set-Content -LiteralPath $ConfigPath -Value $lines -Encoding UTF8 -ErrorAction Stop
            break
        } catch {
            Start-Sleep -Milliseconds (40 * $attempt)
        }
    }
}

function Test-Tools {
    foreach ($n in 'yt-dlp.exe', 'ffmpeg.exe', 'ffprobe.exe', 'deno.exe') {
        $p = Join-Path $Bin $n
        if (-not (Test-Path -LiteralPath $p)) { return $false }
        try {
            if ((Get-Item -LiteralPath $p).Length -lt 10000) { return $false }
        } catch { return $false }
    }
    return $true
}

# ---------------- cookies management ----------------
function Remove-FileBomIfPresent([string]$FilePath) {
    if (-not $FilePath -or -not (Test-Path -LiteralPath $FilePath)) { return $true }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $cleanBytes = New-Object byte[] ($bytes.Length - 3)
            [System.Array]::Copy($bytes, 3, $cleanBytes, 0, $cleanBytes.Length)
            [System.IO.File]::WriteAllBytes($FilePath, $cleanBytes)
        }
        return $true
    } catch {
        return $false
    }
}

function Add-CookieLinesToMap($CookieMap, [string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    $added = 0
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $t = $line.TrimStart([char]0xFEFF).Trim()
        if (-not $t) { continue }
        if ($t.StartsWith('#') -and -not $t.StartsWith('#HttpOnly_', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $parts = $t -split "`t"
        if ($parts.Count -ge 7 -and -not [string]::IsNullOrWhiteSpace($parts[0]) -and -not [string]::IsNullOrWhiteSpace($parts[5])) {
            # Key uniquely identifies cookie: Domain + Path + Name
            $domKey = ($parts[0] -replace '(?i)^#HttpOnly_', '').ToLower()
            $key = "$domKey|$($parts[2])|$($parts[5])"
            $CookieMap[$key] = $t
            $added++
        }
    }
    return $added
}

function Merge-CookieFiles([string]$ExistingPath, [string]$NewPath, [string]$OutputPath) {
    $cookieMap = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    $headerLines = New-Object System.Collections.Generic.List[string]
    $headerLines.Add('# Netscape HTTP Cookie File')
    $headerLines.Add('# Merged by ClipToast')

    # Load existing cookies if present
    [void](Add-CookieLinesToMap $cookieMap $ExistingPath)

    # Merge/override with new cookies
    if ($NewPath -and (Test-Path -LiteralPath $NewPath)) {
        $newCount = Add-CookieLinesToMap $cookieMap $NewPath
        if ($newCount -eq 0) {
            throw "No valid Netscape cookies found in the selected file. Please export cookies.txt in Netscape format."
        }
    }

    $outLines = New-Object System.Collections.Generic.List[string]
    $outLines.AddRange($headerLines)
    foreach ($val in $cookieMap.Values) {
        $outLines.Add($val)
    }

    $outDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    # Python's MozillaCookieJar (used by yt-dlp) fails to recognize the header if a UTF-8 BOM is present
    [System.IO.File]::WriteAllLines($OutputPath, $outLines, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ActiveCookieDomains([string]$CookiePath) {
    $domains = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    if (-not $CookiePath -or -not (Test-Path -LiteralPath $CookiePath)) { return @() }

    $nowUnix = Get-UnixNow
    $knownAuth = [ordered]@{
        'Instagram'  = @{ Pattern = 'instagram\.com$'; Tokens = @('sessionid', 'ds_user_id') }
        'YouTube'    = @{ Pattern = '(youtube\.com|google\.com)$'; Tokens = @('SAPISID', '__Secure-1PAPISID', '__Secure-3PAPISID', 'SID', '__Secure-1PSID', '__Secure-3PSID', 'LOGIN_INFO', 'SSID', 'HSID') }
        'TikTok'     = @{ Pattern = 'tiktok\.com$'; Tokens = @('sessionid', 'sessionid_ss', 'sid_tt', 'sid_guard') }
        'Reddit'     = @{ Pattern = 'reddit\.com$'; Tokens = @('reddit_session', 'token_v2') }
        'Twitter/X'  = @{ Pattern = '(twitter\.com|x\.com)$'; Tokens = @('auth_token') }
        'Facebook'   = @{ Pattern = '(facebook\.com|fb\.com)$'; Tokens = @('c_user', 'xs') }
        'Twitch'     = @{ Pattern = 'twitch\.tv$'; Tokens = @('auth-token', 'login', 'twilight-user') }
        'SoundCloud' = @{ Pattern = 'soundcloud\.com$'; Tokens = @('oauth_token') }
        'Pinterest'  = @{ Pattern = 'pinterest\.[a-z.]+$'; Tokens = @('_auth', '_pinterest_sess') }
        'Vimeo'      = @{ Pattern = 'vimeo\.com$'; Tokens = @('vimeo', 'is_logged_in') }
        'Spotify'    = @{ Pattern = 'spotify\.com$'; Tokens = @('sp_dc', 'sp_key') }
        'Bilibili'   = @{ Pattern = 'bilibili\.com$'; Tokens = @('SESSDATA', 'DedeUserID') }
        'LinkedIn'   = @{ Pattern = 'linkedin\.com$'; Tokens = @('li_at') }
        'Threads'    = @{ Pattern = 'threads\.net$'; Tokens = @('sessionid', 'ds_user_id') }
        'Patreon'    = @{ Pattern = 'patreon\.com$'; Tokens = @('session_id') }
    }

    foreach ($line in (Get-Content -LiteralPath $CookiePath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $t = $line.TrimStart([char]0xFEFF).Trim()
        if (-not $t) { continue }
        if ($t.StartsWith('#') -and -not $t.StartsWith('#HttpOnly_', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $parts = $t -split "`t"
        if ($parts.Count -ge 7) {
            $domain = ($parts[0] -replace '(?i)^#HttpOnly_', '').TrimStart('.')
            $expiry = [int64]0
            [void][int64]::TryParse($parts[4], [ref]$expiry)
            if ($expiry -ne 0 -and $expiry -le $nowUnix) { continue }

            $cookieName = $parts[5].Trim()
            $cookieVal  = $parts[6].Trim()
            if ([string]::IsNullOrEmpty($cookieVal) -or $cookieVal -eq 'deleted') { continue }

            $matched = $false
            foreach ($site in $knownAuth.Keys) {
                $def = $knownAuth[$site]
                if ($domain -match $def.Pattern) {
                    $matched = $true
                    foreach ($tok in $def.Tokens) {
                        if ([string]::Equals($cookieName, $tok, [System.StringComparison]::OrdinalIgnoreCase)) {
                            [void]$domains.Add($site)
                            break
                        }
                    }
                    break
                }
            }

            if (-not $matched) {
                # For generic unlisted sites, ignore non-auth/anonymous/guest/consent/telemetry cookies
                $isIgnored = $cookieName -match '^(pref|socs|ysc|gps|guest|guest_id.*|visitor.*|device.*|datr|mid|ig_did|csrftoken|csrf.*|xsrf.*|cf_.*|__cf.*|_ga.*|_gid|_gat.*|lang.*|locale.*|country.*|notice.*|consent.*|optimizely.*|fr|sb|wd|dpr|rur|bcookie|bscookie|lidc|vuid|mstoken|ttwid|edge_bucket|buvid.*|_uuid|__secure-rollout_token|__secure-ynid)$'
                if (-not $isIgnored -and ($cookieName -match 'session|auth|token|jwt|login' -and $cookieVal.Length -ge 8)) {
                    $partsD = $domain.Split('.')
                    if ($partsD.Count -ge 2) {
                        $name = $partsD[$partsD.Count - 2]
                        if ($name.Length -gt 1) {
                            $name = $name.Substring(0, 1).ToUpper() + $name.Substring(1)
                            [void]$domains.Add($name)
                        }
                    }
                }
            }
        }
    }
    return @($domains | Sort-Object)
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
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $s = $s.Trim()
    if ($s.Length -le $n) { return $s }
    if ($n -le 3) { return $s.Substring(0, $n) }
    $sub = $s.Substring(0, $n - 3)
    $lastSpace = $sub.LastIndexOf(' ')
    if ($lastSpace -gt ($n / 2)) {
        return $sub.Substring(0, $lastSpace).TrimEnd(',', '.', ';', ':', '-', ' ', '!') + '...'
    }
    return $sub.TrimEnd() + '...'
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

        # Ensure AppUserModelId and cliptoast:// protocol are registered (only writes if not already present)
        $needAumid = -not (Test-Path -LiteralPath 'HKCU:\Software\Classes\AppUserModelId\ClipToast')
        $needProto = -not (Test-Path -LiteralPath 'HKCU:\Software\Classes\cliptoast\shell\open\command')

        if ($needAumid) {
            try {
                $regKey = 'HKCU:\Software\Classes\AppUserModelId\ClipToast'
                New-Item -Path $regKey -Force | Out-Null
                Set-ItemProperty -Path $regKey -Name 'DisplayName' -Value 'ClipToast' -ErrorAction SilentlyContinue
                if ($script:LogoPath) {
                    Set-ItemProperty -Path $regKey -Name 'IconUri' -Value $script:LogoPath -ErrorAction SilentlyContinue
                }
                Set-ItemProperty -Path $regKey -Name 'ShowInSettings' -Value 1 -Type DWord -ErrorAction SilentlyContinue
            } catch { Write-Log "AppUserModelId registration notice: $_" }
        }

        # Ensure notifications and banners are explicitly enabled for ClipToast in Windows Settings
        try {
            $notifKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\ClipToast'
            if (-not (Test-Path -LiteralPath $notifKey)) {
                New-Item -Path $notifKey -Force | Out-Null
            }
            Set-ItemProperty -Path $notifKey -Name 'Enabled' -Value 1 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $notifKey -Name 'ShowBanners' -Value 1 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $notifKey -Name 'ShowInActionCenter' -Value 1 -Type DWord -ErrorAction SilentlyContinue
        } catch { Write-Log "Notification settings registration notice: $_" }

        if ($needProto) {
            try {
                $protoKey = 'HKCU:\Software\Classes\cliptoast'
                New-Item -Path $protoKey -Force | Out-Null
                Set-ItemProperty -Path $protoKey -Name '(Default)' -Value 'URL:ClipToast Protocol' -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $protoKey -Name 'URL Protocol' -Value '' -ErrorAction SilentlyContinue
                $cmdKey = Join-Path $protoKey 'shell\open\command'
                New-Item -Path $cmdKey -Force | Out-Null
                $launcher = Get-ClipToastLauncher
                if ($launcher) {
                    $cmdVal = '"{0}" --action "%1"' -f $launcher
                } else {
                    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    $cmdVal = '"{0}" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f $ps, (Join-Path $AppDir 'action.ps1')
                }
                Set-ItemProperty -Path $cmdKey -Name '(Default)' -Value $cmdVal -ErrorAction SilentlyContinue
            } catch { Write-Log "Protocol registration notice: $_" }
        }

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

function Show-Toast(
    [string]$Title,
    [string]$Body,
    [string]$Tag = 'ct',
    [string]$FolderPath = '',
    [string]$FilePath = '',
    [string]$ReportTag = '',
    [string]$CustomActionTitle = '',
    [string]$CustomActionUri = '',
    [switch]$IncludeLogAction
) {
    if (-not $script:ToastOK) { return }
    if ([string]::IsNullOrWhiteSpace($Tag)) { $Tag = 'ct' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    try {
        $t = [Security.SecurityElement]::Escape($Title)
        $b = [Security.SecurityElement]::Escape($Body)
        $actionList = New-Object System.Collections.Generic.List[string]
        if ($CustomActionTitle -and $CustomActionUri) {
            $actionList.Add("<action content='$([Security.SecurityElement]::Escape($CustomActionTitle))' arguments='$([Security.SecurityElement]::Escape($CustomActionUri))' activationType='protocol'/>")
            if ($IncludeLogAction -and (Test-Path -LiteralPath $LogPath)) {
                $fB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Item -LiteralPath $LogPath).FullName)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
                $actionList.Add("<action content='View log' arguments='cliptoast:open:$fB64' activationType='protocol'/>")
            }
        } elseif ($ReportTag) {
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
        } elseif ($IncludeLogAction -and (Test-Path -LiteralPath $LogPath)) {
            $fB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Item -LiteralPath $LogPath).FullName)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
            $actionList.Add("<action content='View log' arguments='cliptoast:open:$fB64' activationType='protocol'/>")
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
        if (-not $dPath) { $dPath = Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'ClipToast Downloads' }
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
        $cleanManifestVer = ([string]$m.version).TrimStart('v', 'V').Trim()
        $cleanAppVer      = ([string]$AppVersion).TrimStart('v', 'V').Trim()
        if ([version]$cleanManifestVer -le [version]$cleanAppVer) { return @{ Status = 'current'; Version = $AppVersion } }
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
        if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Log "Updated $AppVersion -> $newVer"

        # If system tray was running, reload it so the new code is active immediately
        try {
            $trayMutex = $null
            $isTrayRunning = [System.Threading.Mutex]::TryOpenExisting('Local\ClipToast_Tray_Mutex', [ref]$trayMutex)
            if ($trayMutex) { $trayMutex.Dispose() }
            if ($isTrayRunning) {
                $launcher = Get-ClipToastLauncher
                if ($launcher) {
                    Start-Process -FilePath $launcher -ArgumentList '--stop' -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 400
                    Start-ClipToastScript 'tray.ps1'
                }
            }
        } catch {}

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

