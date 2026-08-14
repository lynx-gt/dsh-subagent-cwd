#!/usr/bin/env bash
# install.sh — apply the two in-process provider patches required by the `cwd`
# parameter of dsh-subagent-cwd.
#
# Usage:  ./install.sh
#
# Locates the target packages under the dsh install and DSH_HOME profiles,
# backs them up, applies both hunks idempotently, and runs `node --check`.
# Safe to re-run. Uninstall: ./uninstall.sh

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

APPLIED=()
for root in "${ROOTS[@]}"; do
  f1="$root/@deepseek-ai/dsh-subagent-in-process-driver/lib/index.js"
  if [[ -f "$f1" ]]; then
    [[ -f "$f1.bak_cwd" ]] || { cp "$f1" "$f1.bak_cwd"; echo "[bak] $f1.bak_cwd"; }
    apply_replace "$f1" "$HUNK1_OLD" "$HUNK1_NEW" "01-in-process-driver"
    APPLIED+=("$f1")
  fi
  f2="$root/@deepseek-ai/dsh-subagent/lib/index.js"
  if [[ -f "$f2" ]]; then
    [[ -f "$f2.bak_cwd_bundle" ]] || { cp "$f2" "$f2.bak_cwd_bundle"; echo "[bak] $f2.bak_cwd_bundle"; }
    apply_replace "$f2" "$HUNK2_OLD" "$HUNK2_NEW" "02-subagent-bundle"
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
