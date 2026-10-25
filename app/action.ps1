# action.ps1 - handles protocol actions from toast notifications (cliptoast://)
param([string]$Uri)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-Toast

if (-not $Uri -and $args.Count -gt 0) {
    $Uri = [string]$args[0]
}
if (-not $Uri) { exit 0 }

# Normalize protocol string: strip quotes, URL-decode, and remove trailing slashes
$Uri = $Uri.Trim('"', "'")
$Uri = [System.Uri]::UnescapeDataString($Uri).Trim().TrimEnd('/')
Write-Log "ACTION $Uri"

function From-SafeBase64([string]$s) {
    $s = $s.Trim().TrimEnd('/')
    $pad = (4 - ($s.Length % 4)) % 4
    $s = ($s + ('=' * $pad)).Replace('-', '+').Replace('_', '/')
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}

# 1. Action: Cancel ongoing download
if ($Uri -like 'cliptoast:cancel:*') {
    $rawTag = $Uri.Substring('cliptoast:cancel:'.Length).Trim()
    # Security: strictly sanitize tag to alphanumeric characters and dashes to prevent path traversal
    $tag = [regex]::Replace($rawTag, '[^a-zA-Z0-9_-]', '')
    if (-not $tag) { exit 0 }

    $taskFile = Join-Path $env:TEMP ("cliptoast_task_" + $tag + ".json")
    if (Test-Path -LiteralPath $taskFile) {
        try {
            $task = Get-Content -LiteralPath $taskFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $targetPid = if ($task.pid) { [int]$task.pid } else { 0 }
            $workPath = if ($task.work) { [string]$task.work } else { '' }

            Write-Log ("Cancelling task tag $tag (PID: $targetPid, Work: $workPath)")
            # Terminate downloader process tree and robustly clean up all files and work directory
            [void](Remove-WorkDirectoryRobust $workPath $targetPid)
        } catch {
            Write-Log "Cancel task error: $_"
        } finally {
            Remove-Item -LiteralPath $taskFile -Force -ErrorAction SilentlyContinue
        }
    }
    Show-Toast 'ClipToast' 'Download was cancelled.' $tag
    exit 0
}

# 2. Action: Open folder or highlight downloaded file in Explorer
if ($Uri -like 'cliptoast:open:*') {
    $b64 = $Uri.Substring('cliptoast:open:'.Length)
    try {
        $path = From-SafeBase64 $b64
        if ($path) {
            if (Test-Path -LiteralPath $path) {
                $item = Get-Item -LiteralPath $path
                if ($item -is [System.IO.DirectoryInfo]) {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $item.FullName)
                } else {
                    # Reveal and select the downloaded file in Explorer
                    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $item.FullName)
                }
            } else {
                # Fallback: if file was moved or renamed, open the parent directory
                $parent = Split-Path -Parent $path
                if ($parent -and (Test-Path -LiteralPath $parent)) {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $parent)
                }
            }
        }
    } catch {
        Write-Log "Open error: $_"
    }
    exit 0
}

# 3. Action: Play downloaded media file
if ($Uri -like 'cliptoast:play:*') {
    $b64 = $Uri.Substring('cliptoast:play:'.Length)
    try {
        $path = From-SafeBase64 $b64
        # Security validation: Path must exist, cannot be a directory, and MUST have a recognized media extension
        if ($path -and (Test-Path -LiteralPath $path)) {
            $item = Get-Item -LiteralPath $path
            $ext = $item.Extension.ToLower()
            $allowedMediaExts = @('.mp4', '.mp3', '.mkv', '.webm', '.m4a', '.aac', '.flac', '.wav', '.ogg', '.opus', '.mov')
            if ($ext -in $allowedMediaExts -and -not ($item -is [System.IO.DirectoryInfo])) {
                Invoke-Item -LiteralPath $item.FullName
            } else {
                Write-Log "Play blocked: non-media extension $ext on $path"
            }
        }
    } catch {
        Write-Log "Play error: $_"
    }
    exit 0
}


# 4. Action: Anonymous Error Report via GitHub Issues
if ($Uri -like 'cliptoast:report:*') {
    $rawTag = $Uri.Substring('cliptoast:report:'.Length).Trim()
    $tag = [regex]::Replace($rawTag, '[^a-zA-Z0-9_-]', '')

    $lastErr = $null
    if ($tag) {
        $errFile = Join-Path $env:TEMP ("cliptoast_err_" + $tag + ".json")
        if (Test-Path -LiteralPath $errFile) {
            try { $lastErr = Get-Content -LiteralPath $errFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        }
    }

    $osInfo = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue)
    $osName = if ($osInfo) { "$($osInfo.Caption) (Build $($osInfo.BuildNumber))" } else { [System.Environment]::OSVersion.VersionString }
    $arch = [System.Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")

    $ytVer = 'unknown'
    try {
        $ytBin = Join-Path $Bin 'yt-dlp.exe'
        if (Test-Path -LiteralPath $ytBin) { $ytVer = (& $ytBin --version).Trim() }
    } catch {}

    $errSummary = if ($lastErr -and $lastErr.error) { [string]$lastErr.error } else { 'Media download encountered an unrecoverable failure.' }
    $platform = if ($lastErr -and $lastErr.platform) { [string]$lastErr.platform } else { 'Media platform' }
    $sanitizedLogs = if ($lastErr -and $lastErr.logs) { [string]$lastErr.logs } else { 'No detailed logs available.' }

    $title = "[Bug] Download failed on $platform"
    $title = Limit-Text $title 70

    $body = @"
### Problem Description
Download failed on **$platform** with error:
````
$errSummary
````

### Anonymous Environment Info
- **ClipToast Version:** $AppVersion
- **yt-dlp Version:** $ytVer
- **Operating System:** $osName ($arch)

### Diagnostics Log (Anonymous)
````
$sanitizedLogs
````
"@

    $issueUrl = "https://github.com/2harshpandey/ClipToast/issues/new?title=" + [System.Uri]::EscapeDataString($title) + "&body=" + [System.Uri]::EscapeDataString($body)

    Show-Toast 'ClipToast Error Reporting' 'Opening anonymous bug report form on GitHub in your browser...'
    Start-Process $issueUrl
    exit 0
}
