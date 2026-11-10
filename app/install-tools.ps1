# install-tools.ps1 - downloads yt-dlp, ffmpeg + ffprobe, and deno into <ClipToast>\bin
param(
    [switch]$Force,
    [switch]$FromInstaller,
    [string]$Tag = ''
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

. (Join-Path $PSScriptRoot 'common.ps1')

# Ensure Bin directory exists
New-Item -ItemType Directory -Force -Path $Bin | Out-Null

# Load compression assemblies
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

# Guarantee modern TLS security protocols (TLS 1.2 and TLS 1.3)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12, Tls13'
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

# Concurrency lock to prevent concurrent downloads/file corruptions
$mutex = $null
$hasLock = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\ClipToast_InstallTools_Mutex')
    try {
        $hasLock = $mutex.WaitOne(300000) # Wait up to 5 minutes
    } catch [System.Threading.AbandonedMutexException] {
        $hasLock = $true
    }
} catch {
    $hasLock = $true
}

if (-not $hasLock) {
    Write-Log 'Could not acquire InstallTools mutex within timeout.'
    if (Test-Tools) { exit 0 }
    exit 1
}

# If already valid and force not specified, finish immediately
if (-not $Force -and (Test-Tools)) {
    Write-Log 'Media tools already installed and verified.'
    if ($FromInstaller) {
        Write-Host "All media dependencies are already installed and verified." -ForegroundColor Green
    }
    if ($mutex -and $hasLock) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
    exit 0
}

function Report-Status([string]$Title, [string]$Detail, [double]$Fraction = -1.0, [string]$StatusText = '') {
    Write-Log "install-tools: $Title - $Detail"
    if ($FromInstaller -or [Environment]::UserInteractive) {
        Write-Host ("  >> {0} : {1}" -f $Title, $Detail) -ForegroundColor Cyan
    }
    if ($Tag -and $script:ToastOK) {
        $val = if ($Fraction -ge 0.0) { Format-Fraction $Fraction } else { 'indeterminate' }
        $vtext = if ($Fraction -ge 0.0) { ('{0:N0}%' -f ($Fraction * 100)) } else { '' }
        Update-ProgressToast $Tag 'Setting Up Media Tools' $Title $val $vtext (if ($StatusText) { $StatusText } else { $Detail })
    }
}

function Download-File([string]$Url, [string]$Dest, [string]$Label) {
    $destDir = Split-Path -Parent $Dest
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    $success = $false
    $errList = New-Object System.Collections.Generic.List[string]

    # Strategy 1: curl.exe (standard in Windows 10/11, highly resilient with redirects and large files)
    if ($curl) {
        try {
            $curlArgs = @('-L', '--fail', '--retry', '3', '--retry-delay', '2', '--connect-timeout', '30', '--max-time', '600', '-o', $Dest, $Url)
            if ($FromInstaller) {
                $curlArgs = @('-#') + $curlArgs
            } else {
                $curlArgs = @('-s', '-S') + $curlArgs
            }
            $p = Start-Process -FilePath $curl.Source -ArgumentList $curlArgs -NoNewWindow -PassThru -Wait
            if ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $Dest) -and ((Get-Item -LiteralPath $Dest).Length -gt 10000)) {
                $success = $true
            } else {
                $errList.Add("curl failed (exit $($p.ExitCode))")
            }
        } catch {
            $errList.Add("curl exception: $_")
        }
    }

    # Strategy 2: System.Net.WebClient fallback
    if (-not $success) {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'ClipToast/1.1 (Windows NT)')
            $wc.DownloadFile($Url, $Dest)
            if ((Test-Path -LiteralPath $Dest) -and ((Get-Item -LiteralPath $Dest).Length -gt 10000)) {
                $success = $true
            } else {
                $errList.Add("WebClient returned invalid file")
            }
        } catch {
            $errList.Add("WebClient exception: $_")
        }
    }

    # Strategy 3: Invoke-WebRequest fallback
    if (-not $success) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 300 -Headers @{ 'User-Agent' = 'ClipToast/1.1' }
            if ((Test-Path -LiteralPath $Dest) -and ((Get-Item -LiteralPath $Dest).Length -gt 10000)) {
                $success = $true
            } else {
                $errList.Add("Invoke-WebRequest returned invalid file")
            }
        } catch {
            $errList.Add("Invoke-WebRequest exception: $_")
        }
    }

    if (-not $success) {
        throw "Failed to download $Label ($Url): $($errList -join '; ')"
    }
}

function Expand-FromZip([string]$Zip, [string[]]$Names) {
    if (-not (Test-Path -LiteralPath $Zip)) { throw "Zip file not found: $Zip" }

    $z = [System.IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($e in $z.Entries) {
            $entryFileName = if ($e.Name) { $e.Name } else { [System.IO.Path]::GetFileName($e.FullName) }
            foreach ($n in $Names) {
                if ($entryFileName -ieq $n) {
                    $target = Join-Path $Bin $n
                    if (Test-Path -LiteralPath $target) {
                        try { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue } catch {}
                    }
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
                }
            }
        }
    } finally {
        $z.Dispose()
    }

    foreach ($n in $Names) {
        $target = Join-Path $Bin $n
        if (-not (Test-Path -LiteralPath $target) -or ((Get-Item -LiteralPath $target).Length -lt 10000)) {
            return $false
        }
    }
    return $true
}

$tmp = Join-Path $env:TEMP ('cliptoast_tools_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # Terminate any leftover instances to release file locks if reinstalling
    if ($Force) {
        Get-Process -Name 'yt-dlp', 'ffmpeg', 'ffprobe', 'deno' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }

    if ($FromInstaller) {
        Write-Host ""
        Write-Host "==========================================================" -ForegroundColor Green
        Write-Host " ClipToast - Installing Media Processing Dependencies" -ForegroundColor Green
        Write-Host "==========================================================" -ForegroundColor Green
        Write-Host " yt-dlp  : Media extraction engine"
        Write-Host " FFmpeg  : Universal video/audio converter (H.264, AAC, MP3)"
        Write-Host " ffprobe : Media format inspector"
        Write-Host " Deno    : High-performance JavaScript runtime for YouTube"
        Write-Host "----------------------------------------------------------"
    }

    # 1. yt-dlp.exe (~17 MB)
    $ytTarget = Join-Path $Bin 'yt-dlp.exe'
    if ($Force -or -not (Test-Path -LiteralPath $ytTarget) -or ((Get-Item -LiteralPath $ytTarget).Length -lt 10000)) {
        Report-Status "Step 1 of 3: yt-dlp" "Downloading yt-dlp media engine..." 0.15 "Downloading media extractor..."
        $ytTmp = Join-Path $tmp 'yt-dlp.exe'
        Download-File 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' $ytTmp 'yt-dlp'
        Move-Item -LiteralPath $ytTmp -Destination $ytTarget -Force
    }

    # 2. FFmpeg & ffprobe (~85 MB)
    $ffTarget = Join-Path $Bin 'ffmpeg.exe'
    $probeTarget = Join-Path $Bin 'ffprobe.exe'
    if ($Force -or -not (Test-Path -LiteralPath $ffTarget) -or -not (Test-Path -LiteralPath $probeTarget) -or
        ((Get-Item -LiteralPath $ffTarget).Length -lt 10000) -or ((Get-Item -LiteralPath $probeTarget).Length -lt 10000)) {
        Report-Status "Step 2 of 3: FFmpeg" "Downloading FFmpeg & ffprobe (~85 MB)..." 0.50 "Downloading audio/video converter..."
        $ffZip = Join-Path $tmp 'ffmpeg.zip'
        $ffMirrors = @(
            'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
            'https://github.com/GyanD/codexffmpeg/releases/latest/download/ffmpeg-release-essentials.zip',
            'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip'
        )
        $ffSuccess = $false
        foreach ($mirror in $ffMirrors) {
            try {
                Download-File $mirror $ffZip 'FFmpeg package'
                Report-Status "Step 2 of 3: FFmpeg" "Extracting ffmpeg.exe and ffprobe.exe..." 0.70 "Extracting converter tools..."
                if (Expand-FromZip $ffZip @('ffmpeg.exe', 'ffprobe.exe')) {
                    $ffSuccess = $true
                    break
                }
            } catch {
                Write-Log "FFmpeg mirror failed ($mirror): $_"
            }
        }
        if (-not $ffSuccess) {
            throw "Failed to download and extract FFmpeg from all mirrors."
        }
    }

    # 3. Deno (~35 MB)
    $denoTarget = Join-Path $Bin 'deno.exe'
    if ($Force -or -not (Test-Path -LiteralPath $denoTarget) -or ((Get-Item -LiteralPath $denoTarget).Length -lt 10000)) {
        Report-Status "Step 3 of 3: Deno" "Downloading Deno JavaScript runtime..." 0.85 "Downloading JavaScript engine..."
        $denoZip = Join-Path $tmp 'deno.zip'
        Download-File 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip' $denoZip 'Deno'
        Report-Status "Step 3 of 3: Deno" "Extracting deno.exe..." 0.95 "Extracting JavaScript engine..."
        if (-not (Expand-FromZip $denoZip @('deno.exe'))) {
            throw "Failed to extract deno.exe from package."
        }
    }

    if (Test-Tools) {
        Report-Status "Complete" "All media dependencies are ready and verified!" 1.0 "Ready"
        if ($FromInstaller) {
            Write-Host ""
            Write-Host "[OK] All dependencies installed successfully!" -ForegroundColor Green
            Write-Host ""
        }
        exit 0
    } else {
        throw "One or more tools are missing after installation."
    }
} catch {
    Write-Log "install-tools failed: $_"
    if ($FromInstaller -or [Environment]::UserInteractive) {
        Write-Host ""
        Write-Host "[ERROR] $_" -ForegroundColor Red
        Write-Host ""
    }
    exit 1
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($mutex -and $hasLock) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}
