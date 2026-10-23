# make-update.ps1 - package a new version of ClipToast and sign it.
#
# Usage (from repository root):
#   powershell -ExecutionPolicy Bypass -File .\make-update.ps1 -Version 1.1.0 -Notes "Added MP3 audio, system tray, and subtitles"
#
# Output: ClipToast-app-<version>.zip and latest.json -> upload BOTH to the GitHub release.
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$BaseUrl = '',
    [string]$PrivateKey = '',
    [string]$Notes = '',
    [string]$AppDir = '',
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $AppDir) { $AppDir = Join-Path $scriptDir 'app' }
if (-not $OutDir) { $OutDir = Join-Path $scriptDir 'release' }
if (-not $PrivateKey) { $PrivateKey = Join-Path $scriptDir 'PRIVATE-update-signing-key.xml' }
if (-not $BaseUrl) {
    $BaseUrl = "https://github.com/2harshpandey/ClipToast/releases/download/v$Version"
}

if (-not (Test-Path $AppDir)) { throw "App folder not found: $AppDir" }
if (-not (Test-Path $PrivateKey)) { throw "Private key not found: $PrivateKey" }
[void][version]$Version   # validates the format, e.g. 1.0.1
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

[IO.File]::WriteAllText((Join-Path $AppDir 'version.txt'), $Version, (New-Object Text.UTF8Encoding($false)))

$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$launcherSrc = Join-Path $scriptDir 'src\launcher\Program.cs'
$iconPath = Join-Path $scriptDir 'cliptoast.ico'
if ((Test-Path $csc) -and (Test-Path $launcherSrc)) {
    $launcherOut = Join-Path (Join-Path $scriptDir 'src\launcher') 'ClipToast.exe'
    & $csc /target:winexe "/win32icon:$iconPath" /reference:System.Windows.Forms.dll,System.Drawing.dll /optimize+ /platform:anycpu "/out:$launcherOut" $launcherSrc | Out-Null
}

$zip = Join-Path $OutDir ("ClipToast-app-$Version.zip")
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $AppDir '*') -DestinationPath $zip

$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
$rsa.FromXmlString((Get-Content -LiteralPath $PrivateKey -Raw))
$sig = [Convert]::ToBase64String($rsa.SignData([IO.File]::ReadAllBytes($zip), 'SHA256'))

$manifest = [ordered]@{
    version   = $Version
    url       = ($BaseUrl.TrimEnd('/') + '/' + (Split-Path $zip -Leaf))
    signature = $sig
    notes     = $Notes
}
$json = $manifest | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $OutDir 'latest.json'), $json, (New-Object Text.UTF8Encoding($false)))

# Package standalone portable zip (zero-install)
$portableDir = Join-Path $env:TEMP ('cliptoast_port_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$portableZip = Join-Path $OutDir ("ClipToast-v$Version-portable.zip")
if (Test-Path $portableZip) { Remove-Item $portableZip -Force }
try {
    $portClipDir = Join-Path $portableDir 'ClipToast'
    New-Item -ItemType Directory -Force -Path $portClipDir | Out-Null
    Copy-Item $launcherOut (Join-Path $portClipDir 'ClipToast.exe') -Force
    Copy-Item (Join-Path $scriptDir 'cliptoast.ico') (Join-Path $portClipDir 'cliptoast.ico') -Force
    Copy-Item (Join-Path $scriptDir 'cliptoast.png') (Join-Path $portClipDir 'cliptoast.png') -Force
    Copy-Item (Join-Path $scriptDir 'LICENSE') (Join-Path $portClipDir 'LICENSE') -Force
    Copy-Item (Join-Path $scriptDir 'README.md') (Join-Path $portClipDir 'README.md') -Force
    Copy-Item $AppDir (Join-Path $portClipDir 'app') -Recurse -Force
    Compress-Archive -Path (Join-Path $portableDir '*') -DestinationPath $portableZip
} finally {
    Remove-Item -LiteralPath $portableDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Done. Upload these files to your GitHub release (tag v$Version):" -ForegroundColor Green
Write-Host "  $(Join-Path $OutDir 'ClipToastSetup-v1.1.exe')  (Installer)"
Write-Host "  $portableZip  (Portable Zero-Install ZIP)"
Write-Host "  $zip  (Signed auto-update bundle)"
Write-Host "  $(Join-Path $OutDir 'latest.json')  (Update signature manifest)"
