#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Never replace a different live script with a potentially stale stock backup.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"
[[ -f $GO && -f $SDSPIN ]] || die "go or live sdspin missing"
exec 9> "$ROOT/tmp/sdspin-race-fix.lock"
flock -n 9 || die "another installer/uninstaller is running"
strip_guard > "$WORK/go" || die "malformed guard markers; nothing changed"
if grep -qF '/boot/config/custom/sdspin.patched' "$WORK/go"; then
  die "unmanaged/legacy sdspin guard found in go; review it before uninstalling; nothing changed"
fi
bash -n "$WORK/go"
RESTORE=0
if [[ -f $CUSTOM/sdspin.patched && $(hash_file "$SDSPIN") == $(hash_file "$CUSTOM/sdspin.patched") ]]; then
  [[ -f $CUSTOM/sdspin.stock ]] || die "live is patched but stock backup missing; nothing changed"
  STOCK_MD5=$(hash_file "$CUSTOM/sdspin.stock")
  grep -q "^$STOCK_MD5 " "$HERE/known-stock-md5s" || die "stock backup is not recognised; nothing changed"
  bash -n "$CUSTOM/sdspin.stock"
  RESTORE=1
fi
save_target "$GO"
if (( RESTORE )); then
  save_target "$SDSPIN"
  install -m 0755 "$CUSTOM/sdspin.stock" "$SDSPIN"
  [[ $(hash_file "$SDSPIN") == "$STOCK_MD5" ]] || die "stock restore verification failed"
fi
cp "$WORK/go" "$GO"
COMMITTED=1
if (( RESTORE )); then
  echo "Saved stock sdspin restored and verified; boot guard removed."
else
  echo "Live sdspin does not match the saved patch; left unchanged (it may be newer upstream stock). Boot guard removed."
fi
echo "Saved patch/stock files retained. Remove the optional notification script if retiring this fix."
