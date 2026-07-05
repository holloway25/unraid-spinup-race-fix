#!/bin/bash
# unraid-spinup-race-fix installer
# https://github.com/holloway25/unraid-spinup-race-fix
#
# - Verifies your /usr/local/sbin/sdspin is a known-stock version (md5)
# - Backs it up to /boot/config/custom/sdspin.stock
# - Applies patches/sdspin-45s-timeout.patch -> /boot/config/custom/sdspin.patched
# - Installs the patched script live
# - Adds a boot guard to /boot/config/go (the live copy lives in a ramdisk
#   and is rebuilt stock at every boot; the guard re-applies the patch,
#   and refuses + logs if an Unraid update shipped a different sdspin)
#
# Safe to re-run. Rollback: uninstall.sh (or see README).

set -euo pipefail

SDSPIN=/usr/local/sbin/sdspin
CUSTOM=/boot/config/custom
GO=/boot/config/go
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/patches/sdspin-45s-timeout.patch"
MD5S="$HERE/known-stock-md5s"
MARK_BEGIN="# --- sdspin-patch guard (unraid-spinup-race-fix) BEGIN ---"
MARK_END="# --- sdspin-patch guard (unraid-spinup-race-fix) END ---"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
[[ -f $PATCH ]] || die "patch file not found: $PATCH"
[[ -f $MD5S ]] || die "known-stock-md5s not found"
command -v sg_raw >/dev/null || die "sg_raw not found (sg3_utils) - cannot install"
command -v patch >/dev/null || die "'patch' utility not found - cannot install"
[[ -f $SDSPIN ]] || die "$SDSPIN not found - is this Unraid 6.9+?"

CUR_MD5=$(md5sum "$SDSPIN" | cut -d' ' -f1)

# Already patched and current?
if [[ -f $CUSTOM/sdspin.patched ]] && \
   [[ $CUR_MD5 == $(md5sum "$CUSTOM/sdspin.patched" | cut -d' ' -f1) ]]; then
  echo "Live sdspin already matches sdspin.patched - refreshing guard only."
else
  # Verify the live script is a known-stock version before touching anything
  grep -q "^$CUR_MD5 " "$MD5S" || die "live sdspin md5 ($CUR_MD5) is not a known stock version.
This Unraid release ships an sdspin this patch has not been validated against.
Please open an issue with your Unraid version and the output of: cat $SDSPIN"

  mkdir -p "$CUSTOM"
  cp -f "$SDSPIN" "$CUSTOM/sdspin.stock"
  echo "Stock sdspin backed up to $CUSTOM/sdspin.stock"

  cp -f "$CUSTOM/sdspin.stock" /tmp/sdspin.patchwork
  patch -s /tmp/sdspin.patchwork "$PATCH" || die "patch failed to apply"
  install -m 0755 /tmp/sdspin.patchwork "$CUSTOM/sdspin.patched"
  rm -f /tmp/sdspin.patchwork
  install -m 0755 "$CUSTOM/sdspin.patched" "$SDSPIN"
  echo "Patched sdspin installed live."
fi

STOCK_MD5=$(md5sum "$CUSTOM/sdspin.stock" | cut -d' ' -f1)

# (Re)write the go-file guard idempotently
TMP=$(mktemp)
sed "/^${MARK_BEGIN}$/,/^${MARK_END}$/d" "$GO" > "$TMP"
cat >> "$TMP" << GUARD
$MARK_BEGIN
# Re-applies the sdspin spin-up-race patch each boot (live copy is ramdisk).
# If an Unraid update ships a different sdspin, runs STOCK and logs a warning.
if command -v sg_raw >/dev/null && \\
   [[ "\$(md5sum /usr/local/sbin/sdspin | cut -d' ' -f1)" == "$STOCK_MD5" ]]; then
  install -m 0755 $CUSTOM/sdspin.patched /usr/local/sbin/sdspin
  logger -t sdspin-patch "patched sdspin installed (45s SG_IO timeout)"
else
  logger -t sdspin-patch "STOCK SDSPIN CHANGED or sg_raw missing - patch NOT applied, running stock"
fi
$MARK_END
GUARD
cp -f "$TMP" "$GO"; rm -f "$TMP"
echo "Boot guard installed in $GO"

# Smoke test against the first array device present
DEV=$(ls /dev/sd? 2>/dev/null | head -1)
if [[ -n ${DEV:-} ]]; then
  set +e; "$SDSPIN" "$DEV" status; RC=$?; set -e
  echo "Smoke test: sdspin ${DEV#/dev/} status -> exit $RC (0=spun up, 2=standby, 1=unsupported)"
fi
echo "Done. After every Unraid update: grep sdspin-patch /var/log/syslog"
