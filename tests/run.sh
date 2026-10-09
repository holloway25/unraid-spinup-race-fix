#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# All operations target a private /tmp sandbox; no disk/device commands run.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(mktemp -d /tmp/sdspin-tests.XXXXXXXX)
trap 'rm -rf -- "$ROOT"' EXIT
touch "$ROOT/.sdspin-test-root"
mkdir -p "$ROOT/usr/local/sbin" "$ROOT/boot/config/custom" "$ROOT/tmp" "$ROOT/bin"
export SDSPIN_TEST_ROOT="$ROOT"
export TEST_LOG="$ROOT/log"
export PATH="$ROOT/bin:$PATH"
REAL_INSTALL=$(command -v install)
export REAL_INSTALL
cat > "$ROOT/bin/sg_raw" <<'MOCK'
#!/bin/bash
echo 'ERROR: tests must not issue disk commands' >&2
exit 99
MOCK
cat > "$ROOT/bin/logger" <<'MOCK'
#!/bin/bash
echo "$*" >> "$TEST_LOG"
MOCK
cat > "$ROOT/bin/install" <<'MOCK'
#!/bin/bash
destination=${*: -1}
if [[ $destination == "$SDSPIN_TEST_ROOT/usr/local/sbin/sdspin" ]]; then
  echo 'FAIL: non-atomic write to live script' >&2
  exit 99
fi
if [[ ! -e $SDSPIN_TEST_ROOT/failure.used && ( ( ${FAIL_INSTALL:-0} == 1 && ( $destination == "$SDSPIN_TEST_ROOT/usr/local/sbin/.sdspin.replace."* || $destination == "$SDSPIN_TEST_ROOT/usr/local/sbin/.sdspin.boot."* ) ) || ( ${FAIL_GO:-0} == 1 && $destination == "$SDSPIN_TEST_ROOT/boot/config/.go.replace."* ) ) ]]; then
  touch "$SDSPIN_TEST_ROOT/failure.used"
  printf 'partial write\n' > "$destination"
  exit 1
fi
exec "$REAL_INSTALL" "$@"
MOCK
chmod +x "$ROOT/bin/"*

# Reconstruct the stock fixture from the old side of the distributed diff.
awk '/^---/ || /^\+\+\+/ || /^@@/ {next} /^ / || /^-/ {print substr($0,2)}' "$REPO/patches/sdspin-45s-timeout.patch" > "$ROOT/fixture"
STOCK=$(md5sum "$ROOT/fixture" | cut -d' ' -f1)
grep -q "^$STOCK " "$REPO/known-stock-md5s"
reset_files() {
  cp "$ROOT/fixture" "$ROOT/usr/local/sbin/sdspin"
  printf '#!/bin/bash\n# unrelated user configuration\n' > "$ROOT/boot/config/go"
  rm -f "$ROOT/boot/config/custom/sdspin."* "$ROOT/log" "$ROOT/failure.used"
}
expect_fail() {
  if "$@" > "$ROOT/output" 2>&1; then
    echo "FAIL: unexpectedly succeeded: $*" >&2
    exit 1
  fi
}
assert_stock() { cmp "$ROOT/fixture" "$ROOT/usr/local/sbin/sdspin"; }
assert_absent() {
  local rc
  if grep -q "$1" "$2"; then
    echo "FAIL: unexpected pattern '$1' in $2" >&2
    exit 1
  else
    rc=$?
    [[ $rc == 1 ]] || { echo "FAIL: grep could not inspect $2" >&2; exit 1; }
  fi
}
run_install() { bash "$REPO/install.sh" > "$ROOT/output" 2>&1; }
reset_files
run_install
PATCHED=$(md5sum "$ROOT/usr/local/sbin/sdspin" | cut -d' ' -f1)
[[ $PATCHED != "$STOCK" ]]
cp "$ROOT/boot/config/go" "$ROOT/go.installed"
run_install
cmp "$ROOT/go.installed" "$ROOT/boot/config/go"
echo 'PASS: install and idempotent reinstallation'

cp "$ROOT/fixture" "$ROOT/usr/local/sbin/sdspin"
bash "$ROOT/boot/config/go"
[[ $(md5sum "$ROOT/usr/local/sbin/sdspin" | cut -d' ' -f1) == "$PATCHED" ]]
grep -q 'patched sdspin installed' "$ROOT/log"
echo 'PASS: boot guard installs and verifies patch'

cp "$ROOT/fixture" "$ROOT/usr/local/sbin/sdspin"
rm -f "$ROOT/log"
FAIL_INSTALL=1 bash "$ROOT/boot/config/go"
assert_stock
grep -q 'PATCH INSTALL FAILED' "$ROOT/log"
assert_absent 'patched sdspin installed' "$ROOT/log"
echo 'PASS: boot guard never reports success on failed copy'

printf '# changed patch\n' >> "$ROOT/boot/config/custom/sdspin.patched"
rm -f "$ROOT/log"
bash "$ROOT/boot/config/go"
assert_stock
grep -q 'PATCH FILE INVALID' "$ROOT/log"
echo 'PASS: corrupt patch rejected'

reset_files
run_install
cp "$ROOT/fixture" "$ROOT/usr/local/sbin/sdspin"
rm "$ROOT/boot/config/custom/sdspin.patched"
rm -f "$ROOT/log"
bash "$ROOT/boot/config/go"
assert_stock
grep -q 'PATCH FILE INVALID' "$ROOT/log"
echo 'PASS: missing patch leaves stock untouched'

reset_files
FAIL_INSTALL=1 expect_fail bash "$REPO/install.sh"
assert_stock
assert_absent 'guard (unraid' "$ROOT/boot/config/go"
[[ ! -e $ROOT/boot/config/custom/sdspin.stock && ! -e $ROOT/boot/config/custom/sdspin.patched ]]
echo 'PASS: failed installation rolls back all target files'

reset_files
run_install
cp "$ROOT/usr/local/sbin/sdspin" "$ROOT/live.before"
cp "$ROOT/boot/config/go" "$ROOT/go.before"
cp "$ROOT/boot/config/custom/sdspin.stock" "$ROOT/stock.before"
FAIL_INSTALL=1 expect_fail bash "$REPO/install.sh"
cmp "$ROOT/live.before" "$ROOT/usr/local/sbin/sdspin"
cmp "$ROOT/go.before" "$ROOT/boot/config/go"
cmp "$ROOT/stock.before" "$ROOT/boot/config/custom/sdspin.stock"
echo 'PASS: failed repeat installation preserves existing installation'

reset_files
printf '# unknown upstream\n' >> "$ROOT/usr/local/sbin/sdspin"
cp "$ROOT/usr/local/sbin/sdspin" "$ROOT/unknown"
expect_fail bash "$REPO/install.sh"
cmp "$ROOT/unknown" "$ROOT/usr/local/sbin/sdspin"
echo 'PASS: unknown stock refused without changes'

reset_files
run_install
printf '# newer upstream script\n' > "$ROOT/usr/local/sbin/sdspin"
cp "$ROOT/usr/local/sbin/sdspin" "$ROOT/newer"
rm -f "$ROOT/log"
bash "$ROOT/boot/config/go"
cmp "$ROOT/newer" "$ROOT/usr/local/sbin/sdspin"
grep -q 'STOCK SDSPIN CHANGED' "$ROOT/log"
bash "$REPO/uninstall.sh" > "$ROOT/output"
cmp "$ROOT/newer" "$ROOT/usr/local/sbin/sdspin"
assert_absent 'guard (unraid' "$ROOT/boot/config/go"
echo 'PASS: changed upstream preserved at boot and uninstall'

reset_files
run_install
bash "$REPO/uninstall.sh" > "$ROOT/output"
assert_stock
assert_absent 'guard (unraid' "$ROOT/boot/config/go"
echo 'PASS: normal uninstall restores verified stock'

reset_files
run_install
cp "$ROOT/usr/local/sbin/sdspin" "$ROOT/live.before"
cp "$ROOT/boot/config/go" "$ROOT/go.before"
FAIL_GO=1 expect_fail bash "$REPO/uninstall.sh"
cmp "$ROOT/live.before" "$ROOT/usr/local/sbin/sdspin"
cmp "$ROOT/go.before" "$ROOT/boot/config/go"
echo 'PASS: failed uninstall atomically rolls back live script and guard'

reset_files
run_install
rm "$ROOT/boot/config/custom/sdspin.stock"
cp "$ROOT/boot/config/go" "$ROOT/go.before"
expect_fail bash "$REPO/uninstall.sh"
cmp "$ROOT/go.before" "$ROOT/boot/config/go"
[[ $(md5sum "$ROOT/usr/local/sbin/sdspin" | cut -d' ' -f1) == "$PATCHED" ]]
echo 'PASS: missing stock backup refuses unsafe rollback'

reset_files
run_install
printf '# corrupted stock backup\n' >> "$ROOT/boot/config/custom/sdspin.stock"
cp "$ROOT/boot/config/go" "$ROOT/go.before"
expect_fail bash "$REPO/uninstall.sh"
cmp "$ROOT/go.before" "$ROOT/boot/config/go"
[[ $(md5sum "$ROOT/usr/local/sbin/sdspin" | cut -d' ' -f1) == "$PATCHED" ]]
echo 'PASS: corrupt stock backup refuses unsafe rollback'

reset_files
printf '%s\n' '# --- sdspin-patch guard (unraid-spinup-race-fix) BEGIN ---' >> "$ROOT/boot/config/go"
cp "$ROOT/boot/config/go" "$ROOT/go.before"
expect_fail bash "$REPO/install.sh"
cmp "$ROOT/go.before" "$ROOT/boot/config/go"
assert_stock
echo 'PASS: malformed guard refused without losing user configuration'
reset_files
printf '%s\n' 'install -m 0755 /boot/config/custom/sdspin.patched /usr/local/sbin/sdspin' >> "$ROOT/boot/config/go"
cp "$ROOT/boot/config/go" "$ROOT/go.before"
expect_fail bash "$REPO/install.sh"
expect_fail bash "$REPO/uninstall.sh"
cmp "$ROOT/go.before" "$ROOT/boot/config/go"
assert_stock
echo 'PASS: legacy manual guard refused rather than duplicated or silently retained'

reset_files
printf 'printf "service startup\\n" >> "$TEST_LOG"\nexit 0\n' >> "$ROOT/boot/config/go"
run_install
cp "$ROOT/fixture" "$ROOT/usr/local/sbin/sdspin"
bash "$ROOT/boot/config/go"
[[ $(md5sum "$ROOT/usr/local/sbin/sdspin" | cut -d' ' -f1) == "$PATCHED" ]]
[[ $(head -n 1 "$ROOT/log") == *'patched sdspin installed'* ]]
grep -q 'service startup' "$ROOT/log"
echo 'PASS: guard runs before service startup and trailing exit'

reset_files
printf '#!/bin/sh\nexit 0\n' > "$ROOT/boot/config/go"
cp "$ROOT/boot/config/go" "$ROOT/go.before"
expect_fail bash "$REPO/install.sh"
cmp "$ROOT/go.before" "$ROOT/boot/config/go"
assert_stock
echo 'PASS: unsupported go layout refused explicitly'

# Emulate pulling a newer repository without touching the checkout under test.
reset_files
run_install
mkdir -p "$ROOT/new-repo/lib" "$ROOT/new-repo/patches"
cp "$REPO/install.sh" "$REPO/known-stock-md5s" "$ROOT/new-repo/"
cp "$REPO/lib/common.sh" "$ROOT/new-repo/lib/"
sed 's/+# PATCHED:/+# UPDATED PATCH:/' "$REPO/patches/sdspin-45s-timeout.patch" > "$ROOT/new-repo/patches/sdspin-45s-timeout.patch"
bash "$ROOT/new-repo/install.sh" > "$ROOT/output"
grep -q '# UPDATED PATCH:' "$ROOT/usr/local/sbin/sdspin"
echo 'PASS: reinstallation rebuilds from the current repository patch'
cp "$ROOT/usr/local/sbin/sdspin" "$ROOT/live.before"
cp "$ROOT/boot/config/go" "$ROOT/go.before"
printf 'invalid patch\n' > "$ROOT/new-repo/patches/sdspin-45s-timeout.patch"
expect_fail bash "$ROOT/new-repo/install.sh"
cmp "$ROOT/live.before" "$ROOT/usr/local/sbin/sdspin"
cmp "$ROOT/go.before" "$ROOT/boot/config/go"
echo 'PASS: invalid updated patch fails without changing existing installation'

# Only replace the absolute command path in the sandbox copy of the patch.
reset_files
run_install
sed "s#/usr/bin/sg_raw#$ROOT/bin/sg_raw#g" "$ROOT/usr/local/sbin/sdspin" > "$ROOT/ata-script"
cat > "$ROOT/bin/sg_raw" <<'MOCK'
#!/bin/bash
printf '%s\n' "$ATA_OUTPUT" >&2
exit "$ATA_RC"
MOCK
ata_case() {
  local rc=0
  export ATA_RC=$1 ATA_OUTPUT=$2
  bash "$ROOT/ata-script" ignored "$3" || rc=$?
  if [[ $rc != "$4" ]]; then
    echo "FAIL: ATA case $5 returned $rc, expected $4" >&2
    exit 1
  fi
}
for branch in up status; do
  ata_case 11 'error=0x4 count=0xff status=0x51' "$branch" 1 'aborted with error descriptor'
  ata_case 11 'error=0x4 count=0x0 status=0x51' "$branch" 1 'aborted standby count'
  ata_case 33 'error=0x0 count=0xff status=0x50' "$branch" 1 'timeout with clean-looking descriptor'
  ata_case 0 'error=0x4 count=0xff status=0x50' "$branch" 1 'nonzero error register'
  for status in 51 70 d0 58; do
    ata_case 0 "error=0x0 count=0xff status=0x$status" "$branch" 1 'ERR/DF/BSY/DRQ status'
  done
  ata_case 0 'count=0xff status=0x50' "$branch" 1 'missing error register'
  ata_case 0 'error=0x0 count=0xff' "$branch" 1 'missing status register'
  ata_case 0 'error=0x0 count=0xff status=0x500' "$branch" 1 'oversized status register'
  ata_case 21 'error=0x0 count=0xff status=0x50' "$branch" 1 'unrelated recovered sense'
  ata_case 0 'error=0x0 count=0xff status=0x50' "$branch" 0 'clean completion'
  for sense_rc in 20 21; do
    ata_case "$sense_rc" 'ATA pass through information available
error=0x0 count=0xff status=0x50' "$branch" 0 'successful CK_COND descriptor'
  done
done
for count in 0 1; do
  ata_case 21 "ATA pass through information available
error=0x0 count=0x$count status=0x50" status 2 'valid standby response'
done
for count in 40 41 80 81 82 ff; do
  ata_case 21 "ATA pass through information available
error=0x0 count=0x$count status=0x50" status 0 'valid spun-up response'
done
ata_case 0 'error=0x0 status=0x50' status 1 'missing power-state count'
ata_case 0 'error=0x0 count=0x10000 status=0x50' status 1 'oversized power-state count'
echo 'PASS: ATA error/status/exit-code matrix (40 cases), including successful CK_COND'
echo 'All sandbox tests passed; no live server or disk commands used.'
