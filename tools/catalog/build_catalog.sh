#!/usr/bin/env bash
#
# Catalog asset pipeline orchestrator.
#
#   raw mesh (gltf/glb/fbx/obj)
#     --[Blender: import + Y-up + uniform-normalize + aspect report]--> .usdc
#     --[usdzip --arkitAsset]--> .usdz
#     --[usdchecker --arkit (EXIT CODE, not stdout — it prints benign noise)]--> validated
#
# Usage:
#   ./build_catalog.sh <raw-dir> <out-dir> <source-key>
# Example (validated synthetic path, no downloads):
#   ./build_catalog.sh test/raw test/out _test
#
set -euo pipefail

BLENDER="/Applications/Blender.app/Contents/MacOS/Blender"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: $0 <raw-dir> <out-dir> <source-key>" >&2; exit 2; }
RAW="${1:-}"; OUT="${2:-}"; SRC="${3:-}"
[ -n "$RAW" ] && [ -n "$OUT" ] && [ -n "$SRC" ] || usage
[ -x "$BLENDER" ] || { echo "error: Blender not found at $BLENDER" >&2; exit 1; }

mkdir -p "$OUT"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPORT="$OUT/report.json"

echo "==> [1/3] Blender: import + Y-up + uniform-normalize + aspect report"
"$BLENDER" --background --factory-startup --python "$HERE/convert_to_usdz.py" -- \
  --in "$RAW" --out "$WORK" --source "$SRC" \
  --sources "$HERE/sources.json" --report "$REPORT" \
  2>&1 | grep -iE "^OK|^SKIP|^WROTE|error|Traceback" || true

echo "==> [2/3] usdzip --arkitAsset   [3/3] usdchecker --arkit"
pass=0; fail=0
shopt -s nullglob
for usd in "$WORK"/*.usdc "$WORK"/*.usd; do
  base="$(basename "${usd%.*}")"
  out="$OUT/$base.usdz"

  if ! /usr/bin/usdzip "$out" --arkitAsset "$usd" >/dev/null 2>&1; then
    echo "  FAIL package          $base"; fail=$((fail + 1)); continue
  fi

  # Gate on exit code only. usdchecker emits a harmless "Coding Error" line even
  # when the asset passes, so a text match would false-fail every model.
  if check_out="$(/usr/bin/usdchecker --arkit "$out" 2>&1)"; then
    echo "  PASS  $base.usdz"; pass=$((pass + 1))
  else
    echo "  FAIL arkit-compliance $base.usdz"
    echo "$check_out" | sed 's/^/        /'
    fail=$((fail + 1))
  fi
done

echo ""
echo "==> $pass passed, $fail failed. USDZ -> $OUT/   report -> $REPORT"
echo "    next: tools/catalog/validate_assignments.py to guard aspect-ratio pairing"
[ "$fail" -eq 0 ]
