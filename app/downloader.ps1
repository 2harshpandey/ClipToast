# downloader.ps1 - takes the link from the clipboard and downloads it in the background
param([switch]$NoUpdateCheck)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-Toast

$cfg     = Read-Config
$yt      = Join-Path $Bin 'yt-dlp.exe'
$ffmpeg  = Join-Path $Bin 'ffmpeg.exe'
$ffprobe = Join-Path $Bin 'ffprobe.exe'
$env:Path = "$Bin;$env:Path"      # lets yt-dlp find deno
$tag = 'dl' + [guid]::NewGuid().ToString('N').Substring(0, 10)

# ---------- 0. tools present? (first run / repair) ----------
if (-not (Test-Tools)) {
    Show-Toast 'ClipToast' 'First-time setup: configuring media tools (about 200 MB, happens once).' $tag
    & (Join-Path $PSScriptRoot 'install-tools.ps1') | Out-Null
    if (-not (Test-Tools)) { Show-Toast 'Setup failed' 'Could not download the tools. Check your internet connection and try again.' $tag; exit 1 }
}

# ---------- 1. self-update (small, signed package; checked at most every 6 hours) ----------
if (-not $NoUpdateCheck -and $cfg['AutoUpdate'] -ne '0') {
    $u = Invoke-AppUpdate
    if ($u.Status -eq 'updated') {
        Show-Toast ('ClipToast updated to ' + $u.Version) ([string]$u.Notes) 'ctupdate'
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f (Join-Path $AppDir 'downloader.ps1')), '-NoUpdateCheck')
        exit 0
    }
}

# ---------- 2. keep yt-dlp fresh (sites change often) ----------
$cfg = Read-Config
$lastY = [int64]0
[void][int64]::TryParse([string]$cfg['LastYtdlpUpdate'], [ref]$lastY)
if (((Get-UnixNow) - $lastY) -gt 259200) {
    try { & $yt -U 2>&1 | Out-Null } catch {}
    $cfg['LastYtdlpUpdate'] = [string](Get-UnixNow)
    Write-Config $cfg
}

# ---------- 3. read the link ----------
$clip = Get-Clipboard -Raw
$m = [regex]::Match([string]$clip, 'https?://[^\s"<>]+')
if (-not $m.Success) { Show-Toast 'ClipToast' 'No link found in the clipboard. Copy a link first, then try again.' $tag; exit 1 }
$url = $m.Value
Write-Log "START $url"

$Work = Join-Path $env:TEMP ('cliptoast_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Out  = Join-Path $Work 'out'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$dest = $cfg['DownloadDir']

Show-ProgressToast $tag 'Starting download...' (Limit-Text $url 60) 'indeterminate' '' 'Contacting the site...'

# ---------- 4. download: best video + best audio ----------
$h = ''
if ([int](ConvertTo-Num $cfg['MaxHeight']) -gt 0) { $h = '[height<=' + [int](ConvertTo-Num $cfg['MaxHeight']) + ']' }
# Prefer SDR (HDR -> SDR conversion looks washed out), then anything.
$fmt = "bv*${h}[dynamic_range=SDR]+ba/bv*${h}+ba/b${h}"
$ytArgs = @(
    '--no-playlist', '--no-warnings', '--newline', '--no-mtime',
    '--retries', '10', '--fragment-retries', '10', '--socket-timeout', '30',
    '-f', $fmt,
    '-S', 'res,fps,vcodec:h264,abr',     # highest resolution, then fps, then prefer H.264 (no re-encode), then best audio
    '--merge-output-format', 'mkv',
    '--concurrent-fragments', '8',
    '--windows-filenames',
    '--ffmpeg-location', $Bin,
    '-P', $Work,
    '-o', '%(title).100B [%(id)s].%(ext)s',
    '--progress-template', 'download:LGP|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(progress.status)s|%(info.title)s'
)
if ($cfg['CookiesBrowser']) { $ytArgs += @('--cookies-from-browser', [string]$cfg['CookiesBrowser']) }

$script:ytLines = New-Object System.Collections.Generic.List[string]
$script:ytCode  = 1
$script:vTitle  = ''
$sw = [Diagnostics.Stopwatch]::StartNew()

function Invoke-Yt {
    $script:ytLines.Clear()
    $script:ytCode = 1
    $part = 1
    $lastUi = -1000
    & $yt @ytArgs $url 2>&1 | ForEach-Object {
        $line = "$_"
        if ($line.StartsWith('LGP|')) {
            $p = $line.Split([char[]]@('|'), 8)
            if ($p.Count -ge 8) {
                $dl  = ConvertTo-Num $p[1]
                $tot = ConvertTo-Num $p[2]
                if ($tot -le 0) { $tot = ConvertTo-Num $p[3] }
                $spd = ConvertTo-Num $p[4]
                $eta = ConvertTo-Num $p[5]
                $st  = $p[6]
                if ($p[7] -and $p[7] -ne 'NA') { $script:vTitle = Limit-Text $p[7] 70 }
                if (($sw.ElapsedMilliseconds - $lastUi) -ge 700 -or $st -eq 'finished') {
                    $lastUi = $sw.ElapsedMilliseconds
                    if ($tot -gt 0) {
                        $value = Format-Fraction ($dl / $tot)
                        $vtext = '{0} / {1} ({2:N0}%)' -f (Format-Size $dl), (Format-Size $tot), (100 * [Math]::Min(1.0, $dl / $tot))
                    } else {
                        $value = 'indeterminate'
                        $vtext = (Format-Size $dl)
                    }
                    $stat = ''
                    if ($spd -gt 0) { $stat = (Format-Size $spd) + '/s' }
                    if ($eta -gt 0 -and $tot -gt 0) { if ($stat) { $stat += '  -  ' }; $stat += 'ETA ' + (Format-Eta $eta) }
                    if (-not $stat) { $stat = 'Downloading...' }
                    $head = 'Downloading'
                    if ($part -gt 1) { $head = "Downloading (part $part)" }
                    Update-ProgressToast $tag $head $script:vTitle $value $vtext $stat
                }
                if ($st -eq 'finished') { $part++ }
            }
        } else {
            [void]$script:ytLines.Add($line)
        }
    }
    $script:ytCode = $LASTEXITCODE
}

Invoke-Yt
if ($script:ytCode -ne 0) {
    Write-Log 'First attempt failed - updating yt-dlp and retrying'
    Update-ProgressToast $tag 'Retrying...' $script:vTitle 'indeterminate' '' 'Updating the downloader engine'
    try { & $yt -U 2>&1 | Out-Null } catch {}
    Invoke-Yt
}
Write-Log ($script:ytLines -join "`n")
if ($script:ytCode -ne 0) {
    $err = ($script:ytLines | Where-Object { $_ -match 'ERROR' } | Select-Object -Last 1)
    $err = ([string]$err) -replace '^ERROR:\s*', ''
    if (-not $err) { $err = 'Unknown error. See log.txt in %LOCALAPPDATA%\ClipToast' }
    Show-Toast 'Download failed' (Limit-Text $err 200) $tag
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# ---------- 5. make every video WhatsApp-safe: MP4 + H.264 (yuv420p) + AAC + faststart ----------
function Move-Unique([string]$src, [string]$name) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $base = [IO.Path]::GetFileNameWithoutExtension($name)
    $ext  = [IO.Path]::GetExtension($name)
    $target = Join-Path $dest $name
    $i = 1
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $dest ("{0} ({1}){2}" -f $base, $i, $ext)
        $i++
    }
    Move-Item -LiteralPath $src -Destination $target
    return $target
}
function Get-Probe([string]$file, [string]$stream, [string]$entry) {
    return (& $ffprobe -v error -select_streams $stream -show_entries "stream=$entry" -of 'default=nw=1:nk=1' $file | Select-Object -First 1)
}

$saved = @()
$n = 0
foreach ($f in (Get-ChildItem -LiteralPath $Work -File)) {
    $ext = $f.Extension.ToLower()
    if ($ext -in '.jpg', '.jpeg', '.png', '.gif') { $saved += (Move-Unique $f.FullName $f.Name); continue }
    if ($ext -notin '.mkv', '.mp4', '.webm', '.mov', '.m4v') { continue }

    $n++
    $display = $f.BaseName + '.mp4'
    $inFile  = Join-Path $Work ("in$n$ext")            # plain ASCII names so ffmpeg never trips on Hindi/emoji titles
    $outFile = Join-Path $Out  ("out$n.mp4")
    Move-Item -LiteralPath $f.FullName -Destination $inFile

    $vcodec = Get-Probe $inFile 'v:0' 'codec_name'
    $pix    = Get-Probe $inFile 'v:0' 'pix_fmt'
    $acodec = Get-Probe $inFile 'a:0' 'codec_name'
    if (-not $vcodec) { $saved += (Move-Unique $inFile ($f.BaseName + $ext)); continue }   # audio-only: keep as is

    $transcode = $false
    if ($vcodec -eq 'h264' -and $pix -in 'yuv420p', 'yuvj420p') {
        $vArgs = @('-c:v', 'copy')                       # already compatible: no quality loss, instant
    } else {
        $transcode = $true
        $vArgs = @('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '17', '-pix_fmt', 'yuv420p', '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2')
    }
    if (-not $acodec)          { $aArgs = @('-an') }
    elseif ($acodec -eq 'aac') { $aArgs = @('-c:a', 'copy') }
    else                       { $aArgs = @('-c:a', 'aac', '-b:a', '256k', '-ac', '2') }

    $dur = ConvertTo-Num ([string](& $ffprobe -v error -show_entries format=duration -of 'default=nw=1:nk=1' $inFile | Select-Object -First 1))
    $ff = @('-y', '-v', 'error', '-nostats', '-progress', 'pipe:1', '-i', $inFile, '-map', '0:v:0', '-map', '0:a:0?') + $vArgs + $aArgs + @('-movflags', '+faststart', $outFile)

    $head = 'Finishing...'
    if ($transcode) { $head = 'Converting to a WhatsApp-compatible MP4' }
    Update-ProgressToast $tag $head $script:vTitle 'indeterminate' '' 'Preparing...'

    $ffErr = New-Object System.Collections.Generic.List[string]
    $lastUi = -1000
    & $ffmpeg @ff 2>&1 | ForEach-Object {
        $l = "$_"
        if ($l -match '^out_time_(us|ms)=(\d+)$') {
            if ($transcode -and $dur -gt 0 -and ($sw.ElapsedMilliseconds - $lastUi) -ge 700) {
                $lastUi = $sw.ElapsedMilliseconds
                $frac = ([double]$matches[2] / 1000000.0) / $dur
                Update-ProgressToast $tag $head $script:vTitle (Format-Fraction $frac) ('{0:N0}%' -f (100 * [Math]::Min(1.0, $frac))) 'H.264 + AAC, highest quality'
            }
        } elseif ($l -notmatch '^(frame|fps|stream_|bitrate|total_size|out_time|dup_frames|drop_frames|speed|progress)') {
            [void]$ffErr.Add($l)
        }
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outFile)) {
        Write-Log ('FFMPEG FAILED: ' + ($ffErr -join "`n"))
        Show-Toast 'Conversion failed' 'Could not convert the video to MP4. Details are in log.txt in %LOCALAPPDATA%\ClipToast' $tag
        continue
    }
    $saved += (Move-Unique $outFile $display)
}

Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue

if ($saved.Count -eq 0) {
    Show-Toast 'ClipToast' 'Nothing was saved. Details are in log.txt in %LOCALAPPDATA%\ClipToast' $tag
} elseif ($saved.Count -eq 1) {
    $size = Format-Size ((Get-Item -LiteralPath $saved[0]).Length)
    Show-Toast 'Download complete' ("{0}  ({1})" -f (Limit-Text ([IO.Path]::GetFileName($saved[0])) 90), $size) $tag $dest
} else {
    Show-Toast 'Download complete' ("{0} files saved to {1}" -f $saved.Count, $dest) $tag $dest
}
Write-Log ('DONE ' + ($saved -join ' | '))
