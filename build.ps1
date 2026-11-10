# build.ps1 - build launcher, (optional) download dependencies, and compile NSIS installer
param(
    [switch]$BundleTools,
    [string]$Version = '1.1.1'
)
$ErrorActionPreference = 'Stop'
$rootDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$outDir = Join-Path $rootDir 'release'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "==========================================================" -ForegroundColor Green
Write-Host " ClipToast - Build & Package Wizard (v$Version)" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

# 1. Compile C# Launcher
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$launcherSrc = Join-Path $rootDir 'src\launcher\Program.cs'
$launcherOut = Join-Path $rootDir 'src\launcher\ClipToast.exe'
$iconPath = Join-Path $rootDir 'cliptoast.ico'

if (-not (Test-Path -LiteralPath $csc)) {
    throw "C# compiler not found at $csc"
}

Write-Host "1. Compiling launcher binary (ClipToast.exe)..." -ForegroundColor Cyan
& $csc /target:winexe "/win32icon:$iconPath" /reference:System.Windows.Forms.dll,System.Drawing.dll /optimize+ /platform:anycpu "/out:$launcherOut" $launcherSrc
if ($LASTEXITCODE -ne 0) { throw "Launcher compilation failed with exit code $LASTEXITCODE" }
Copy-Item $launcherOut (Join-Path $rootDir 'ClipToast.exe') -Force
Write-Host "   Launcher compiled successfully." -ForegroundColor Green

# 2. Bundle Tools if requested
if ($BundleTools) {
    Write-Host "2. Downloading media dependencies into bin\ for offline installer bundle..." -ForegroundColor Cyan
    & (Join-Path $rootDir 'app\install-tools.ps1') -FromInstaller -Force
    if ($LASTEXITCODE -ne 0) { throw "Failed to download media dependencies into bin\" }
    Write-Host "   Dependencies downloaded and verified." -ForegroundColor Green
} else {
    Write-Host "2. Skipping tool pre-download. (Installer will configure them during setup)." -ForegroundColor Yellow
}

# 3. Locate and compile with NSIS
Write-Host "3. Locating NSIS compiler (makensis)..." -ForegroundColor Cyan
$makensis = Get-Command makensis.exe -ErrorAction SilentlyContinue
if (-not $makensis) {
    foreach ($p in @(
        'C:\Program Files (x86)\NSIS\makensis.exe',
        'C:\Program Files\NSIS\makensis.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\NSIS\makensis.exe')
    )) {
        if (Test-Path -LiteralPath $p) { $makensis = Get-Item $p; break }
    }
}

$installerExe = Join-Path $outDir ("ClipToastSetup-v$Version.exe")
if ($makensis) {
    Write-Host "   Found NSIS at: $($makensis.FullName)" -ForegroundColor Green
    Write-Host "   Building installer: $installerExe ..." -ForegroundColor Cyan
    & $makensis.FullName "/DOUT_FILE=$installerExe" "/DAPP_VERSION=$Version" (Join-Path $rootDir 'installer.nsi')
    if ($LASTEXITCODE -ne 0) { throw "NSIS build failed with exit code $LASTEXITCODE" }
    Write-Host "   Installer built successfully: $installerExe" -ForegroundColor Green
} else {
    Write-Host "   makensis.exe not found in PATH or standard Program Files locations." -ForegroundColor Yellow
    Write-Host "   To build the installer executable, install NSIS (e.g. 'winget install NSIS.NSIS') and rerun this script." -ForegroundColor Yellow
}

Write-Host "==========================================================" -ForegroundColor Green
Write-Host " Build completed!" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

