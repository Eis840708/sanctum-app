#!/usr/bin/env bash
# CI analyze gate (DEV-P0-03 CI-automation). Enforces the project analyze
# baseline on the output of `flutter analyze`:
#
#   errors == 0   (absolute)
#   warnings <= 2 (pre-existing passwords_screen.dart tech debt)
#   infos    <= 162
#
# Vendored third-party source (lib/core/crypto/v3/vendor/**) is already excluded
# by analysis_options.yaml, so this operates directly on `flutter analyze`.
#
# Usage: flutter analyze 2>&1 | tee analyze.txt || true; bash tool/ci_check_analyze.sh analyze.txt
set -uo pipefail

OUT="${1:-analyze.txt}"
if [ ! -f "$OUT" ]; then
  echo "FAIL: analyze output '$OUT' not found"
  exit 2
fi

errors=$(grep -cE '(^|[[:space:]])error - ' "$OUT" || true)
warnings=$(grep -cE '(^|[[:space:]])warning - ' "$OUT" || true)
infos=$(grep -cE '(^|[[:space:]])info - ' "$OUT" || true)

echo "analyze severities: errors=$errors warnings=$warnings infos=$infos"
echo "baseline:           errors=0  warnings<=2  infos<=162"

status=0
if [ "$errors" -gt 0 ]; then echo "::error::analyze errors=$errors (must be 0)"; status=1; fi
if [ "$warnings" -gt 2 ]; then echo "::error::analyze warnings=$warnings (>2)"; status=1; fi
if [ "$infos" -gt 162 ]; then echo "::error::analyze infos=$infos (>162)"; status=1; fi

if [ "$status" -eq 0 ]; then
  echo "PASS: analyze within baseline"
else
  echo "FAIL: analyze exceeds baseline"
fi
exit "$status"
