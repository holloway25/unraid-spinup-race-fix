#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Prove the suite fails if the reviewed uninstall bug is deliberately restored.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(mktemp -d /tmp/sdspin-mutations.XXXXXXXX)
trap 'rm -rf -- "$ROOT"' EXIT
mkdir -p "$ROOT/repo"/{lib,patches,tests}
cp "$REPO/install.sh" "$REPO/uninstall.sh" "$REPO/known-stock-md5s" "$ROOT/repo/"
cp "$REPO/lib/common.sh" "$ROOT/repo/lib/"
cp "$REPO/patches/sdspin-45s-timeout.patch" "$ROOT/repo/patches/"
cp "$REPO/tests/run.sh" "$ROOT/repo/tests/"
sed -i '/atomic_replace "\$WORK\/go"/d' "$ROOT/repo/uninstall.sh"
if bash "$ROOT/repo/tests/run.sh" > "$ROOT/output" 2>&1; then
  echo 'FAIL: broken uninstaller escaped the test suite' >&2
  exit 1
fi
grep -q 'FAIL: unexpected pattern' "$ROOT/output"
echo 'PASS: suite rejects mutated uninstaller that leaves the guard behind'
cp "$REPO/uninstall.sh" "$ROOT/repo/"
sed -i 's/if ata_ok; then/if [[ $OUTPUT =~ status=0x ]]; then/; s/if ata_ok \&\& \[\[/if [[/' "$ROOT/repo/patches/sdspin-45s-timeout.patch"
if bash "$ROOT/repo/tests/run.sh" > "$ROOT/output" 2>&1; then
  echo 'FAIL: broken ATA completion handling escaped the test suite' >&2
  exit 1
fi
grep -q 'FAIL: ATA case' "$ROOT/output"
echo 'PASS: suite rejects mutated ATA parser that treats failed descriptors as success'

cp "$REPO/patches/sdspin-45s-timeout.patch" "$ROOT/repo/patches/"
# Restore the empty-equals-empty decision when the two comparison reads fail.
sed -i '/^LIVE_MD5=/s/ || die .*/ || true/; /PATCHED_MD5=$(hash_file/s/ || die .*/ || true/; s/\[\[ -n $PATCHED_MD5 \&\& $LIVE_MD5/[[ $LIVE_MD5/' "$ROOT/repo/uninstall.sh"
if bash "$ROOT/repo/tests/run.sh" > "$ROOT/output" 2>&1; then
  echo 'FAIL: unsafe checksum comparison escaped the test suite' >&2
  exit 1
fi
grep -q '^PASS: normal uninstall' "$ROOT/output"
echo 'PASS: suite rejects mutated checksum handling that accepts two failed reads'

cp "$REPO/uninstall.sh" "$ROOT/repo/"
sed -i 's/if (( rollback_failed )); then/if (( 0 )); then/' "$ROOT/repo/lib/common.sh"
if bash "$ROOT/repo/tests/run.sh" > "$ROOT/output" 2>&1; then
  echo 'FAIL: deleted recovery backups escaped the test suite' >&2
  exit 1
fi
grep -q '^PASS: uninstall refuses failed, empty and malformed checksums' "$ROOT/output"
echo 'PASS: suite rejects mutated cleanup that deletes backups after failed rollback'
