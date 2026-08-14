# uninstall.ps1 — revert the two in-process provider patches applied by install.ps1.
#
# Usage:  powershell -ExecutionPolicy Bypass -File uninstall.ps1
#
# Restores the .bak_cwd / .bak_cwd_bundle backups created on first install.
# Safe to re-run: missing backups are reported and skipped.

$ErrorActionPreference = 'Continue'

function Get-DshRoots {
  $roots = @()
  $dshInstall = Join-Path $PSScriptRoot '..\..\..\dsh'
  if (Test-Path $dshInstall) { $roots += $dshInstall }
  $dshHome = Join-Path $PSScriptRoot '..\..\..\dsh_home'
  if (Test-Path $dshHome) {
    Get-ChildItem (Join-Path $dshHome 'profiles') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $roots += $_.FullName
    }
  }
  return ($roots | Select-Object -Unique)
}

$restored = @()
foreach ($root in (Get-DshRoots)) {
  foreach ($rel in @(
    '@deepseek-ai\dsh-subagent-in-process-driver\lib\index.js',
    '@deepseek-ai\dsh-subagent\lib\index.js'
  )) {
    $target = Join-Path $root $rel
    if (-not (Test-Path $target)) { continue }
    $bak = "$target.bak_cwd"
    if (-not (Test-Path $bak)) { $bak = "$target.bak_cwd_bundle" }
    if (-not (Test-Path $bak)) {
      Write-Host "[skip] no backup for $target"
      continue
    }
    Copy-Item $bak $target -Force
    Write-Host "[ok]   restored $target from $(Split-Path $bak -Leaf)"
    $restored += $target
  }
}

if ($restored.Count -eq 0) {
  Write-Host '[info] nothing to restore.'
  exit 0
}

Write-Host ''
Write-Host 'Done. Restart `dsh --profile web` for the reverted files to take effect.'
