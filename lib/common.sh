#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Shared installer helpers; never sourced by the standalone boot guard.
die() { echo "ERROR: $*" >&2; exit 1; }
hash_file() {
  local checksum
  checksum=$(md5sum -- "$1") || return 1
  [[ $checksum =~ ^([[:xdigit:]]{32})[[:space:]][\ *] ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1],,}"
}
TEST_MODE=0
ROOT=""
if [[ -n ${SDSPIN_TEST_ROOT:-} ]]; then
  ROOT=$(realpath "$SDSPIN_TEST_ROOT")
  [[ $ROOT == /tmp/sdspin-tests.* && -f $ROOT/.sdspin-test-root ]] || die "invalid test sandbox"
  TEST_MODE=1
else
  [[ $EUID -eq 0 ]] || die "run as root"
fi
SDSPIN="$ROOT/usr/local/sbin/sdspin"
CUSTOM="$ROOT/boot/config/custom"
GO="$ROOT/boot/config/go"
MARK_BEGIN="# --- sdspin-patch guard (unraid-spinup-race-fix) BEGIN ---"
MARK_END="# --- sdspin-patch guard (unraid-spinup-race-fix) END ---"

# Refuse malformed markers instead of deleting unrelated go code.
strip_guard() {
  awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
    $0==begin {if (inside || seen++) exit 1; inside=1; next}
    $0==end {if (!inside) exit 1; inside=0; next}
    !inside {print}
    END {if (inside) exit 1}
  ' "$GO"
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sdspin-work.XXXXXXXX")
COMMITTED=0
declare -a TARGETS=() BACKUPS=() EXISTED=()
# Prepare and verify alongside the destination, then publish with atomic rename.
# Explicit failure handling also applies when called from rollback conditionals.
atomic_replace() {
  local source=$1 target=$2 mode=$3 staged expected actual
  staged=$(mktemp "${target%/*}/.${target##*/}.replace.XXXXXXXX") || return 1
  if ! expected=$(hash_file "$source") ||
     ! install -m "$mode" "$source" "$staged" ||
     ! actual=$(hash_file "$staged") ||
     [[ $actual != "$expected" ]] ||
     ! mv -f -- "$staged" "$target"; then
    rm -f -- "$staged"
    return 1
  fi
}
cleanup() {
  local rc=$? i mode rollback_failed=0
  trap - EXIT HUP INT TERM
  if (( ! COMMITTED )); then
    for ((i=${#TARGETS[@]}-1; i>=0; i--)); do
      if [[ ${EXISTED[i]} == 1 ]]; then
        if ! mode=$(stat -c %a "${BACKUPS[i]}") ||
           ! atomic_replace "${BACKUPS[i]}" "${TARGETS[i]}" "$mode"; then
          echo "ERROR: rollback failed for ${TARGETS[i]}" >&2
          rollback_failed=1
        fi
      else
        if ! rm -f -- "${TARGETS[i]}"; then
          echo "ERROR: rollback failed for ${TARGETS[i]}" >&2
          rollback_failed=1
        fi
      fi
    done
  fi
  if (( rollback_failed )); then
    echo "ERROR: incomplete rollback; private recovery directory retained: $WORK" >&2
    for ((i=0; i<${#TARGETS[@]}; i++)); do
      if [[ ${EXISTED[i]} == 1 ]]; then
        printf 'Recovery backup: %s -> %s\n' "${BACKUPS[i]}" "${TARGETS[i]}" >&2
      else
        printf 'Recovery removal (originally absent): %s\n' "${TARGETS[i]}" >&2
      fi
    done
    rc=1
  else
    rm -rf -- "$WORK"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
save_target() {
  local target=$1 index=${#TARGETS[@]} exists=0 backup
  backup="$WORK/backup.$index"
  if [[ -e $target ]]; then
    cp -p -- "$target" "$backup"
    exists=1
  fi
  TARGETS+=("$target") BACKUPS+=("$backup") EXISTED+=("$exists")
}
