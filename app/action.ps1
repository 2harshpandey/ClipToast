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
            if ($task.pid -and [int]$task.pid -gt 0) {
                # Security: verify process exists and is a powershell instance before terminating
                $proc = Get-Process -Id $task.pid -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -like '*powershell*') {
                    Write-Log ("Cancelling task PID " + $task.pid)
                    & taskkill.exe /F /T /PID $task.pid 2>$null | Out-Null
                }
            }
            # Security: ensure work directory is strictly inside TEMP\cliptoast_* before wiping
            if ($task.work -and (Test-Path -LiteralPath $task.work) -and ($task.work -like (Join-Path $env:TEMP 'cliptoast_*'))) {
                Remove-Item -LiteralPath $task.work -Recurse -Force -ErrorAction SilentlyContinue
            }
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
        if ($path -and (Test-Path -LiteralPath $path)) {
            $item = Get-Item -LiteralPath $path
            if ($item -is [System.IO.DirectoryInfo]) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $item.FullName)
            } else {
                # Reveal and select the downloaded file in Explorer
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $item.FullName)
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
                Start-Process -FilePath $item.FullName
            } else {
                Write-Log "Play blocked: non-media extension $ext on $path"
            }
        }
    } catch {
        Write-Log "Play error: $_"
    }
    exit 0
}
