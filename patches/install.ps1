# install.ps1 — apply the in-process provider patches required by the `cwd` AND
# `preset` parameters of dsh-subagent-cwd.
#
# Usage:  powershell -ExecutionPolicy Bypass -File install.ps1
#
# What it does:
#   1. Locates the two target packages under <dsh install>/node_modules and
#      <DSH_HOME>/profiles/*/node_modules (they are the SAME physical files —
#      patching one syncs both, but each profile dir is checked for the backup).
#   2. Backs up each target to <file>.bak_cwd / .bak_cwd_bundle (first run only).
#   3. Applies the hunks with an exact, idempotent, LINE-BASED replacement
#      (the installed files use LF line endings; line-level replacement avoids
#      hard-coding any EOL style).
#   4. Runs `node --check` on all patched files.
#
# Hunks:
#   hunk 1  in-process-driver        : merge request.cwd into child session meta
#   hunk 2  subagent bundle          : merge request.cwd into child create.meta
#   hunk 3  in-process-driver        : async setup + recompose child onto request.preset;
#                                      persona × preset coexist — when both are given,
#                                      skip deployment:persona and register
#                                      delegation:role after recompose (survives
#                                      router-style presets that delete persona-named
#                                      sections). Anchors BOTH raw and old-patch states.
#   hunk 4  subagent bundle          : forward request.preset through composition
#   hunk 5  subagent bundle          : async setup + recompose child onto composition.preset
#                                      (same persona × preset coexist; anchors both states)
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

# hunk 1: foreground in-process driver — replace the meta line with the cwd merge.
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
  "`t`t`t`t`t`t`t...childSessionMeta(parent, childDepth, lineageSeedLength),",
  "`t`t`t`t`t`t`t...request.cwd !== void 0 ? { cwd: request.cwd } : {}",
  "`t`t`t`t`t`t},"
)

# hunk 3: foreground in-process driver — async setup + recompose onto request.preset.
# Three states are handled: RAW (original harness), OLD (previous patch state:
# async setup + recompose but persona still registered as deployment:persona),
# and FINAL (persona × preset coexist). hunk3OldRaw anchors the raw file,
# hunk3OldOld anchors the old-patch file; both upgrade to the FINAL text.
$hunk3OldRaw = @(
  "`tconst setup = (childCtx) => {",
  "`t`tappendDelegatedPolicyOverrides(childCtx.agent.session, inherited);",
  "`t`tapplyChildComposition(childCtx, parent, {",
  "`t`t`tpersona: request.persona,",
  "`t`t`ttoolFilter: request.toolFilter",
  "`t`t});",
  "`t`tif (request.outputSchema !== void 0) structured = attachStructuredRuntime(childCtx, request.outputSchema);",
  "`t`tattachDescriptorAppend(childCtx, request.descriptor);",
  "`t};"
)
$hunk3OldOld = @(
  "`tconst setup = async (childCtx) => {",
  "`t`tappendDelegatedPolicyOverrides(childCtx.agent.session, inherited);",
  "`t`tapplyChildComposition(childCtx, parent, {",
  "`t`t`tpersona: request.persona,",
  "`t`t`ttoolFilter: request.toolFilter",
  "`t`t});",
  "`t`tif (request.preset !== void 0) {",
  "`t`t`tawait childCtx.get(`"agentPresets`")?.recompose(childCtx, request.preset);",
  "`t`t}",
  "`t`tif (request.outputSchema !== void 0) structured = attachStructuredRuntime(childCtx, request.outputSchema);",
  "`t`tattachDescriptorAppend(childCtx, request.descriptor);",
  "`t};"
)
$hunk3New = @(
  "`tconst setup = async (childCtx) => {",
  "`t`tappendDelegatedPolicyOverrides(childCtx.agent.session, inherited);",
  "`t`tapplyChildComposition(childCtx, parent, {",
  "`t`t`t// persona + preset 同给时先跳过默认 deployment:persona 段：目标 preset 的",
  "`t`t`t// router-bootstrap 类插件会按名删除 persona 段，改在 recompose 之后注册",
  "`t`t`t// 不含 `"persona`" 字样的 delegation:role 段，与 preset 自身 persona 并存。",
  "`t`t`tpersona: request.persona !== void 0 && request.preset !== void 0 ? undefined : request.persona,",
  "`t`t`ttoolFilter: request.toolFilter",
  "`t`t});",
  "`t`tif (request.preset !== void 0) {",
  "`t`t`tawait childCtx.get(`"agentPresets`")?.recompose(childCtx, request.preset);",
  "`t`t`tif (request.persona !== void 0) {",
  "`t`t`t`tchildCtx.systemPrompt.section({",
  "`t`t`t`t`tname: `"delegation:role`",",
  "`t`t`t`t`torder: 1,",
  "`t`t`t`t`ttext: request.persona",
  "`t`t`t`t});",
  "`t`t`t}",
  "`t`t}",
  "`t`tif (request.outputSchema !== void 0) structured = attachStructuredRuntime(childCtx, request.outputSchema);",
  "`t`tattachDescriptorAppend(childCtx, request.descriptor);",
  "`t};"
)

# hunk 4: continuable bundle — forward request.preset through composition.
$hunk4Old = @(
  "`t`t`t`t`tcomposition: {",
  "`t`t`t`t`t`tpersona: request.persona,",
  "`t`t`t`t`t`ttoolFilter: request.toolFilter",
  "`t`t`t`t`t},"
)
$hunk4New = @(
  "`t`t`t`t`tcomposition: {",
  "`t`t`t`t`t`tpersona: request.persona,",
  "`t`t`t`t`t`ttoolFilter: request.toolFilter,",
  "`t`t`t`t`t`t...request.preset !== void 0 ? { preset: request.preset } : {}",
  "`t`t`t`t`t},"
)

# hunk 5: continuable bundle — async setup + recompose onto composition.preset.
# Same three-state handling as hunk 3 (raw → final, old-patch → final).
$hunk5OldRaw = @(
  "`t`tconst setup = (childCtx) => {",
  "`t`t`tif (create !== void 0) appendDelegatedPolicyOverrides(childCtx.agent.session, create.delegatedPolicies);",
  "`t`t`tapplyChildComposition(childCtx, parent, inputs.composition);",
  "`t`t`treturn this.setupRegistry.apply(childCtx);",
  "`t`t};"
)
$hunk5OldOld = @(
  "`t`tconst setup = async (childCtx) => {",
  "`t`t`tif (create !== void 0) appendDelegatedPolicyOverrides(childCtx.agent.session, create.delegatedPolicies);",
  "`t`t`tapplyChildComposition(childCtx, parent, inputs.composition);",
  "`t`t`tif (inputs.composition?.preset !== void 0) {",
  "`t`t`t`tawait childCtx.get(`"agentPresets`")?.recompose(childCtx, inputs.composition.preset);",
  "`t`t`t}",
  "`t`t`treturn this.setupRegistry.apply(childCtx);",
  "`t`t};"
)
$hunk5New = @(
  "`t`tconst setup = async (childCtx) => {",
  "`t`t`tif (create !== void 0) appendDelegatedPolicyOverrides(childCtx.agent.session, create.delegatedPolicies);",
  "`t`t`tapplyChildComposition(childCtx, parent, {",
  "`t`t`t`t// 同 driver：preset + persona 同给时跳过 deployment:persona 段，",
  "`t`t`t`t// recompose 后注册 delegation:role 段，与 preset 自身 persona 并存。",
  "`t`t`t`t...inputs.composition,",
  "`t`t`t`tpersona: inputs.composition?.persona !== void 0 && inputs.composition?.preset !== void 0 ? undefined : inputs.composition?.persona",
  "`t`t`t});",
  "`t`t`tif (inputs.composition?.preset !== void 0) {",
  "`t`t`t`tawait childCtx.get(`"agentPresets`")?.recompose(childCtx, inputs.composition.preset);",
  "`t`t`t`tif (inputs.composition?.persona !== void 0) {",
  "`t`t`t`t`tchildCtx.systemPrompt.section({",
  "`t`t`t`t`t`tname: `"delegation:role`",",
  "`t`t`t`t`t`torder: 1,",
  "`t`t`t`t`t`ttext: inputs.composition.persona",
  "`t`t`t`t`t});",
  "`t`t`t`t}",
  "`t`t`t}",
  "`t`t`treturn this.setupRegistry.apply(childCtx);",
  "`t`t};"
)

$applied = @()
$roots = Get-DshRoots
Write-Host "dsh roots found: $($roots -join ', ')"

foreach ($root in $roots) {
  # hunk 1 + hunk 3: in-process driver
  $f1 = Get-TargetFile $root '@deepseek-ai\dsh-subagent-in-process-driver\lib\index.js'
  if ($f1) {
    $bak = "$f1.bak_cwd"
    if (-not (Test-Path $bak)) { Copy-Item $f1 $bak; Write-Host "[bak] $bak" }
    Apply-Replace $f1 $hunk1Old $hunk1New '01-in-process-driver (cwd meta)'
    try { Apply-Replace $f1 $hunk3OldRaw $hunk3New '03-in-process-driver (preset recompose, raw)' }
    catch { Apply-Replace $f1 $hunk3OldOld $hunk3New '03-in-process-driver (preset recompose, upgrade)' }
    $applied += $f1
  }
  # hunk 2 + hunk 4 + hunk 5: subagent bundle
  $f2 = Get-TargetFile $root '@deepseek-ai\dsh-subagent\lib\index.js'
  if ($f2) {
    $bak = "$f2.bak_cwd_bundle"
    if (-not (Test-Path $bak)) { Copy-Item $f2 $bak; Write-Host "[bak] $bak" }
    Apply-Replace $f2 $hunk2Old $hunk2New '02-subagent-bundle (cwd meta)'
    Apply-Replace $f2 $hunk4Old $hunk4New '04-subagent-bundle (preset composition)'
    try { Apply-Replace $f2 $hunk5OldRaw $hunk5New '05-subagent-bundle (preset recompose, raw)' }
    catch { Apply-Replace $f2 $hunk5OldOld $hunk5New '05-subagent-bundle (preset recompose, upgrade)' }
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
Write-Host "  Select-String -Path `"$(Join-Path $roots[0] '@deepseek-ai\dsh-subagent\lib\index.js')`" -Pattern 'recompose'"
