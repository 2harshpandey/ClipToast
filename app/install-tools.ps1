# install-tools.ps1 - downloads yt-dlp, ffmpeg + ffprobe and deno into <ClipToast>\bin
param([switch]$Force)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
New-Item -ItemType Directory -Force -Path $Bin | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-File([string]$Url, [string]$Dest, [string]$Label) {
    Write-Host "Downloading $Label ..."
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'ClipToast'
    $req.AllowAutoRedirect = $true
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 60000
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $in = $resp.GetResponseStream()
    $out = [IO.File]::Create($Dest)
    try {
        $buf = New-Object byte[] 262144
        $done = [int64]0
        $mark = 10
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $done += $n
            if ($total -gt 0) {
                $pct = [int](100 * $done / $total)
                if ($pct -ge $mark) { Write-Host ('  {0}: {1}% ({2:N0} MB)' -f $Label, $pct, ($done / 1MB)); $mark += 10 }
            }
        }
    } finally { $out.Close(); $in.Close(); $resp.Close() }
}

function Expand-FromZip([string]$Zip, [string[]]$Names) {
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($e in $z.Entries) {
            foreach ($n in $Names) {
                if ($e.FullName -like "*/bin/$n" -or $e.FullName -eq $n) {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $Bin $n), $true)
                }
            }
        }
    } finally { $z.Dispose() }
}

$tmp = Join-Path $env:TEMP ('cliptoast_tools_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    # --- yt-dlp ---
    $yt = Join-Path $Bin 'yt-dlp.exe'
    if ($Force -or -not (Test-Path -LiteralPath $yt)) {
        Get-File 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' (Join-Path $tmp 'yt-dlp.exe') 'yt-dlp'
        Move-Item -LiteralPath (Join-Path $tmp 'yt-dlp.exe') -Destination $yt -Force
    }

    # --- ffmpeg + ffprobe (two mirrors) ---
    if ($Force -or -not ((Test-Path -LiteralPath (Join-Path $Bin 'ffmpeg.exe')) -and (Test-Path -LiteralPath (Join-Path $Bin 'ffprobe.exe')))) {
        $ok = $false
        foreach ($u in @(
            'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip',
            'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip')) {
            try {
                $zip = Join-Path $tmp 'ffmpeg.zip'
                Get-File $u $zip 'ffmpeg (about 150 MB, please wait)'
                Expand-FromZip $zip @('ffmpeg.exe', 'ffprobe.exe')
                if ((Test-Path -LiteralPath (Join-Path $Bin 'ffmpeg.exe')) -and (Test-Path -LiteralPath (Join-Path $Bin 'ffprobe.exe'))) { $ok = $true; break }
            } catch { Write-Host "  that mirror failed: $_" }
        }
        if (-not $ok) { throw 'Could not download ffmpeg.' }
    }

    # --- deno (YouTube needs a JavaScript runtime for the highest-quality formats) ---
    if ($Force -or -not (Test-Path -LiteralPath (Join-Path $Bin 'deno.exe'))) {
        $zip = Join-Path $tmp 'deno.zip'
        Get-File 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip' $zip 'deno'
        Expand-FromZip $zip @('deno.exe')
    }
} catch {
    Write-Host "ERROR: $_"
    Write-Log "install-tools failed: $_"
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if (Test-Tools) { Write-Host 'All tools are ready.'; exit 0 }
Write-Host 'Some tools are missing. They will be retried the first time you download something.'
exit 1
