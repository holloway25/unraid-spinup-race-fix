#!/bin/bash
# sdspin-patch-notify - verify the sdspin patch is active after boot and raise
# an Unraid notification with the result (success, failure, or guard missing).
#
# Companion to the boot guard installed by install.sh. The guard only writes
# to syslog; this script turns that into a GUI/agent notification so a failed
# re-apply after an Unraid update cannot go unnoticed.
#
# Setup (User Scripts plugin): see "Optional: boot notification" in README.md.
# Schedule: "At First Array Start Only".
#
# Expected patched md5 is read from /boot/config/custom/sdspin.patched, so no
# constants need editing when the patch is ported to a new stock sdspin.

NOTIFY=/usr/local/emhttp/webGui/scripts/notify
TAG=sdspin-notify
PATCHED_FILE=/boot/config/custom/sdspin.patched

if [ ! -f "$PATCHED_FILE" ]; then
  logger -t "$TAG" "WARNING: $PATCHED_FILE not found - is the fix installed?"
  "$NOTIFY" -e "sdspin patch" -s "sdspin patch files missing" \
    -d "$PATCHED_FILE not found - the spin-up race fix does not appear to be installed (or was uninstalled). Remove this script if the fix was retired." -i "warning"
  exit 0
fi

EXPECT=$(md5sum "$PATCHED_FILE" | cut -d' ' -f1)
LIVE=$(md5sum /usr/local/sbin/sdspin 2>/dev/null | cut -d' ' -f1)
LINE=$(grep 'sdspin-patch:' /var/log/syslog | tail -1)

if echo "$LINE" | grep -q 'patched sdspin installed' && [ "$LIVE" = "$EXPECT" ]; then
  logger -t "$TAG" "OK: guard applied patch, live md5 verified ($LIVE)"
  "$NOTIFY" -e "sdspin patch" -s "sdspin patch active" \
    -d "Boot guard applied the patch; live md5 verified ($LIVE)" -i "normal"
elif echo "$LINE" | grep -q 'STOCK SDSPIN CHANGED'; then
  logger -t "$TAG" "ALERT: guard refused - stock sdspin changed"
  "$NOTIFY" -e "sdspin patch" -s "SDSPIN PATCH NOT APPLIED" \
    -d "This Unraid update shipped a different sdspin - you are running STOCK (spin-up task aborts may return; nothing is broken). Follow 'After every Unraid OS update' in the repo README." -i "alert"
else
  logger -t "$TAG" "WARNING: no guard line this boot or md5 mismatch (live: ${LIVE:-none}, expected: $EXPECT)"
  "$NOTIFY" -e "sdspin patch" -s "sdspin guard did not run" \
    -d "No sdspin-patch syslog line found this boot and/or the live sdspin md5 is unexpected (live: ${LIVE:-none}). Check the guard block in /boot/config/go." -i "warning"
fi
exit 0
