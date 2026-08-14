# install.ps1 — apply the two in-process provider patches required by the `cwd`
# parameter of dsh-subagent-cwd.
#
# Usage:  powershell -ExecutionPolicy Bypass -File install.ps1
#
# What it does:
#   1. Locates the two target packages under <dsh install>/node_modules and
#      <DSH_HOME>/profiles/*/node_modules (they are the SAME physical files —
#      patching one syncs both, but each profile dir is checked for the backup).
#   2. Backs up each target to <file>.bak_cwd / .bak_cwd_bundle (first run only).
#   3. Applies the two hunks with an exact, idempotent, LINE-BASED replacement
#      (the installed files use LF line endings; line-level replacement avoids
#      hard-coding any EOL style).
#   4. Runs `node --check` on both patched files.
#
# Safe to re-run: already-patched files are detected and skipped.
# Uninstall: run uninstall.ps1.

$ErrorActionPreference = 'Stop'

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

function Get-TargetFile($root, $rel) {
  $p = Join-Path $root $rel
  if (Test-Path $p) { return $p }
  return $null
}

# Line-based patch application. Preserves the file's own EOL style (LF or CRLF)
# by operating on lines and joining with the detected separator.
function Apply-Replace($path, $oldLines, $newLines, $label) {
  $raw = [System.IO.File]::ReadAllText($path)
  $eol = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
  $lines = $raw -split "`r?`n"
  # strip a trailing empty element from a final newline
  if ($lines.Length -gt 0 -and $lines[$lines.Length-1] -eq '') {
    $lines = $lines[0..($lines.Length-2)]
  }
  $joined = $lines -join "`n"
  if ($joined.Contains(($newLines -join "`n"))) {
    Write-Host "[skip] $label already patched: $path"
    return
  }
  $idx = -1
  for ($i = 0; $i -le $lines.Length - $oldLines.Length; $i++) {
    $match = $true
    for ($j = 0; $j -lt $oldLines.Length; $j++) {
      if ($lines[$i+$j] -ne $oldLines[$j]) { $match = $false; break }
    }
    if ($match) { $idx = $i; break }
  }
  if ($idx -lt 0) {
    throw "[ERROR] $label anchor not found in $path — version mismatch? Refusing to patch blindly."
  }
  $result = @()
  if ($idx -gt 0) { $result += $lines[0..($idx-1)] }
  $result += $newLines
  if ($idx + $oldLines.Length -lt $lines.Length) {
    $result += $lines[($idx+$oldLines.Length)..($lines.Length-1)]
  }
  [System.IO.File]::WriteAllText($path, ($result -join $eol) + $eol)
  Write-Host "[ok]   patched: $path"
}

# hunk 1: foreground in-process driver — replace the meta line with the merge.
$hunk1Old = @(
  "`t`tmeta: childSessionMeta(parent, childDepth, activationBoundary),"
)
$hunk1New = @(
  "`t`tmeta: {",
  "`t`t`t...childSessionMeta(parent, childDepth, activationBoundary),",
  "`t`t`t...request.cwd !== void 0 ? { cwd: request.cwd } : {}",
  "`t`t},"
)

# hunk 2: continuable bundle (inline copy) — replace the create.meta line.
$hunk2Old = @(
  "`t`t`t`t`t`tmeta: childSessionMeta(parent, childDepth, lineageSeedLength),"
)
$hunk2New = @(
  "`t`t`t`t`t`tmeta: {",
  "`t`t`t`t`t`t...childSessionMeta(parent, childDepth, lineageSeedLength),",
  "`t`t`t`t`t`t...request.cwd !== void 0 ? { cwd: request.cwd } : {}",
  "`t`t`t`t`t},"
)

$applied = @()
$roots = Get-DshRoots
Write-Host "dsh roots found: $($roots -join ', ')"

foreach ($root in $roots) {
  # hunk 1
  $f1 = Get-TargetFile $root '@deepseek-ai\dsh-subagent-in-process-driver\lib\index.js'
  if ($f1) {
    $bak = "$f1.bak_cwd"
    if (-not (Test-Path $bak)) { Copy-Item $f1 $bak; Write-Host "[bak] $bak" }
    Apply-Replace $f1 $hunk1Old $hunk1New '01-in-process-driver'
    $applied += $f1
  }
  # hunk 2
  $f2 = Get-TargetFile $root '@deepseek-ai\dsh-subagent\lib\index.js'
  if ($f2) {
    $bak = "$f2.bak_cwd_bundle"
    if (-not (Test-Path $bak)) { Copy-Item $f2 $bak; Write-Host "[bak] $bak" }
    Apply-Replace $f2 $hunk2Old $hunk2New '02-subagent-bundle'
    $applied += $f2
  }
}

if ($applied.Count -eq 0) {
  Write-Host '[warn] No target package files found. Is dsh installed under ..\..\..\dsh and ..\..\..\dsh_home?'
  exit 1
}

Write-Host ''
Write-Host 'Verifying syntax...'
foreach ($f in ($applied | Select-Object -Unique)) {
  node --check $f
  if ($LASTEXITCODE -ne 0) { throw "node --check FAILED on $f" }
  Write-Host "[ok] node --check passed: $f"
}

Write-Host ''
Write-Host 'Done. Restart `dsh --profile web` for the patches to take effect.'
Write-Host 'Verify the continuable patch landed in the BUNDLE (not lib/types/continuation.js):'
Write-Host "  Select-String -Path `"$(Join-Path $roots[0] '@deepseek-ai\dsh-subagent\lib\index.js')`" -Pattern 'request.cwd'"
