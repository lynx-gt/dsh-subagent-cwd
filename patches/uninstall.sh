#!/usr/bin/env bash
# uninstall.sh — revert the two in-process provider patches applied by install.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTS=()
if [[ -d "$SCRIPT_DIR/../../../dsh" ]]; then ROOTS+=("$SCRIPT_DIR/../../../dsh"); fi
if [[ -d "$SCRIPT_DIR/../../../dsh_home" ]]; then
  for d in "$SCRIPT_DIR/../../../dsh_home"/profiles/*/; do
    [[ -d "$d" ]] && ROOTS+=("${d%/}")
  done
fi

RESTORED=0
for root in "${ROOTS[@]}"; do
  for rel in "@deepseek-ai/dsh-subagent-in-process-driver/lib/index.js" "@deepseek-ai/dsh-subagent/lib/index.js"; do
    target="$root/$rel"
    [[ -f "$target" ]] || continue
    bak="$target.bak_cwd"
    [[ -f "$bak" ]] || bak="$target.bak_cwd_bundle"
    if [[ -f "$bak" ]]; then
      cp "$bak" "$target"
      echo "[ok] restored $target from $(basename "$bak")"
      RESTORED=1
    else
      echo "[skip] no backup for $target"
    fi
  done
done

if [[ "$RESTORED" -eq 0 ]]; then
  echo "[info] nothing to restore."
  exit 0
fi
echo ""
echo "Done. Restart \`dsh --profile web\` for the reverted files to take effect."
