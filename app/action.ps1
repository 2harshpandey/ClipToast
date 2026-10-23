# action.ps1 - handles protocol actions from toast notifications (cliptoast://)
param([string]$Uri)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-Toast

if (-not $Uri -and $args.Count -gt 0) {
    $Uri = [string]$args[0]
}
if (-not $Uri) { exit 0 }

$Uri = [System.Uri]::UnescapeDataString($Uri).Trim()
Write-Log "ACTION $Uri"

function From-SafeBase64([string]$s) {
    $pad = (4 - ($s.Length % 4)) % 4
    $s = ($s + ('=' * $pad)).Replace('-', '+').Replace('_', '/')
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}

if ($Uri -like 'cliptoast:cancel:*') {
    $tag = $Uri.Substring('cliptoast:cancel:'.Length).Trim()
    $taskFile = Join-Path $env:TEMP ("cliptoast_task_" + $tag + ".json")
    if (Test-Path -LiteralPath $taskFile) {
        try {
            $task = Get-Content -LiteralPath $taskFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($task.pid) {
                Write-Log ("Cancelling task PID " + $task.pid)
                # Terminate PowerShell and all child processes (yt-dlp.exe, ffmpeg.exe)
                & taskkill.exe /F /T /PID $task.pid 2>$null | Out-Null
            }
            if ($task.work -and (Test-Path -LiteralPath $task.work)) {
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

if ($Uri -like 'cliptoast:open:*') {
    $b64 = $Uri.Substring('cliptoast:open:'.Length).Trim()
    try {
        $path = From-SafeBase64 $b64
        if (Test-Path -LiteralPath $path) {
            if ((Get-Item -LiteralPath $path) -is [System.IO.DirectoryInfo]) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $path)
            } else {
                # Select the downloaded file in Explorer
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $path)
            }
        }
    } catch {
        Write-Log "Open error: $_"
    }
    exit 0
}

if ($Uri -like 'cliptoast:play:*') {
    $b64 = $Uri.Substring('cliptoast:play:'.Length).Trim()
    try {
        $path = From-SafeBase64 $b64
        if (Test-Path -LiteralPath $path) {
            Start-Process -FilePath $path
        }
    } catch {
        Write-Log "Play error: $_"
    }
    exit 0
}
