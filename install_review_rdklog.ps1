<#
.SYNOPSIS
  Install or update Review LogFiles on Windows (local use).

.EXAMPLE
  irm https://raw.githubusercontent.com/udaybhadauria/Review_LogFiles/main/install_review_rdklog.ps1 | iex

.EXAMPLE
  .\install_review_rdklog.ps1 -Dir C:\Tools\Review_LogFiles -Port 8443 -Start
#>
[CmdletBinding()]
param(
  [string]$Dir = $(if ($env:PROJECT_DIR) { $env:PROJECT_DIR } else { Join-Path $HOME 'Review_LogFiles' }),
  [string]$Repo = $(if ($env:REPO_URL) { $env:REPO_URL } else { 'https://github.com/udaybhadauria/Review_LogFiles.git' }),
  [string]$Branch = $(if ($env:BRANCH) { $env:BRANCH } else { 'main' }),
  [int]$Port = 0,
  [switch]$Start,
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "[ok] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[warn] $msg" -ForegroundColor Yellow }
# throw (not exit) so that `irm ... | iex` does not close the user's PowerShell window.
function Fail($msg) { throw "[error] $msg" }
function Invoke-Checked {
  param([string]$Exe, [string[]]$Arguments)
  & $Exe @Arguments
  if ($LASTEXITCODE -ne 0) { Fail "Command failed ($LASTEXITCODE): $Exe $($Arguments -join ' ')" }
}

# Running from inside an existing checkout: deploy that checkout.
if (-not $PSBoundParameters.ContainsKey('Dir') -and $PSScriptRoot -and
    (Test-Path (Join-Path $PSScriptRoot '.git')) -and (Test-Path (Join-Path $PSScriptRoot 'pyproject.toml'))) {
  $Dir = $PSScriptRoot
}
$Dir = [IO.Path]::GetFullPath($Dir)
$venv = Join-Path $Dir '.venv'
$envFile = Join-Path $Dir '.env'

if ($Uninstall) {
  Step "Uninstalling from $Dir"
  if ((Test-Path $Dir) -and ((Read-Host "Delete $Dir including uploads and .env? [y/N]") -match '^[Yy]$')) {
    Remove-Item -Recurse -Force -LiteralPath $Dir
    Ok "Deleted $Dir"
  } else { Write-Host "Kept $Dir" }
  return
}

Write-Host "Review LogFiles installer" -ForegroundColor Cyan
Write-Host "    Directory : $Dir"
Write-Host "    Repository: $Repo ($Branch)"

Step '1/4 Prerequisites'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Fail 'git is required. Install it with:  winget install --id Git.Git -e'
}
$python = $null
foreach ($candidate in @(@('py', '-3'), @('python'), @('python3'))) {
  if (-not (Get-Command $candidate[0] -ErrorAction SilentlyContinue)) { continue }
  $probeArgs = @($candidate | Select-Object -Skip 1) + @('-c', 'import sys; print(sys.executable) if sys.version_info >= (3, 10) else exit(1)')
  $exe = & $candidate[0] @probeArgs 2>$null
  if ($LASTEXITCODE -eq 0 -and $exe) { $python = $exe.Trim(); break }
}
if (-not $python) { Fail 'Python 3.10+ is required. Install it with:  winget install --id Python.Python.3.12 -e' }
Ok "Using $(& $python -V) ($python)"

Step '2/4 Source code'
if (Test-Path (Join-Path $Dir '.git')) {
  if (git -C $Dir status --porcelain --untracked-files=no) {
    $stash = "installer-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Warn "Local changes found; stashing them as '$stash' (restore with: git -C `"$Dir`" stash pop)"
    Invoke-Checked git @('-C', $Dir, 'stash', 'push', '-q', '-m', $stash)
  }
  Invoke-Checked git @('-C', $Dir, 'fetch', '-q', '--tags', 'origin', $Branch)
  Invoke-Checked git @('-C', $Dir, 'checkout', '-q', $Branch)
  Invoke-Checked git @('-C', $Dir, 'merge', '-q', '--ff-only', "origin/$Branch")
} else {
  if ((Test-Path $Dir) -and (Get-ChildItem -Force -LiteralPath $Dir | Select-Object -First 1)) {
    Fail "$Dir exists, is not empty and is not a git checkout. Use -Dir to choose another location."
  }
  Invoke-Checked git @('clone', '-q', '--depth', '1', '--branch', $Branch, $Repo, $Dir)
}
if (-not (Test-Path (Join-Path $Dir 'src\review_rdk_logger'))) { Fail "$Dir does not look like the Review LogFiles project." }
Ok "Code at $(git -C $Dir rev-parse --short HEAD)"

Step '3/4 Dependencies'
$venvPython = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $venvPython)) { Invoke-Checked $python @('-m', 'venv', $venv) }
Invoke-Checked $venvPython @('-m', 'pip', 'install', '-q', '--disable-pip-version-check', '--upgrade', 'pip', 'setuptools', 'wheel')
Invoke-Checked $venvPython @('-m', 'pip', 'install', '-q', '--disable-pip-version-check', '-e', $Dir)
$web = Join-Path $venv 'Scripts\review-rdk-web.exe'
Ok "Installed $(& $web --version)"

Step '4/4 Configuration'
$lines = @()
if (Test-Path $envFile) { $lines = @(Get-Content $envFile) }
elseif (Test-Path (Join-Path $Dir '.env.example')) { $lines = @(Get-Content (Join-Path $Dir '.env.example') | Where-Object { $_ -notmatch '^FLASK_SECRET_KEY=' }) }
function Set-EnvLine([string]$key, [string]$value) {
  $found = $false
  $script:lines = @($script:lines | ForEach-Object { if ($_ -match "^$key=") { $found = $true; "$key=$value" } else { $_ } })
  if (-not $found) { $script:lines += "$key=$value" }
}
if ($Port -gt 0) { Set-EnvLine 'APP_PORT' $Port }
$secret = $lines | Where-Object { $_ -match '^FLASK_SECRET_KEY=(.{32,})$' -and $_ -notmatch 'change-me' }
if (-not $secret) { Set-EnvLine 'FLASK_SECRET_KEY' (-join ((1..32) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) })) }
Set-Content -LiteralPath $envFile -Value $lines -Encoding ascii
$effectivePort = (($lines | Where-Object { $_ -match '^APP_PORT=' } | Select-Object -Last 1) -replace '^APP_PORT=', '')
if (-not $effectivePort) { $effectivePort = 5001 }
New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'uploads') | Out-Null

$launcher = Join-Path $Dir 'start_review_rdklog.cmd'
Set-Content -LiteralPath $launcher -Encoding ascii -Value @(
  '@echo off',
  'cd /d "%~dp0"',
  'set REVIEW_DATA_DIR=%~dp0.',
  '".venv\Scripts\review-rdk-web.exe" %*'
)
Ok "Configuration in $envFile (port $effectivePort)"

Write-Host "`nDone." -ForegroundColor Green
Write-Host "  Start:  `"$launcher`""
Write-Host "  Open:   https://localhost:$effectivePort   (self-signed certificate - accept the browser warning)"
Write-Host "  CLI:    `"$(Join-Path $venv 'Scripts\review-rdk-logger.exe')`" <archive.tgz|directory>"

if ($Start) {
  Step 'Starting (Ctrl+C to stop)'
  & $launcher
}
