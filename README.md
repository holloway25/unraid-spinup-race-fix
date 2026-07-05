# unraid-spinup-race-fix

Fixes **"attempting task abort"** errors — and the spurious **`md: diskN read error`** bursts they can cause — during disk spin-up on Unraid.

```
kernel: sd 1:0:9:0: attempting task abort!scmd(...), outstanding for 15503 ms & timeout 15000 ms
kernel: sd 1:0:9:0: [sdn] tag#2384 CDB: opcode=0x85 85 06 20 00 00 00 00 00 00 00 00 00 00 40 e5 00
kernel: sd 1:0:9:0: task abort: SUCCESS scmd(...)
```

If you've seen those lines every time a sleeping disk wakes up — or worse, a burst of
`md: diskN read error` on a drive whose SMART is pristine — this is very likely your bug.

## Root cause

When anything wakes a spun-down disk, Unraid's `emhttpd` polls drive power state via
`/usr/local/sbin/sdspin`, which calls `hdparm -C` (ATA **CHECK POWER MODE** via SG_IO
passthrough). `hdparm` issues that command with a **hard-coded ~15-second SG_IO timeout**.

Many common NAS drives take **15–19 seconds** to spin up (low-current spin-up makes it
slower still). When the poll lands while the drive is spinning up, the timeout expires
first, the SCSI layer fires a **task abort**, and in the worst case the abort's error
handling fails a *legitimate in-flight read* with sense `02/04/00` ("not ready") —
producing a burst of `md read error` lines on a perfectly healthy disk. Unraid
reconstructs the blocks from parity and carries on (no data loss, disk not disabled),
but the race re-opens on every cold-start wake.

The same 15s limit also hits the spin-**up** command (`hdparm -S0` / ATA IDLE) on every
emhttpd-initiated spin-up — that is the source of the long-standing "benign task abort
at spin-up" log noise many systems show.

**Why the usual fixes don't work:**

* `/sys/block/sdX/device/timeout` (and the popular 30s user-script) governs normal
  block I/O only. SG_IO passthrough commands carry their own timeout **supplied by the
  calling program** — hdparm's is compiled in and not configurable.
* Disabling Seagate EPC / low-current spin-up (the widely-cited workaround) just makes
  the drive spin up faster than the timeout. It sacrifices drive power features, and
  for some systems it doesn't work at all.
* SCT ERC settings don't govern this path either.

## The fix

A small patch to `sdspin`:

* **status** branch: `hdparm -C` → `sg_raw` issuing the *identical* CHECK POWER MODE
  CDB with `--readonly --timeout=45`. Power state is parsed from the ATA return
  descriptor; exit codes are identical to stock, so emhttpd semantics are unchanged.
  `--readonly` matters: a read-write open emits a udev change event on close, which
  triggers a partition rescan that *wakes the disk being polled*.
* **up** branch: `hdparm -S0` → `sg_raw` ATA IDLE at 45s — same wake command, but it
  can no longer time out mid-spin-up.
* **down** branch: unchanged stock. It's only ever sent to spinning disks and
  completes in milliseconds.

A boot guard in `/boot/config/go` re-applies the patch each boot (the live copy lives
in a ramdisk and is rebuilt stock at boot). If an Unraid update ships a **different**
sdspin, the guard refuses, the system runs stock (the old log noise returns but nothing
breaks), and it logs a warning so you know to check this repo for an updated patch.

### Validated results

On the system this was developed on (21-drive array, LSI SAS3224 direct-attach,
IronWolf/WD/HC550 mix, Unraid 7.3.1):

* Race reproduction test (spin-up + concurrent status poll): stock aborted at exactly
  15000 ms; patched waited out a kernel-timestamped **18 s** spin-up and returned
  clean — 0 aborts.
* Boot-time array spin-up: **16 task aborts** on the last pre-patch boot → **0** on
  every boot since.
* Production cold-start wakes and weekly all-disk mover runs since: **0 aborts,
  0 md errors**, standby detection correct, zero udev-induced re-wakes.

## Install

```
git clone https://github.com/holloway25/unraid-spinup-race-fix.git
cd unraid-spinup-race-fix
bash install.sh
```

The installer **refuses to run** unless your live `sdspin` md5-matches a known stock
version (see `known-stock-md5s`), so it cannot clobber something it hasn't been
validated against. If yours isn't listed, please open an issue with your Unraid
version and the contents of `/usr/local/sbin/sdspin`.

Requirements: `sg_raw` (sg3_utils — present in stock Unraid) and `patch`.

### After every Unraid OS update

```
grep sdspin-patch /var/log/syslog
```

* `patched sdspin installed` → all good.
* `STOCK SDSPIN CHANGED` → the update shipped a new sdspin; you are safely running
  stock. Check this repo for an updated patch, or diff the new script — if Lime Tech
  has fixed the timeout upstream, simply run `uninstall.sh` and retire this fix.

## Rollback

Instant, no reboot:

```
bash uninstall.sh
```

(or manually: `cp /boot/config/custom/sdspin.stock /usr/local/sbin/sdspin` and remove
the guard block from `/boot/config/go`.)

## Scope & limitations

* **ATA/SATA drives on SAS HBAs or onboard SATA.** This is where the mpt3sas task-abort
  pattern shows up. It should be harmless elsewhere, but that's the validated setup.
* Other programs that issue their own CHECK POWER MODE with their own short timeout
  (e.g. some monitoring agents calling `smartctl -n standby`) are **not** covered —
  the fix applies to Unraid's sdspin callers (emhttpd) only.
* This is **not** the same thing as the excellent
  [unraid-sas-spindown](https://github.com/doron1/unraid-sas-spindown) plugin — that
  adds spin-*down* support for **SAS** drives; this fixes a *timeout race* for
  ATA drives. They address different branches of the same script and different
  drive classes.

## Status

Currently distributed as a patch + installer. A proper Unraid plugin (.plg with
version-aware self-retirement) is planned. A bug report to Lime Technology with the
full evidence chain is in progress — ideally this repo eventually becomes unnecessary.

## License

GPL-2.0. The patch modifies Unraid's `sdspin` script (credit: Lime Technology /
community dev @doron); this repo distributes only the diff and installer, not the
original script.

*Provided with no warranty. It works on my hardware; validate on yours (the README's
validation section doubles as a test plan). Use at your own risk.*
