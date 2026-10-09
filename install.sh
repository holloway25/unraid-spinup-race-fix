#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Stage and validate before changing files; restore prior files on failure.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"
PATCH="$HERE/patches/sdspin-45s-timeout.patch"
MD5S="$HERE/known-stock-md5s"
[[ -f $PATCH && -f $MD5S ]] || die "patch or known-stock-md5s missing"
command -v sg_raw >/dev/null || die "sg_raw not found (sg3_utils)"
command -v patch >/dev/null || die "patch utility not found"
[[ -f $SDSPIN && -f $GO ]] || die "sdspin or go file missing"
exec 9> "$ROOT/tmp/sdspin-race-fix.lock"
flock -n 9 || die "another installer/uninstaller is running"
CUR_MD5=$(hash_file "$SDSPIN")
if [[ -f $CUSTOM/sdspin.patched && $CUR_MD5 == $(hash_file "$CUSTOM/sdspin.patched") ]]; then
  [[ -f $CUSTOM/sdspin.stock ]] || die "already patched but stock backup missing"
  cp "$CUSTOM/sdspin.stock" "$WORK/stock"
  cp "$CUSTOM/sdspin.patched" "$WORK/patched"
else
  grep -q "^$CUR_MD5 " "$MD5S" || die "live sdspin hash ($CUR_MD5) is not a known stock version; nothing changed"
  cp "$SDSPIN" "$WORK/stock"
  cp "$WORK/stock" "$WORK/patched"
  patch --batch --forward -s "$WORK/patched" "$PATCH" || die "patch failed to apply; nothing changed"
fi
STOCK_MD5=$(hash_file "$WORK/stock")
grep -q "^$STOCK_MD5 " "$MD5S" || die "stock backup is not recognised"
bash -n "$WORK/stock"
bash -n "$WORK/patched"
PATCHED_MD5=$(hash_file "$WORK/patched")
strip_guard > "$WORK/go" || die "malformed or duplicate guard markers; nothing changed"
if grep -qF '/boot/config/custom/sdspin.patched' "$WORK/go"; then
  die "unmanaged/legacy sdspin guard found in go; review it before installing; nothing changed"
fi
cat >> "$WORK/go" <<GUARD
$MARK_BEGIN
# Only replace recognised stock with the verified patched file.
if ! command -v sg_raw >/dev/null; then
  logger -t sdspin-patch "SG_RAW MISSING - patch NOT applied, live script unchanged"
elif [[ "\$(md5sum '$SDSPIN' | cut -d' ' -f1)" != '$STOCK_MD5' ]]; then
  logger -t sdspin-patch "STOCK SDSPIN CHANGED - patch NOT applied, live script unchanged"
elif [[ ! -f '$CUSTOM/sdspin.patched' ]] || \\
     [[ "\$(md5sum '$CUSTOM/sdspin.patched' | cut -d' ' -f1)" != '$PATCHED_MD5' ]]; then
  logger -t sdspin-patch "PATCH FILE INVALID - patch NOT applied, live script unchanged"
elif (
  SDSPIN_BOOT_TMP=\$(mktemp '${SDSPIN%/*}/.sdspin.boot.XXXXXXXX') || exit 1
  trap 'rm -f -- "\$SDSPIN_BOOT_TMP"' EXIT
  install -m 0755 '$CUSTOM/sdspin.patched' "\$SDSPIN_BOOT_TMP" &&
    [[ "\$(md5sum "\$SDSPIN_BOOT_TMP" | cut -d' ' -f1)" == '$PATCHED_MD5' ]] &&
    mv -f -- "\$SDSPIN_BOOT_TMP" '$SDSPIN' &&
    [[ "\$(md5sum '$SDSPIN' | cut -d' ' -f1)" == '$PATCHED_MD5' ]]
); then
  logger -t sdspin-patch "patched sdspin installed (45s SG_IO timeout)"
else
  logger -t sdspin-patch "PATCH INSTALL FAILED - inspect live sdspin before relying on the fix"
fi
$MARK_END
GUARD
bash -n "$WORK/go"
[[ $(hash_file "$SDSPIN") == "$CUR_MD5" ]] || die "live script changed during preparation"
mkdir -p "$CUSTOM"
for target in "$CUSTOM/sdspin.stock" "$CUSTOM/sdspin.patched" "$GO" "$SDSPIN"; do
  save_target "$target"
done
install -m 0755 "$WORK/stock" "$CUSTOM/sdspin.stock"
install -m 0755 "$WORK/patched" "$CUSTOM/sdspin.patched"
cp "$WORK/go" "$GO"
install -m 0755 "$WORK/patched" "$SDSPIN"
[[ $(hash_file "$SDSPIN") == "$PATCHED_MD5" ]] || die "live verification failed"
COMMITTED=1
echo "Patch and boot guard installed; live hash verified."
if (( ! TEST_MODE )); then
  DEV=$(awk -F'"' '/^\[/{sec=$2} /^device=/ && sec!="flash" && $2 ~ /^sd[a-z]+$/ {print $2; exit}' /var/local/emhttp/disks.ini 2>/dev/null || true)
  if [[ -z $DEV ]]; then
    DEV=$(lsblk -dno NAME,TRAN,ROTA 2>/dev/null | awk '$2!="usb" && $3==1 {print $1; exit}' || true)
  fi
  if [[ -n $DEV ]]; then
    RC=0
    "$SDSPIN" "/dev/$DEV" status || RC=$?
    echo "Smoke test: sdspin $DEV status -> exit $RC (0=spun up, 2=standby, 1=error/unsupported)"
    if [[ $RC != 0 && $RC != 2 ]]; then
      echo "WARNING: status query failed; inspect the result before relying on the fix." >&2
    fi
  else
    echo "Smoke test skipped: no suitable disk found."
  fi
fi
echo "After every Unraid update: grep sdspin-patch /var/log/syslog"
