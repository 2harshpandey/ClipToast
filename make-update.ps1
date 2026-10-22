# make-update.ps1 - package a new version of ClipToast and sign it.
#
# Usage (from repository root):
#   powershell -ExecutionPolicy Bypass -File .\make-update.ps1 -Version 1.0.0 -Notes "Initial release"
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

Write-Host ''
Write-Host "Done. Upload these two files to your GitHub release (tag v$Version):" -ForegroundColor Green
Write-Host "  $zip"
Write-Host "  $(Join-Path $OutDir 'latest.json')"
