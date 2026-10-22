# install.ps1 - called by the installer. Reads LG_DLDIR / LG_UPDATEURL from the environment.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

$fresh = -not (Test-Path -LiteralPath $ConfigPath)
$cfg = Read-Config
if ($fresh -and $env:LG_DLDIR) { $cfg['DownloadDir'] = $env:LG_DLDIR }
if ($env:LG_UPDATEURL -and -not $cfg['UpdateUrl']) { $cfg['UpdateUrl'] = $env:LG_UPDATEURL }
Write-Config $cfg
try { New-Item -ItemType Directory -Force -Path $cfg['DownloadDir'] | Out-Null } catch { Write-Host "Could not create the download folder: $_" }
Write-Host ("Downloads will be saved to: " + $cfg['DownloadDir'])

& (Join-Path $PSScriptRoot 'install-tools.ps1')
exit $LASTEXITCODE
