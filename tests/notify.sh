#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Test notifications with mocked paths, checksum failures and notify/logger.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(mktemp -d /tmp/sdspin-notify-tests.XXXXXXXX)
trap 'rm -rf -- "$ROOT"' EXIT
mkdir "$ROOT/bin"
export NOTIFY_TEST_ROOT="$ROOT"
export REAL_MD5SUM=$(command -v md5sum)
export PATH="$ROOT/bin:$PATH"
printf 'identical scripts\n' > "$ROOT/patched"
cp "$ROOT/patched" "$ROOT/live"
printf 'sdspin-patch: patched sdspin installed\n' > "$ROOT/syslog"
cat > "$ROOT/bin/logger" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$NOTIFY_TEST_ROOT/logger"
MOCK
cat > "$ROOT/bin/notify" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$NOTIFY_TEST_ROOT/notifications"
MOCK
cat > "$ROOT/bin/md5sum" <<'MOCK'
#!/bin/bash
case $CHECKSUM_MODE in
  both-fail) exit 1 ;;
  expected-fails) [[ $1 != "$NOTIFY_TEST_ROOT/patched" ]] || exit 1 ;;
  live-fails) [[ $1 != "$NOTIFY_TEST_ROOT/live" ]] || exit 1 ;;
  empty-success) exit 0 ;;
  malformed-success) echo 'not-a-checksum'; exit 0 ;;
esac
exec "$REAL_MD5SUM" "$@"
MOCK
chmod +x "$ROOT/bin/"*
sed -e "s#/usr/local/emhttp/webGui/scripts/notify#$ROOT/bin/notify#g" \
    -e "s#/boot/config/custom/sdspin.patched#$ROOT/patched#g" \
    -e "s#/usr/local/sbin/sdspin#$ROOT/live#g" \
    -e "s#/var/log/syslog#$ROOT/syslog#g" \
    "$REPO/extras/sdspin-patch-notify.sh" > "$ROOT/script"
for mode in both-fail expected-fails live-fails empty-success malformed-success valid; do
  export CHECKSUM_MODE=$mode
  rm -f "$ROOT/notifications" "$ROOT/logger"
  rc=0
  bash "$ROOT/script" || rc=$?
  if [[ $mode == valid ]]; then
    [[ $rc == 0 ]]
    grep -q 'sdspin patch active.*-i normal' "$ROOT/notifications"
  else
    [[ $rc == 1 ]]
    grep -q 'sdspin verification failed.*-i warning' "$ROOT/notifications"
    if grep -q -- '-i normal' "$ROOT/notifications"; then
      echo "FAIL: false success notification for $mode" >&2
      exit 1
    fi
  fi
  echo "PASS: notification checksum case $mode"
done
