#!/usr/bin/env bash
# install.sh — apply the two in-process provider patches required by the `cwd`
# AND `preset` parameters of dsh-subagent-cwd (foreground + continuable paths).
#
# Usage:  ./install.sh
#
# Locates the target packages under the dsh install and DSH_HOME profiles,
# backs them up (first run only), applies all five hunks idempotently (raw and
# old-patch states both upgrade to the final text), and runs `node --check`.
# Safe to re-run. Uninstall: ./uninstall.sh
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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTS=()
if [[ -d "$SCRIPT_DIR/../../../dsh" ]]; then ROOTS+=("$SCRIPT_DIR/../../../dsh"); fi
if [[ -d "$SCRIPT_DIR/../../../dsh_home" ]]; then
  for d in "$SCRIPT_DIR/../../../dsh_home"/profiles/*/; do
    [[ -d "$d" ]] && ROOTS+=("${d%/}")
  done
fi

HUNK1_OLD='		meta: childSessionMeta(parent, childDepth, activationBoundary),'
HUNK1_NEW=$'		meta: {\n			...childSessionMeta(parent, childDepth, activationBoundary),\n			...request.cwd !== void 0 ? { cwd: request.cwd } : {}\n		},'
HUNK2_OLD='						meta: childSessionMeta(parent, childDepth, lineageSeedLength),'
HUNK2_NEW=$'						meta: {\n							...childSessionMeta(parent, childDepth, lineageSeedLength),\n							...request.cwd !== void 0 ? { cwd: request.cwd } : {}\n						},'

HUNK3_OLD_RAW=$'\tconst setup = (childCtx) => {\n\t\tappendDelegatedPolicyOverrides(childCtx.agent.session, inherited);\n\t\tapplyChildComposition(childCtx, parent, {\n\t\t\tpersona: request.persona,\n\t\t\ttoolFilter: request.toolFilter\n\t\t});\n\t\tif (request.outputSchema !== void 0) structured = attachStructuredRuntime(childCtx, request.outputSchema);\n\t\tattachDescriptorAppend(childCtx, request.descriptor);\n\t};'
HUNK3_OLD_OLD=$'\tconst setup = async (childCtx) => {\n\t\tappendDelegatedPolicyOverrides(childCtx.agent.session, inherited);\n\t\tapplyChildComposition(childCtx, parent, {\n\t\t\tpersona: request.persona,\n\t\t\ttoolFilter: request.toolFilter\n\t\t});\n\t\tif (request.preset !== void 0) {\n\t\t\tawait childCtx.get("agentPresets")?.recompose(childCtx, request.preset);\n\t\t}\n\t\tif (request.outputSchema !== void 0) structured = attachStructuredRuntime(childCtx, request.outputSchema);\n\t\tattachDescriptorAppend(childCtx, request.descriptor);\n\t};'
HUNK3_NEW=$'\tconst setup = async (childCtx) => {\n\t\tappendDelegatedPolicyOverrides(childCtx.agent.session, inherited);\n\t\tapplyChildComposition(childCtx, parent, {\n\t\t\t// persona + preset 同给时先跳过默认 deployment:persona 段：目标 preset 的\n\t\t\t// router-bootstrap 类插件会按名删除 persona 段，改在 recompose 之后注册\n\t\t\t// 不含 "persona" 字样的 delegation:role 段，与 preset 自身 persona 并存。\n\t\t\tpersona: request.persona !== void 0 && request.preset !== void 0 ? undefined : request.persona,\n\t\t\ttoolFilter: request.toolFilter\n\t\t});\n\t\tif (request.preset !== void 0) {\n\t\t\tawait childCtx.get("agentPresets")?.recompose(childCtx, request.preset);\n\t\t\tif (request.persona !== void 0) {\n\t\t\t\tchildCtx.systemPrompt.section({\n\t\t\t\t\tname: "delegation:role",\n\t\t\t\t\torder: 1,\n\t\t\t\t\ttext: request.persona\n\t\t\t\t});\n\t\t\t}\n\t\t}\n\t\tif (request.outputSchema !== void 0) structured = attachStructuredRuntime(childCtx, request.outputSchema);\n\t\tattachDescriptorAppend(childCtx, request.descriptor);\n\t};'

HUNK4_OLD=$'\t\t\t\t\tcomposition: {\n\t\t\t\t\t\tpersona: request.persona,\n\t\t\t\t\t\ttoolFilter: request.toolFilter\n\t\t\t\t\t},'
HUNK4_NEW=$'\t\t\t\t\tcomposition: {\n\t\t\t\t\t\tpersona: request.persona,\n\t\t\t\t\t\ttoolFilter: request.toolFilter,\n\t\t\t\t\t\t...(request.preset !== void 0 ? { preset: request.preset } : {})\n\t\t\t\t\t},'

HUNK5_OLD_RAW=$'\t\tconst setup = (childCtx) => {\n\t\t\tif (create !== void 0) appendDelegatedPolicyOverrides(childCtx.agent.session, create.delegatedPolicies);\n\t\t\tapplyChildComposition(childCtx, parent, inputs.composition);\n\t\t\treturn this.setupRegistry.apply(childCtx);\n\t\t};'
HUNK5_OLD_OLD=$'\t\tconst setup = async (childCtx) => {\n\t\t\tif (create !== void 0) appendDelegatedPolicyOverrides(childCtx.agent.session, create.delegatedPolicies);\n\t\t\tapplyChildComposition(childCtx, parent, inputs.composition);\n\t\t\tif (inputs.composition?.preset !== void 0) {\n\t\t\t\tawait childCtx.get("agentPresets")?.recompose(childCtx, inputs.composition.preset);\n\t\t\t}\n\t\t\treturn this.setupRegistry.apply(childCtx);\n\t\t};'
HUNK5_NEW=$'\t\tconst setup = async (childCtx) => {\n\t\t\tif (create !== void 0) appendDelegatedPolicyOverrides(childCtx.agent.session, create.delegatedPolicies);\n\t\t\tapplyChildComposition(childCtx, parent, {\n\t\t\t\t// 同 driver：preset + persona 同给时跳过 deployment:persona 段，\n\t\t\t\t// recompose 后注册 delegation:role 段，与 preset 自身 persona 并存。\n\t\t\t\t...inputs.composition,\n\t\t\t\tpersona: inputs.composition?.persona !== void 0 && inputs.composition?.preset !== void 0 ? undefined : inputs.composition?.persona\n\t\t\t});\n\t\t\tif (inputs.composition?.preset !== void 0) {\n\t\t\t\tawait childCtx.get("agentPresets")?.recompose(childCtx, inputs.composition.preset);\n\t\t\t\tif (inputs.composition?.persona !== void 0) {\n\t\t\t\t\tchildCtx.systemPrompt.section({\n\t\t\t\t\t\tname: "delegation:role",\n\t\t\t\t\t\torder: 1,\n\t\t\t\t\t\ttext: inputs.composition.persona\n\t\t\t\t\t});\n\t\t\t\t}\n\t\t\t}\n\t\t\treturn this.setupRegistry.apply(childCtx);\n\t\t};'

apply_replace() {
  local path="$1" old="$2" new="$3" label="$4"
  if ! grep -qF -- "$new" "$path"; then
    if ! grep -qF -- "$old" "$path"; then
      echo "[ERROR] $label anchor not found in $path — version mismatch? Refusing to patch blindly." >&2
      exit 1
    fi
    python3 - "$path" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()
if old not in content:
    print(f'[ERROR] anchor missing in {path}', file=sys.stderr)
    sys.exit(1)
content = content.replace(old, new, 1)
with open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(content)
PY
    echo "[ok]   patched: $path"
  else
    echo "[skip] already patched: $path"
  fi
}

is_final() {
  grep -qF 'delegation:role' "$1" && grep -qF 'request.cwd' "$1"
}

APPLIED=()
for root in "${ROOTS[@]}"; do
  f1="$root/@deepseek-ai/dsh-subagent-in-process-driver/lib/index.js"
  if [[ -f "$f1" ]]; then
    if is_final "$f1"; then
      echo "[skip] in-process-driver already patched (FINAL): $f1"
    else
      [[ -f "$f1.bak_cwd" ]] || { cp "$f1" "$f1.bak_cwd"; echo "[bak] $f1.bak_cwd"; }
      apply_replace "$f1" "$HUNK1_OLD" "$HUNK1_NEW" "01-in-process-driver"
      if grep -qF -- "$HUNK3_OLD_RAW" "$f1"; then
        apply_replace "$f1" "$HUNK3_OLD_RAW" "$HUNK3_NEW" "03-in-process-driver (raw)"
      elif grep -qF -- "$HUNK3_OLD_OLD" "$f1"; then
        apply_replace "$f1" "$HUNK3_OLD_OLD" "$HUNK3_NEW" "03-in-process-driver (upgrade)"
      else
        echo "[ERROR] 03 anchor not found (neither raw nor old-patch state) in $f1" >&2
        exit 1
      fi
    fi
    APPLIED+=("$f1")
  fi
  f2="$root/@deepseek-ai/dsh-subagent/lib/index.js"
  if [[ -f "$f2" ]]; then
    if is_final "$f2"; then
      echo "[skip] subagent bundle already patched (FINAL): $f2"
    else
      [[ -f "$f2.bak_cwd_bundle" ]] || { cp "$f2" "$f2.bak_cwd_bundle"; echo "[bak] $f2.bak_cwd_bundle"; }
      apply_replace "$f2" "$HUNK2_OLD" "$HUNK2_NEW" "02-subagent-bundle"
      apply_replace "$f2" "$HUNK4_OLD" "$HUNK4_NEW" "04-subagent-bundle (preset composition)"
      if grep -qF -- "$HUNK5_OLD_RAW" "$f2"; then
        apply_replace "$f2" "$HUNK5_OLD_RAW" "$HUNK5_NEW" "05-subagent-bundle (raw)"
      elif grep -qF -- "$HUNK5_OLD_OLD" "$f2"; then
        apply_replace "$f2" "$HUNK5_OLD_OLD" "$HUNK5_NEW" "05-subagent-bundle (upgrade)"
      else
        echo "[ERROR] 05 anchor not found (neither raw nor old-patch state) in $f2" >&2
        exit 1
      fi
    fi
    APPLIED+=("$f2")
  fi
done

if [[ ${#APPLIED[@]} -eq 0 ]]; then
  echo "[warn] No target package files found." >&2
  exit 1
fi

echo ""
echo "Verifying syntax..."
for f in $(printf '%s\n' "${APPLIED[@]}" | sort -u); do
  node --check "$f"
  echo "[ok] node --check passed: $f"
done

echo ""
echo "Done. Restart \`dsh --profile web\` for the patches to take effect."
echo "Verify the continuable patch landed in the BUNDLE:"
echo "  grep -c 'request.cwd' \"${ROOTS[0]}/@deepseek-ai/dsh-subagent/lib/index.js\""
