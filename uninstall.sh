#!/bin/bash
# unraid-spinup-race-fix uninstaller
# Restores stock sdspin immediately (no reboot needed) and removes the boot guard.
set -euo pipefail

SDSPIN=/usr/local/sbin/sdspin
CUSTOM=/boot/config/custom
GO=/boot/config/go
MARK_BEGIN="# --- sdspin-patch guard (unraid-spinup-race-fix) BEGIN ---"
MARK_END="# --- sdspin-patch guard (unraid-spinup-race-fix) END ---"

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }

if [[ -f $CUSTOM/sdspin.stock ]]; then
  install -m 0755 "$CUSTOM/sdspin.stock" "$SDSPIN"
  echo "Stock sdspin restored live."
else
  echo "WARNING: $CUSTOM/sdspin.stock not found - live sdspin left as-is." >&2
  echo "(A reboot will restore stock anyway once the guard is removed.)" >&2
fi

if grep -q "^${MARK_BEGIN}$" "$GO"; then
  TMP=$(mktemp)
  sed "/^${MARK_BEGIN}$/,/^${MARK_END}$/d" "$GO" > "$TMP"
  cp -f "$TMP" "$GO"; rm -f "$TMP"
  echo "Boot guard removed from $GO"
else
  echo "No boot guard found in $GO (nothing to remove)."
fi

echo "Optional cleanup: rm $CUSTOM/sdspin.patched $CUSTOM/sdspin.stock"
echo "Done."
