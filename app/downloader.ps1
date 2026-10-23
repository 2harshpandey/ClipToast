# downloader.ps1 - takes the link from the clipboard and downloads it in the background
param([switch]$NoUpdateCheck, [switch]$AudioOnly, [string]$InputUrl)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-Toast

$cfg     = Read-Config
$yt      = Join-Path $Bin 'yt-dlp.exe'
$ffmpeg  = Join-Path $Bin 'ffmpeg.exe'
$ffprobe = Join-Path $Bin 'ffprobe.exe'
$env:Path = "$Bin;$env:Path"      # lets yt-dlp find deno
$tag = 'dl' + [guid]::NewGuid().ToString('N').Substring(0, 10)

# Restore tray icon if user exited it previously and has StartWithWindows enabled
if ($cfg['StartWithWindows'] -ne '0') {
    try {
        $trayRunning = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*tray.ps1*' }
        if (-not $trayRunning) {
            $vbs = Join-Path $AppDir 'run.vbs'
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}" tray.ps1' -f $vbs) -ErrorAction SilentlyContinue
        }
    } catch {}
}

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
        $reArgs = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f (Join-Path $AppDir 'downloader.ps1')), '-NoUpdateCheck')
        if ($AudioOnly) { $reArgs += '-AudioOnly' }
        if ($InputUrl)  { $reArgs += @('-InputUrl', ('"{0}"' -f $InputUrl)) }
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $reArgs
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
$url = ''
if ($InputUrl) {
    $m = [regex]::Match([string]$InputUrl, 'https?://[^\s"<>]+')
    if ($m.Success) { $url = $m.Value }
}
if (-not $url) {
    $clip = Get-Clipboard -Raw
    $m = [regex]::Match([string]$clip, 'https?://[^\s"<>]+')
    if ($m.Success) { $url = $m.Value }
}
if (-not $url) {
    Show-Toast 'ClipToast' 'No link found in clipboard. Copy a YouTube, Instagram, or media link first, then try again.' $tag
    exit 1
}
Write-Log "START url=$url AudioOnly=$AudioOnly"

# Prevent duplicate concurrent downloads of the exact same URL within 4 seconds
$nowUnix = Get-UnixNow
$duplicateFound = $false
try {
    Get-ChildItem -Path $env:TEMP -Filter "cliptoast_task_*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $tData = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
            if ($tData.pid -ne $PID -and $tData.url -eq $url -and [bool]$tData.audioOnly -eq [bool]$AudioOnly) {
                $p = Get-Process -Id $tData.pid -ErrorAction SilentlyContinue
                if ($p -and ($nowUnix - [int64]$tData.time) -lt 4) {
                    $duplicateFound = $true
                }
            }
        } catch {}
    }
} catch {}

if ($duplicateFound) {
    Write-Log "Ignoring duplicate download trigger for $url (already running in another process)"
    exit 0
}

$Work = Join-Path $env:TEMP ('cliptoast_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Out  = Join-Path $Work 'out'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$dest = $cfg['DownloadDir']

# Register task state for Cancel action in toast and duplicate prevention
$taskFile = Join-Path $env:TEMP ("cliptoast_task_" + $tag + ".json")
try {
    @{
        pid       = $PID
        tag       = $tag
        work      = $Work
        url       = $url
        audioOnly = [bool]$AudioOnly
        time      = $nowUnix
    } | ConvertTo-Json | Set-Content -LiteralPath $taskFile -Encoding UTF8
} catch {}

$headline = if ($AudioOnly) { 'Starting audio download (MP3)...' } else { 'Starting download...' }
Show-ProgressToast $tag $headline (Limit-Text $url 60) 'indeterminate' '' 'Contacting the site...'

# ---------- 4. download: best video + best audio OR 320kbps MP3 audio ----------
if ($AudioOnly) {
    $ytArgs = @(
        '--no-playlist', '--no-warnings', '--newline', '--no-mtime',
        '--retries', '10', '--fragment-retries', '10', '--socket-timeout', '30',
        '-f', 'ba/b',
        '-x', '--audio-format', 'mp3', '--audio-quality', '320k',
        '--embed-thumbnail', '--convert-thumbnails', 'jpg',
        '--embed-metadata',
        '--concurrent-fragments', '8',
        '--windows-filenames',
        '--ffmpeg-location', $Bin,
        '-P', $Work,
        '-o', '%(title).150B.%(ext)s',
        '--progress-template', 'download:LGP|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(progress.status)s|%(info.title)s'
    )
} else {
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
        '-o', '%(title).150B.%(ext)s',
        '--progress-template', 'download:LGP|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(progress.status)s|%(info.title)s'
    )
    if ($cfg['DownloadSubs'] -eq '1') {
        $ytArgs += @('--write-subs', '--write-auto-subs', '--sub-langs', 'en,en-orig,hi,hi-orig', '--convert-subs', 'srt')
    }
}
if ($cfg['CookiesBrowser']) { $ytArgs += @('--cookies-from-browser', [string]$cfg['CookiesBrowser']) }

$script:srtNotAvailable = $false
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

                if ($st -eq 'finished') {
                    $lastUi = $sw.ElapsedMilliseconds
                    $part++
                    if ($AudioOnly) {
                        Update-ProgressToast $tag 'Processing Audio' $script:vTitle 'indeterminate' 'Converting' 'Extracting high-quality 320kbps MP3...'
                    } else {
                        Update-ProgressToast $tag 'Processing' $script:vTitle 'indeterminate' 'Merging' 'Finalizing and merging media streams...'
                    }
                } elseif (($sw.ElapsedMilliseconds - $lastUi) -ge 700) {
                    $lastUi = $sw.ElapsedMilliseconds
                    if ($tot -gt 0) {
                        $pct = [Math]::Min(1.0, $dl / $tot)
                        if ($dl -ge $tot) {
                            $value = 'indeterminate'
                            $vtext = 'Finalizing'
                            $head  = if ($AudioOnly) { 'Processing Audio' } else { 'Processing' }
                            $stat  = if ($AudioOnly) { 'Download finished. Extracting audio...' } else { 'Download finished. Preparing streams...' }
                        } else {
                            $value = Format-Fraction $pct
                            $vtext = '{0} / {1} ({2:N0}%)' -f (Format-Size $dl), (Format-Size $tot), (100 * $pct)
                            $stat = ''
                            if ($spd -gt 0) { $stat = (Format-Size $spd) + '/s' }
                            if ($eta -gt 0) { if ($stat) { $stat += '  -  ' }; $stat += 'ETA ' + (Format-Eta $eta) }
                            if (-not $stat) { $stat = 'Downloading...' }
                            $head = if ($part -gt 1) { "Downloading (part $part)" } else { 'Downloading' }
                        }
                    } else {
                        $value = 'indeterminate'
                        $vtext = (Format-Size $dl)
                        $stat  = if ($spd -gt 0) { (Format-Size $spd) + '/s' } else { 'Downloading...' }
                        $head  = if ($part -gt 1) { "Downloading (part $part)" } else { 'Downloading' }
                    }
                    Update-ProgressToast $tag $head $script:vTitle $value $vtext $stat
                }
            }
        } else {
            [void]$script:ytLines.Add($line)
            if ($line -like '*[ExtractAudio]*') {
                Update-ProgressToast $tag 'Converting Audio' $script:vTitle 'indeterminate' 'Converting' 'Encoding to high-quality 320kbps MP3...'
            } elseif ($line -like '*[ThumbnailsConvertor]*' -or $line -like '*[EmbedThumbnail]*') {
                Update-ProgressToast $tag 'Embedding Artwork' $script:vTitle 'indeterminate' 'Artwork' 'Adding album cover and song metadata...'
            } elseif ($line -like '*[Metadata]*') {
                Update-ProgressToast $tag 'Tagging Metadata' $script:vTitle 'indeterminate' 'Tagging' 'Writing track title and artist tags...'
            } elseif ($line -like '*[Merger]*') {
                Update-ProgressToast $tag 'Merging Streams' $script:vTitle 'indeterminate' 'Merging' 'Combining video and audio streams...'
            } elseif ($line -like '*[Fixup*') {
                Update-ProgressToast $tag 'Fixing Container' $script:vTitle 'indeterminate' 'Fixing' 'Optimizing media container...'
            } elseif ($line -like '*Writing video subtitles*') {
                Update-ProgressToast $tag 'Saving Subtitles' $script:vTitle 'indeterminate' 'Subtitles' 'Saving synchronized .srt captions...'
            }
        }
    }
    $script:ytCode = $LASTEXITCODE
}

Invoke-Yt

# Subtitle recovery: If subtitle rate limit (429) or failure occurred, don't kill the video download!
if ($script:ytCode -ne 0) {
    $isSubError = ($script:ytLines | Where-Object { $_ -match 'Unable to download video subtitles|subtitles.*HTTP Error 429|subtitles.*429|subtitles for' })
    if ($isSubError -and ($ytArgs -contains '--write-subs')) {
        Write-Log "Subtitle download encountered an issue ($isSubError). Checking media status..."
        $script:srtNotAvailable = $true
        $mediaInWork = (Get-ChildItem -LiteralPath $Work -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension.ToLower() -in '.mp4', '.mkv', '.webm', '.mov', '.mp3', '.m4a' })
        if ($mediaInWork) {
            Write-Log "Media was already downloaded; proceeding with packaging."
            $script:ytCode = 0
        } else {
            Write-Log "Retrying video download without subtitles..."
            Update-ProgressToast $tag 'Retrying...' $script:vTitle 'indeterminate' '' 'Subtitles not available. Downloading video...'
            $newYtArgs = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt $ytArgs.Count; $i++) {
                $arg = $ytArgs[$i]
                if ($arg -in '--write-subs', '--write-auto-subs') { continue }
                if ($arg -in '--sub-langs', '--convert-subs') { $i++; continue }
                $newYtArgs.Add($arg)
            }
            $ytArgs = $newYtArgs.ToArray()
            Invoke-Yt
        }
    }
}

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

    $platform = 'media link'
    try { $platform = ([System.Uri]$url).Host } catch {}

    $userPattern = [regex]::Escape($env:USERNAME)
    $profilePattern = [regex]::Escape($env:USERPROFILE)
    $rawLogs = ($script:ytLines | Select-Object -Last 25) -join "`n"
    $cleanLogs = $rawLogs -replace $profilePattern, 'C:\Users\<user>' -replace $userPattern, '<user>'

    $errFile = Join-Path $env:TEMP ("cliptoast_err_" + $tag + ".json")
    try {
        @{
            tag      = $tag
            url      = $url
            platform = $platform
            error    = $err
            logs     = $cleanLogs
            time     = (Get-Date -Format 's')
        } | ConvertTo-Json | Set-Content -LiteralPath $errFile -Encoding UTF8
    } catch {}

    Write-Log "DOWNLOAD FAILED: $err"
    Show-Toast 'Download failed' (Limit-Text $err 130) $tag '' '' $tag
    Remove-Item -LiteralPath $taskFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# ---------- 5. save audio / process video for WhatsApp compatibility ----------
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

if ($AudioOnly) {
    Update-ProgressToast $tag 'Saving Audio' $script:vTitle 'indeterminate' 'Saving' 'Saving 320kbps MP3 to Downloads folder...'
} else {
    Update-ProgressToast $tag 'Processing Video' $script:vTitle 'indeterminate' 'Packaging' 'Checking WhatsApp and Windows compatibility...'
}

foreach ($f in (Get-ChildItem -LiteralPath $Work -File)) {
    $ext = $f.Extension.ToLower()

    # Subtitles and lyrics
    if ($ext -in '.srt', '.vtt') {
        $saved += (Move-Unique $f.FullName $f.Name)
        continue
    }

    # Audio files (already converted to 320k MP3 with embedded cover art)
    if ($ext -in '.mp3', '.m4a', '.aac', '.flac', '.opus', '.ogg', '.wav') {
        $saved += (Move-Unique $f.FullName $f.Name)
        continue
    }

    # Intermediate images or temp files: skip
    if ($ext -in '.jpg', '.jpeg', '.png', '.gif', '.webp', '.part', '.temp', '.ytdl') {
        continue
    }

    # Only process supported video formats through WhatsApp-safe pipeline
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

    $head = if ($transcode) { 'Converting Video' } else { 'Finalizing MP4' }
    $subStatus = if ($transcode) { 'Re-encoding to WhatsApp-compatible H.264 + AAC...' } else { 'Optimizing MP4 for instant playback (faststart)...' }
    $valText = if ($transcode) { 'Converting' } else { 'Finalizing' }
    Update-ProgressToast $tag $head $script:vTitle 'indeterminate' $valText $subStatus

    $ffErr = New-Object System.Collections.Generic.List[string]
    $lastUi = -1000
    & $ffmpeg @ff 2>&1 | ForEach-Object {
        $l = "$_"
        if ($l -match '^out_time_(us|ms)=(\d+)$') {
            if ($transcode -and $dur -gt 0 -and ($sw.ElapsedMilliseconds - $lastUi) -ge 700) {
                $lastUi = $sw.ElapsedMilliseconds
                $frac = ([double]$matches[2] / 1000000.0) / $dur
                Update-ProgressToast $tag $head $script:vTitle (Format-Fraction $frac) ('{0:N0}%' -f (100 * [Math]::Min(1.0, $frac))) 'Re-encoding for universal WhatsApp playback...'
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
    $mainFile = $saved[0]
    $size = Format-Size ((Get-Item -LiteralPath $mainFile).Length)
    $title = if ($AudioOnly -or $mainFile -match '\.(mp3|m4a|aac|opus|flac|wav)$') { "$EmojiMusic Audio downloaded" } else { 'Download complete' }
    $subNote = if ($cfg['DownloadSubs'] -eq '1' -and -not $AudioOnly -and -not $mainFile.EndsWith('.srt')) { " (Subtitles not available for this video)" } else { '' }
    Show-Toast $title ("{0}  ({1}){2}" -f (Limit-Text ([IO.Path]::GetFileName($mainFile)) 75), $size, $subNote) $tag $dest $mainFile
} else {
    $mainFile = ($saved | Where-Object { $_ -match '\.(mp4|mp3|mkv)$' } | Select-Object -First 1)
    if (-not $mainFile) { $mainFile = $saved[0] }
    $title = if ($AudioOnly) { "$EmojiMusic Audio downloaded" } else { 'Download complete' }
    $hasSubs = ($saved | Where-Object { $_ -match '\.(srt|vtt)$' }).Count -gt 0
    $subLabel = if ($hasSubs) { ' (+ subtitles)' } elseif ($cfg['DownloadSubs'] -eq '1' -and -not $AudioOnly) { ' (Subtitles not available)' } else { '' }
    $size = Format-Size ((Get-Item -LiteralPath $mainFile).Length)
    Show-Toast $title ("{0}{1}  ({2})" -f (Limit-Text ([IO.Path]::GetFileName($mainFile)) 75), $subLabel, $size) $tag $dest $mainFile
}
Remove-Item -LiteralPath $taskFile -Force -ErrorAction SilentlyContinue
Write-Log ('DONE ' + ($saved -join ' | '))
