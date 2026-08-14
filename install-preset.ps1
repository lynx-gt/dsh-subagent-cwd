# install-preset.ps1 — make dsh-subagent-cwd available to Web sessions.
#
# WHY THIS IS NEEDED
#   In the `web` profile, agent tools are provided by the mounted agent PRESET
#   (the default `standard` preset composes the `subagent` / `subagent_fork`
#   rows pointing at @deepseek-ai/dsh-tool-subagent), NOT by the host plane.
#   A bundle patch that inserts rows into the host plane is invisible to Web
#   sessions. This script copies `standard` to a user preset (`standard-plus`),
#   rewrites its delegation rows to point at `dsh-subagent-cwd`, and
#   switches the default preset.
#
#   The in-process provider patches (run patches/install.ps1) are still required for
#   the per-call `cwd` parameter to take effect — preset adaptation only routes
#   the tool to this package.
#
# Idempotent. Uninstall: pick `standard` again in the UI and delete the
# standard-plus directory.
#
# Usage:  powershell -ExecutionPolicy Bypass -File install-preset.ps1
#         then restart `dsh web` and start a NEW session.

$ErrorActionPreference = 'Stop'

$dshHome = $env:DSH_HOME
if (-not $dshHome -or -not (Test-Path $dshHome)) {
  $candidate = Join-Path $PSScriptRoot '..\..\dsh_home'
  if (Test-Path $candidate) { $dshHome = (Resolve-Path $candidate).Path }
}
if (-not $dshHome -or -not (Test-Path $dshHome)) {
  throw "Cannot locate DSH_HOME. Set `$env:DSH_HOME or run from the dsh install tree."
}
Write-Host "[info] DSH_HOME = $dshHome"

$candidates = @(
  (Join-Path $PSScriptRoot '..\..\..\node_modules\@deepseek-ai\dsh\config\agent-presets\standard'),
  (Join-Path $dshHome 'profiles\web\node_modules\@deepseek-ai\dsh\config\agent-presets\standard')
)
$standardDir = $candidates | Where-Object { Test-Path (Join-Path $_ 'agent.cordis.yml') } | Select-Object -First 1
if (-not $standardDir) {
  throw 'Cannot locate the deployment `standard` preset (searched dsh install paths).'
}
Write-Host "[info] standard preset at $standardDir"

$standardFile = Join-Path $standardDir 'agent.cordis.yml'
$presetRoot = Join-Path $dshHome '.agent-presets'
$targetDir = Join-Path $presetRoot 'standard-plus'
$targetFile = Join-Path $targetDir 'agent.cordis.yml'

if (Test-Path $targetFile) {
  $existing = Get-Content $targetFile -Raw
  if ($existing -match "name: 'dsh-subagent-cwd'") {
    Write-Host "[skip] standard-plus already adapted."
    exit 0
  }
}

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
Copy-Item $standardFile $targetFile -Force

$content = Get-Content $targetFile -Raw
$old = "      name: '@deepseek-ai/dsh-tool-subagent'"
$new = "      name: 'dsh-subagent-cwd'"
$count = ([regex]::Matches($content, [regex]::Escape($old))).Count
if ($count -eq 0) {
  throw "No delegation rows to rewrite — anchor '$old' not found in $targetFile. Version mismatch?"
}
$content = $content.Replace($old, $new)
Set-Content -Path $targetFile -Value $content -Encoding UTF8 -NoNewline
Write-Host "[ok] rewrote $count delegation row(s) -> dsh-subagent-cwd"

$meta = "name: standard-plus`ndescription: standard preset with dsh-subagent-cwd delegation tools`n"
Set-Content -Path (Join-Path $targetDir 'preset.yml') -Value $meta -Encoding UTF8 -NoNewline
Write-Host "[ok] wrote preset.yml"

$settingsPath = Join-Path $dshHome 'settings.yaml'
if (Test-Path $settingsPath) {
  $settings = Get-Content $settingsPath -Raw
  if ($settings -match 'default:\s*standard(?=\s*$|\s*\n)') {
    $settings = [regex]::Replace($settings, 'default:\s*standard(?=\s*$|\s*\n)', 'default: standard-plus')
    Set-Content -Path $settingsPath -Value $settings -Encoding UTF8 -NoNewline
    Write-Host "[ok] settings.yaml default preset -> standard-plus"
  } elseif ($settings -match 'default:\s*standard-plus') {
    Write-Host "[skip] settings.yaml already default standard-plus"
  } else {
    Write-Host "[warn] no `default: standard` anchor in settings.yaml; set the preset manually in the UI (General > Agent preset)."
  }
} else {
  Write-Host "[warn] no settings.yaml found; set standard-plus in the UI (General > Agent preset)."
}

Write-Host ''
Write-Host 'Done. Restart `dsh web` and start a NEW session for the enhanced subagent tools to appear.'
Write-Host 'Reminder: if you use the per-call `cwd` parameter, also run patches/install.ps1 once.'
