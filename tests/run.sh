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
if [[ ${FAIL_INSTALL:-0} == 1 && ( ${*: -1} == "$SDSPIN_TEST_ROOT/usr/local/sbin/sdspin" || ${*: -1} == "$SDSPIN_TEST_ROOT/usr/local/sbin/.sdspin.boot."* ) ]]; then
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
  rm -f "$ROOT/boot/config/custom/sdspin."* "$ROOT/log"
}
expect_fail() {
  if "$@" > "$ROOT/output" 2>&1; then
    echo "FAIL: unexpectedly succeeded: $*" >&2
    exit 1
  fi
}
assert_stock() { cmp "$ROOT/fixture" "$ROOT/usr/local/sbin/sdspin"; }
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
! grep -q 'patched sdspin installed' "$ROOT/log"
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
! grep -q 'guard (unraid' "$ROOT/boot/config/go"
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
! grep -q 'guard (unraid' "$ROOT/boot/config/go"
echo 'PASS: changed upstream preserved at boot and uninstall'

reset_files
run_install
bash "$REPO/uninstall.sh" > "$ROOT/output"
assert_stock
! grep -q 'guard (unraid' "$ROOT/boot/config/go"
echo 'PASS: normal uninstall restores verified stock'

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
echo 'All sandbox tests passed; no live server or disk commands used.'
