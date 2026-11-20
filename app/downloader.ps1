# downloader.ps1 - takes the link from the clipboard and downloads it in the background
param([switch]$NoUpdateCheck, [switch]$AudioOnly, [string]$InputUrl)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$env:PYTHONIOENCODING = 'utf-8'
. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-Toast
Clear-ClipToastOrphans

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
            Start-ClipToastScript 'tray.ps1'
        }
    } catch {}
}

# Capture intended link early so clipboard changes during initial tool setup do not lose user intent
$url = ''
if ($InputUrl) {
    $m = [regex]::Match([string]$InputUrl, 'https?://[^\s"<>]+')
    if ($m.Success) { $url = $m.Value }
}
if (-not $url) {
    try {
        $clip = Get-Clipboard -Raw
        $m = [regex]::Match([string]$clip, 'https?://[^\s"<>]+')
        if ($m.Success) { $url = $m.Value }
    } catch {}
}
if ($url) {
    $url = $url.TrimEnd('.', ',', ')', ']', ';', "'", '"')
}

# ---------- 0. tools present? (first run / repair) ----------
if (-not (Test-Tools)) {
    Show-ProgressToast $tag 'ClipToast Setup' 'Configuring media tools (happens once)...' 'indeterminate' 'Starting' 'Connecting to downloads...'
    & (Join-Path $PSScriptRoot 'install-tools.ps1') -Tag $tag
    if (-not (Test-Tools)) {
        Show-Toast 'Setup failed' 'Could not download required media tools. Check your internet connection or open Settings to retry.' $tag
        exit 1
    }
    # Refresh tool paths and environment after tool installation
    $yt      = Join-Path $Bin 'yt-dlp.exe'
    $ffmpeg  = Join-Path $Bin 'ffmpeg.exe'
    $ffprobe = Join-Path $Bin 'ffprobe.exe'
    $env:Path = "$Bin;$env:Path"
}

# ---------- 1. periodic updates (dispatched in background so active download never waits) ----------
$nowUnix = Get-UnixNow
$lastAppCheck   = [int64]0
$lastYtdlpCheck = [int64]0
[void][int64]::TryParse([string]$cfg['LastUpdateCheck'], [ref]$lastAppCheck)
[void][int64]::TryParse([string]$cfg['LastYtdlpUpdate'], [ref]$lastYtdlpCheck)

$needsAppCheck   = (-not $NoUpdateCheck -and $cfg['AutoUpdate'] -ne '0' -and ($nowUnix - $lastAppCheck) -gt 21600)
$needsYtdlpCheck = (($nowUnix - $lastYtdlpCheck) -gt 259200)

if ($needsAppCheck -or $needsYtdlpCheck) {
    if ($needsAppCheck)   { $cfg['LastUpdateCheck'] = [string]$nowUnix }
    if ($needsYtdlpCheck) { $cfg['LastYtdlpUpdate'] = [string]$nowUnix }
    Write-Config $cfg

    $bgCmds = New-Object System.Collections.Generic.List[string]
    if ($needsAppCheck) {
        $bgCmds.Add(". (Join-Path '$AppDir' 'common.ps1'); [void](Invoke-AppUpdate)")
    }
    if ($needsYtdlpCheck) {
        $bgCmds.Add("try { & '$yt' -U 2>&1 | Out-Null } catch {}")
    }
    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ($bgCmds -join '; ')
        )
    } catch {}
}

# ---------- 3. validate link ----------
if (-not $url) {
    $clip = Get-Clipboard -Raw
    $m = [regex]::Match([string]$clip, 'https?://[^\s"<>]+')
    if ($m.Success) {
        $url = $m.Value.TrimEnd('.', ',', ')', ']', ';', "'", '"')
    }
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
            $p = if ($tData.pid) { Get-Process -Id $tData.pid -ErrorAction SilentlyContinue } else { $null }
            if ($p -and $tData.pid -ne $PID -and $tData.url -eq $url -and [bool]$tData.audioOnly -eq [bool]$AudioOnly) {
                if (($nowUnix - [int64]$tData.time) -lt 4) {
                    $duplicateFound = $true
                }
            } elseif (-not $p) {
                # Clean up leftover task file from terminated process
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
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

try {
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
        '--progress-template', 'download:LGP|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(progress.status)s|%(info.title)j'
    )
} else {
    $maxH = [int](ConvertTo-Num $cfg['MaxHeight'])
    $sortList = New-Object System.Collections.Generic.List[string]
    if ($maxH -gt 0) {
        $sortList.Add("res:$maxH")
    } else {
        $sortList.Add('res')
    }
    $sortList.Add('vcodec:h264')
    $sortList.Add('acodec:m4a')
    $sortList.Add('ext:mp4:m4a')
    $sortList.Add('fps')
    $sortList.Add('abr')
    $sortStr = $sortList -join ','

    # Prioritize native H.264 (avc1) video and AAC (mp4a) audio so streams are already
    # MP4-compatible right off the CDN, avoiding slow CPU re-encoding entirely.
    $fmt = 'bv*[vcodec^=avc]+ba[acodec^=mp4a]/bv*[ext=mp4]+ba[ext=m4a]/bv*[dynamic_range=SDR]+ba/b[dynamic_range=SDR]/bv*+ba/b/best'
    $ytArgs = @(
        '--no-playlist', '--no-warnings', '--newline', '--no-mtime',
        '--retries', '10', '--fragment-retries', '10', '--socket-timeout', '30',
        '-f', $fmt,
        '-S', $sortStr,
        '--merge-output-format', 'mp4/mkv',
        '--concurrent-fragments', '8',
        '--windows-filenames',
        '--ffmpeg-location', $Bin,
        '-P', $Work,
        '-o', '%(title).150B.%(ext)s',
        '--progress-template', 'download:LGP|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(progress.status)s|%(info.title)j'
    )
    if ($cfg['DownloadSubs'] -eq '1') {
        $ytArgs += @('--write-subs', '--write-auto-subs', '--sub-langs', 'en,en-orig,hi,hi-orig', '--convert-subs', 'srt')
    }
}

# Resolve cookies: check for cookies.txt first (bypasses Windows Chromium DPAPI App-Bound Encryption), then CookiesBrowser
$cookieFile = $null
$candidateCookieFiles = @(
    (Join-Path $env:LOCALAPPDATA 'ClipToast\cookies.txt'),
    (Join-Path $Root 'cookies.txt'),
    (Join-Path $AppDir 'cookies.txt'),
    (Join-Path $dest 'cookies.txt')
)
foreach ($cf in $candidateCookieFiles) {
    if (Test-Path -LiteralPath $cf) {
        $cookieFile = $cf
        break
    }
}

$cookieArgs = @()
if ($cookieFile) {
    $cookieArgs = @('--cookies', $cookieFile)
    Write-Log "Using cookies file: $cookieFile"
} elseif ($cfg['CookiesBrowser']) {
    $cookieArgs = @('--cookies-from-browser', [string]$cfg['CookiesBrowser'])
}
if ($cookieArgs) { $ytArgs += $cookieArgs }

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
                if ($p[7] -and $p[7] -ne 'NA') {
                    try {
                        $rawT = $p[7]
                        if ($rawT.StartsWith('"') -and $rawT.EndsWith('"')) {
                            $rawT = $rawT | ConvertFrom-Json
                        }
                        $script:vTitle = Limit-Text ($rawT.Normalize([System.Text.NormalizationForm]::FormKD).Trim()) 70
                    } catch {
                        $script:vTitle = Limit-Text $p[7].Trim() 70
                    }
                }

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

$script:isDpapiError = $false
if ($script:ytCode -ne 0) {
    $hasDpapi = ($script:ytLines | Where-Object { $_ -match 'Failed to decrypt with DPAPI|issue #10927' })
    if ($hasDpapi -and ($ytArgs -contains '--cookies-from-browser')) {
        $script:isDpapiError = $true
        Write-Log "Chromium App-Bound Encryption blocked browser cookie extraction (DPAPI). Retrying without browser cookies..."
        Update-ProgressToast $tag 'Retrying...' $script:vTitle 'indeterminate' '' 'Browser locked cookies. Retrying without cookies...'
        $newYtArgs = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $ytArgs.Count; $i++) {
            $arg = $ytArgs[$i]
            if ($arg -eq '--cookies-from-browser') { $i++; continue }
            $newYtArgs.Add($arg)
        }
        $ytArgs = $newYtArgs.ToArray()
        Invoke-Yt
    }
}

# Fallback: Instagram photo posts & carousels (with optional attached audio track)
function Invoke-InstagramPhotoFallback([string]$PostUrl, [string]$WorkDir, [string]$DestDir, [bool]$AudioOnly) {
    Write-Log "Attempting Instagram Photo/Carousel Fallback for: $PostUrl"
    Update-ProgressToast $tag 'Instagram Media' (Limit-Text $PostUrl 60) 'indeterminate' 'Extracting' 'Retrieving Instagram photo and audio streams...'

    $shortcode = ''
    if ($PostUrl -match 'instagram\.com/(?:p|reel|tv)/([^/?#&]+)') {
        $shortcode = $matches[1]
    }
    if (-not $shortcode) { return $false }

    $dumpDir = Join-Path $WorkDir ('ig_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force -Path $dumpDir | Out-Null
    
    $dumpArgs = @('--no-warnings', '--write-pages')
    if ($cookieFile -and (Test-Path -LiteralPath $cookieFile)) {
        $dumpArgs += @('--cookies', $cookieFile)
    } elseif ($cfg['CookiesBrowser'] -and -not $script:isDpapiError) {
        $dumpArgs += @('--cookies-from-browser', [string]$cfg['CookiesBrowser'])
    }
    $dumpArgs += $PostUrl

    $prevPwd = Get-Location
    Set-Location $dumpDir
    try {
        & $yt @dumpArgs 2>&1 | Out-Null
    } finally {
        Set-Location $prevPwd
    }

    $dumpFile = Get-ChildItem -Path $dumpDir -Filter "*.dump" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*media_*_info*' -or $_.Name -like '*graphql*' -or $_.Name -like '*info*.dump' } | Select-Object -First 1
    if (-not $dumpFile) {
        $dumpFile = Get-ChildItem -Path $dumpDir -Filter "*.dump" -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $dumpFile) {
        Remove-Item -LiteralPath $dumpDir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }

    $media = $null
    try {
        $json = (Get-Content -LiteralPath $dumpFile.FullName -Raw -Encoding UTF8) | ConvertFrom-Json
        if ($json.items -and $json.items.Count -gt 0) {
            $media = $json.items[0]
        } elseif ($json.data.xdt_shortcode_media) {
            $media = $json.data.xdt_shortcode_media
        } elseif ($json.data.xig_polaris_media) {
            if ($json.data.xig_polaris_media.if_not_gated_logged_out) {
                $media = $json.data.xig_polaris_media.if_not_gated_logged_out
            } else {
                $media = $json.data.xig_polaris_media
            }
        } elseif ($json.graphql.shortcode_media) {
            $media = $json.graphql.shortcode_media
        }
    } catch {
        Remove-Item -LiteralPath $dumpDir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }
    Remove-Item -LiteralPath $dumpDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $media) { return $false }

    $caption = ''
    if ($media.caption -and $media.caption.text) {
        $caption = $media.caption.text
    }
    $cleanTitle = if ($caption) { ($caption -split "`n")[0] } else { "Instagram_$shortcode" }
    $cleanTitle = ($cleanTitle -replace '[\\/:*?"<>|]', '_').Trim()
    if ($cleanTitle.Length -gt 70) { $cleanTitle = $cleanTitle.Substring(0, 70).Trim() }
    if (-not $cleanTitle) { $cleanTitle = "Instagram_$shortcode" }
    $script:vTitle = $cleanTitle

    # Collect all image URLs (single photo and multi-image carousels)
    $images = New-Object System.Collections.Generic.List[string]
    if ($media.carousel_media) {
        foreach ($item in $media.carousel_media) {
            if ($item.image_versions2 -and $item.image_versions2.candidates) {
                $images.Add($item.image_versions2.candidates[0].url)
            } elseif ($item.display_uri) {
                $images.Add($item.display_uri)
            }
        }
    }
    if ($images.Count -eq 0) {
        if ($media.image_versions2 -and $media.image_versions2.candidates) {
            $images.Add($media.image_versions2.candidates[0].url)
        } elseif ($media.display_uri) {
            $images.Add($media.display_uri)
        }
    }
    if ($images.Count -eq 0) { return $false }

    # Download high-resolution images
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    $idx = 0
    $downloadedImages = New-Object System.Collections.Generic.List[string]
    foreach ($imgUrl in $images) {
        $idx++
        $imgName = if ($images.Count -eq 1) { "$cleanTitle.jpg" } else { "$cleanTitle ($idx).jpg" }
        $imgPath = Join-Path $WorkDir $imgName
        if ($curl) {
            & $curl.Source -s -L -o $imgPath $imgUrl
        } else {
            (New-Object System.Net.WebClient).DownloadFile($imgUrl, $imgPath)
        }
        if ((Test-Path -LiteralPath $imgPath) -and ((Get-Item -LiteralPath $imgPath).Length -gt 1000)) {
            $downloadedImages.Add($imgPath)
        }
    }
    if ($downloadedImages.Count -eq 0) { return $false }

    # Check for attached audio track stream and snippet timing
    $audioUrl = $null
    $audioStartTimeMs = 0
    $audioDurationMs  = 0

    if ($media.music_metadata -and $media.music_metadata.music_info) {
        $mi = $media.music_metadata.music_info
        if ($mi.music_asset_info -and $mi.music_asset_info.progressive_download_url) {
            $audioUrl = $mi.music_asset_info.progressive_download_url
        }
        if ($mi.music_consumption_info) {
            $mci = $mi.music_consumption_info
            if ($mci.audio_asset_start_time_in_ms) { $audioStartTimeMs = [int]$mci.audio_asset_start_time_in_ms }
            if ($mci.overlap_duration_in_ms) { $audioDurationMs = [int]$mci.overlap_duration_in_ms }
        }
    }
    if (-not $audioUrl -and $media.clips_metadata) {
        if ($media.clips_metadata.music_info) {
            $mi = $media.clips_metadata.music_info
            if ($mi.music_asset_info -and $mi.music_asset_info.progressive_download_url) {
                $audioUrl = $mi.music_asset_info.progressive_download_url
            }
            if ($mi.music_consumption_info) {
                $mci = $mi.music_consumption_info
                if ($mci.audio_asset_start_time_in_ms) { $audioStartTimeMs = [int]$mci.audio_asset_start_time_in_ms }
                if ($mci.overlap_duration_in_ms) { $audioDurationMs = [int]$mci.overlap_duration_in_ms }
            }
        } elseif ($media.clips_metadata.original_sound_info -and $media.clips_metadata.original_sound_info.progressive_download_url) {
            $audioUrl = $media.clips_metadata.original_sound_info.progressive_download_url
        }
    }
    if (-not $audioUrl -and $media.music_info) {
        $mi = $media.music_info
        if ($mi.music_asset_info -and $mi.music_asset_info.progressive_download_url) {
            $audioUrl = $mi.music_asset_info.progressive_download_url
        }
        if ($mi.music_consumption_info) {
            $mci = $mi.music_consumption_info
            if ($mci.audio_asset_start_time_in_ms) { $audioStartTimeMs = [int]$mci.audio_asset_start_time_in_ms }
            if ($mci.overlap_duration_in_ms) { $audioDurationMs = [int]$mci.overlap_duration_in_ms }
        }
    }

    # If still no snippet duration found, default to 30s max for photo posts with music
    if ($audioDurationMs -le 0) { $audioDurationMs = 30000 }

    if ($audioUrl) {
        Update-ProgressToast $tag 'Processing Audio' $cleanTitle 'indeterminate' 'Audio' 'Merging attached audio track...'
        $audioFile = Join-Path $WorkDir 'audio_raw.mp4'
        if ($curl) {
            & $curl.Source -s -L -o $audioFile $audioUrl
        } else {
            (New-Object System.Net.WebClient).DownloadFile($audioUrl, $audioFile)
        }

        if ((Test-Path -LiteralPath $audioFile) -and ((Get-Item -LiteralPath $audioFile).Length -gt 1000)) {
            $startSec = [double]($audioStartTimeMs / 1000.0)
            $durSec   = [double]($audioDurationMs / 1000.0)
            $ffAudioArgs = @('-ss', "$startSec", '-t', "$durSec")

            if ($AudioOnly) {
                $mp3File = Join-Path $WorkDir "$cleanTitle.mp3"
                & $ffmpeg -y @ffAudioArgs -i $audioFile -i $downloadedImages[0] -map 0:a -map 1:v -c:a libmp3lame -b:a 320k -c:v copy -id3v2_version 3 -metadata "title=$cleanTitle" $mp3File 2>&1 | Out-Null
                Remove-Item -LiteralPath $audioFile -Force -ErrorAction SilentlyContinue
            } else {
                $mp4File = Join-Path $WorkDir "$cleanTitle.mp4"
                & $ffmpeg -y @ffAudioArgs -i $audioFile -loop 1 -i $downloadedImages[0] -c:v libx264 -tune stillimage -preset ultrafast -crf 20 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest -movflags +faststart $mp4File 2>&1 | Out-Null
                Remove-Item -LiteralPath $audioFile -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-Log "Instagram photo has no web audio stream (mobile app only). Saved high-res photo."
    }

    return $true
}

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
    # Check if this is an Instagram photo or carousel post
    $isInstaNoVideo = ($script:ytLines | Where-Object { $_ -match 'There is no video in this post|no video formats' })
    if ($isInstaNoVideo -and ($url -match 'instagram\.com/(?:p|reel|tv)/([^/?#&]+)')) {
        if (Invoke-InstagramPhotoFallback $url $Work $dest $AudioOnly) {
            $script:ytCode = 0
        }
    }
}

if ($script:ytCode -ne 0) {
    Write-Log 'First attempt failed - updating yt-dlp and retrying'
    Update-ProgressToast $tag 'Retrying...' $script:vTitle 'indeterminate' '' 'Updating the downloader engine'
    try { & $yt -U 2>&1 | Out-Null } catch {}
    Invoke-Yt
    if ($script:ytCode -ne 0) {
        $isInstaNoVideo = ($script:ytLines | Where-Object { $_ -match 'There is no video in this post|no video formats' })
        if ($isInstaNoVideo -and ($url -match 'instagram\.com/(?:p|reel|tv)/([^/?#&]+)')) {
            if (Invoke-InstagramPhotoFallback $url $Work $dest $AudioOnly) {
                $script:ytCode = 0
            }
        }
    }
}
Write-Log ($script:ytLines -join "`n")
if ($script:ytCode -ne 0) {
    $err = ($script:ytLines | Where-Object { $_ -match 'ERROR' } | Select-Object -Last 1)
    $err = ([string]$err) -replace '^ERROR:\s*', ''
    if (-not $err) { $err = 'Unknown error. See log.txt in %LOCALAPPDATA%\ClipToast' }

    $platform = 'media link'
    try { $platform = ([System.Uri]$url).Host } catch {}

    # Check for site-specific authentication or session expiration errors
    $isAuthError = ($script:ytLines | Where-Object { 
        $_ -match 'Sign in to confirm your age|login_required|checkpoint_required|Please log in|confirm you are not a bot|Members-only content|This video is private|requires authentication|HTTP Error 401|HTTP Error 403' 
    })
    if ($isAuthError) {
        $siteName = 'this site'
        if ($url -match 'instagram\.com') { $siteName = 'Instagram' }
        elseif ($url -match 'youtube\.com|youtu\.be') { $siteName = 'YouTube' }
        elseif ($url -match 'tiktok\.com') { $siteName = 'TikTok' }
        elseif ($url -match 'reddit\.com') { $siteName = 'Reddit' }
        elseif ($url -match 'twitter\.com|x\.com') { $siteName = 'Twitter/X' }
        
        $authMsg = "Session expired or login required for $siteName. Please re-export cookies in browser and merge in Settings."
        Write-Log "AUTH EXPIRED/REQUIRED: $siteName - $err"
        Show-Toast "$siteName Session Required" $authMsg $tag '' '' $tag
        exit 1
    }

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
    exit 1
}

# ---------- 5. save audio / process video for WhatsApp compatibility ----------
function Move-Unique([string]$src, [string]$name) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $base = [IO.Path]::GetFileNameWithoutExtension($name).Trim(' .')
    if (-not $base) { $base = 'Media' }
    $ext  = [IO.Path]::GetExtension($name)
    $target = Join-Path $dest ($base + $ext)
    $i = 1
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $dest ("{0} ({1}){2}" -f $base, $i, $ext)
        $i++
    }

    # Resilient move with retries for cross-drive operations and indexer file locks
    $moved = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Move-Item -LiteralPath $src -Destination $target -Force -ErrorAction Stop
            $moved = $true
            break
        } catch {
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
    if (-not $moved) {
        Copy-Item -LiteralPath $src -Destination $target -Force
        Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    }
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

    # Determine safe base name (normalize if styled unicode font was stripped to punctuation)
    $cleanBase = $f.BaseName
    if (($cleanBase -replace '[^a-zA-Z0-9\p{L}]', '' -eq '') -and $script:vTitle) {
        $cleanBase = ($script:vTitle -replace '[\\/:*?"<>|]', '_').Trim()
    }

    # Subtitles and lyrics
    if ($ext -in '.srt', '.vtt') {
        $saved += (Move-Unique $f.FullName ($cleanBase + $ext))
        continue
    }

    # Audio files (already converted to 320k MP3 with embedded cover art)
    if ($ext -in '.mp3', '.m4a', '.aac', '.flac', '.opus', '.ogg', '.wav') {
        $saved += (Move-Unique $f.FullName ($cleanBase + $ext))
        continue
    }

    # High-resolution photo posts (standalone or carousels)
    if ($ext -in '.jpg', '.jpeg', '.png', '.webp') {
        $hasVideoOrAudio = (Get-ChildItem -LiteralPath $Work -File | Where-Object { $_.Extension.ToLower() -in '.mp4', '.mkv', '.webm', '.mov', '.mp3' })
        if (-not $hasVideoOrAudio) {
            $saved += (Move-Unique $f.FullName ($cleanBase + $ext))
            continue
        } else {
            continue
        }
    }

    # Intermediate images or temp files: skip
    if ($ext -in '.gif', '.part', '.temp', '.ytdl') {
        continue
    }

    # Only process supported video formats through WhatsApp-safe pipeline
    if ($ext -notin '.mkv', '.mp4', '.webm', '.mov', '.m4v') { continue }

    $n++
    $display = $cleanBase + '.mp4'
    $inFile  = Join-Path $Work ("in$n$ext")            # plain ASCII names so ffmpeg never trips on Hindi/emoji titles
    $outFile = Join-Path $Out  ("out$n.mp4")
    Move-Item -LiteralPath $f.FullName -Destination $inFile

    $vcodec = $null
    $pix    = $null
    $acodec = $null
    $dur    = [double]0
    try {
        $jsonStr = & $ffprobe -v error -show_entries stream=codec_type,codec_name,pix_fmt -show_entries format=duration -of json $inFile 2>&1
        $probe = $jsonStr | ConvertFrom-Json
        $vStream = ($probe.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1)
        $aStream = ($probe.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1)
        if ($vStream) {
            $vcodec = $vStream.codec_name
            $pix    = $vStream.pix_fmt
        }
        if ($aStream) {
            $acodec = $aStream.codec_name
        }
        if ($probe.format -and $probe.format.duration) {
            $dur = ConvertTo-Num ([string]$probe.format.duration)
        }
    } catch {
        $vcodec = Get-Probe $inFile 'v:0' 'codec_name'
        $pix    = Get-Probe $inFile 'v:0' 'pix_fmt'
        $acodec = Get-Probe $inFile 'a:0' 'codec_name'
        $dur    = ConvertTo-Num ([string](& $ffprobe -v error -show_entries format=duration -of 'default=nw=1:nk=1' $inFile | Select-Object -First 1))
    }
    if (-not $vcodec) { $saved += (Move-Unique $inFile ($f.BaseName + $ext)); continue }   # audio-only: keep as is

    $transcode = $false
    if ($vcodec -eq 'h264' -and $pix -in 'yuv420p', 'yuvj420p') {
        $vArgs = @('-c:v', 'copy')                       # already compatible: no quality loss, instant
    } else {
        $transcode = $true
        $vArgs = @('-c:v', 'libx264', '-preset', 'superfast', '-crf', '19', '-threads', '0', '-pix_fmt', 'yuv420p', '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2')
    }
    if (-not $acodec)          { $aArgs = @('-an') }
    elseif ($acodec -eq 'aac') { $aArgs = @('-c:a', 'copy') }
    else                       { $aArgs = @('-c:a', 'aac', '-b:a', '192k', '-ac', '2') }

    $ff = @('-y', '-v', 'error', '-nostats', '-threads', '0', '-progress', 'pipe:1', '-i', $inFile, '-map', '0:v:0', '-map', '0:a:0?') + $vArgs + $aArgs + @('-movflags', '+faststart', $outFile)

    $head = if ($transcode) { 'Converting Video' } elseif ($acodec -ne 'aac' -and $acodec) { 'Optimizing Audio' } else { 'Finalizing MP4' }
    $subStatus = if ($transcode) { 'Re-encoding to WhatsApp-compatible H.264...' } elseif ($acodec -ne 'aac' -and $acodec) { 'Converting audio track to AAC...' } else { 'Optimizing MP4 for instant playback (faststart)...' }
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

if ($saved.Count -eq 0) {
    Show-Toast 'ClipToast' 'Nothing was saved. Details are in log.txt in %LOCALAPPDATA%\ClipToast' $tag
} elseif ($saved.Count -eq 1) {
    $mainFile = $saved[0]
    $size = Format-Size ((Get-Item -LiteralPath $mainFile).Length)
    $title = if ($AudioOnly -or $mainFile -match '\.(mp3|m4a|aac|opus|flac|wav)$') {
        'Audio downloaded'
    } elseif ($mainFile -match '\.(jpg|jpeg|png|webp)$') {
        'Photo downloaded'
    } else {
        'Download complete'
    }
    $subNote = if ($cfg['DownloadSubs'] -eq '1' -and -not $AudioOnly -and -not $mainFile.EndsWith('.srt')) { " (Subtitles not available for this video)" } else { '' }
    Show-Toast $title ("{0}  ({1}){2}" -f (Limit-Text ([IO.Path]::GetFileName($mainFile)) 75), $size, $subNote) $tag $dest $mainFile
} else {
    $mainFile = ($saved | Where-Object { $_ -match '\.(mp4|mp3|mkv)$' } | Select-Object -First 1)
    if (-not $mainFile) { $mainFile = $saved[0] }
    $title = if ($AudioOnly) {
        'Audio downloaded'
    } elseif ($mainFile -match '\.(jpg|jpeg|png|webp)$') {
        'Photo downloaded'
    } else {
        'Download complete'
    }
    $hasSubs = ($saved | Where-Object { $_ -match '\.(srt|vtt)$' }).Count -gt 0
    $subLabel = if ($hasSubs) { ' (+ subtitles)' } elseif ($cfg['DownloadSubs'] -eq '1' -and -not $AudioOnly) { ' (Subtitles not available)' } else { '' }
    $size = Format-Size ((Get-Item -LiteralPath $mainFile).Length)
    Show-Toast $title ("{0}{1}  ({2})" -f (Limit-Text ([IO.Path]::GetFileName($mainFile)) 75), $subLabel, $size) $tag $dest $mainFile
}
Write-Log ('DONE ' + ($saved -join ' | '))
} finally {
    if ($Work) {
        [void](Remove-WorkDirectoryRobust $Work 0)
    }
    if ($taskFile -and (Test-Path -LiteralPath $taskFile)) {
        Remove-Item -LiteralPath $taskFile -Force -ErrorAction SilentlyContinue
    }
}
