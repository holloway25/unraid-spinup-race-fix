# unraid-spinup-race-fix

Fixes **"attempting task abort"** errors — and the spurious **`md: diskN read error`** bursts they can cause — during disk spin-up on Unraid.

```
kernel: sd 1:0:9:0: attempting task abort!scmd(...), outstanding for 15503 ms & timeout 15000 ms
kernel: sd 1:0:9:0: [sdn] tag#2384 CDB: opcode=0x85 85 06 20 00 00 00 00 00 00 00 00 00 00 40 e5 00
kernel: sd 1:0:9:0: task abort: SUCCESS scmd(...)
```

If you've seen those lines every time a sleeping disk wakes up — or worse, a burst of
`md: diskN read error` on a drive whose SMART is pristine — this is very likely your bug.

## Symptoms — is this your problem?

You may see any combination of the following. All log lines below are real
(identifying details generalised) so that searches for these exact strings
find this page.

**1. Task aborts every time a sleeping disk wakes** (the common, "benign" form
— many systems have shown this noise for years):

```
kernel: sd 1:0:9:0: attempting task abort!scmd(0x00000000155105fb), outstanding for 15503 ms & timeout 15000 ms
kernel: sd 1:0:9:0: [sdn] tag#2384 CDB: opcode=0x85 85 06 20 00 00 00 00 00 00 00 00 00 00 40 e5 00
kernel: sd 1:0:9:0: task abort: SUCCESS scmd(0x00000000155105fb)
```

The giveaways: `opcode=0x85` (ATA PASS-THROUGH 16), a CDB ending `...40 e5 00`
(CHECK POWER MODE) or `...40 e3 00` (IDLE), `timeout 15000 ms`, and
`task abort: SUCCESS` — always coinciding with a disk spinning up. Seen with
`mpt3sas` / LSI SAS HBAs in particular (9207, 9300, 9305, 9306 series etc.),
with or without a SAS expander.

**2. The severe form — spurious read errors on a healthy disk.** If real I/O
(e.g. a Plex/Jellyfin stream cold-starting) is what woke the disk, the abort's
error handling can fail that legitimate read while the drive is still spinning
up. The drive returns sense `02/04/00` ("Not Ready — cause not reportable"),
and Unraid's md driver logs a burst like:

```
kernel: sd 1:0:9:0: [sdn] tag#2385 FAILED Result: hostbyte=DID_OK driverbyte=DRIVER_OK
kernel: sd 1:0:9:0: [sdn] tag#2385 Sense Key : 0x2 [current]
kernel: sd 1:0:9:0: [sdn] tag#2385 ASC=0x4 ASCQ=0x0
kernel: md: disk10 read error, sector=15303268032
kernel: md: disk10 read error, sector=15303268040
...   (often dozens in one burst)
kernel: sd 1:0:9:0: Power-on or device reset occurred
```

Unraid reconstructs the failed blocks from parity and writes them back —
**no data loss, and the disk is not disabled** — but the error counter on the
Main tab climbs, and the pattern repeats on a later cold-start wake.

**How to tell this apart from a genuinely failing disk:** SMART stays clean
(zero pending/reallocated sectors, no ATA errors in the drive's own log), the
errors *only* occur at spin-up, extended SMART tests pass, and the read errors
arrive in one tight burst immediately after a task abort on `opcode=0x85`. A
real failing disk shows pending sectors, errors during sustained I/O, or ATA
errors logged by the drive itself. When in doubt, treat it as a real disk
problem first — see the disclaimer below.

**Drives commonly slow enough to lose this race** (spin-up ≥ 15 s, especially
with low-current spin-up enabled): Seagate IronWolf ST8000VN004 and similar,
various WD Red Plus / shucked white-label 8 TB+ units, and most high-capacity
helium drives. Fast-spinning small drives may never trigger it — which is why
the same system can show aborts on some disks and not others.

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
IronWolf/WD/HC550 mix, Unraid 7.3.1; re-verified on 7.3.2, which ships a byte-identical stock sdspin):

* Race reproduction test (spin-up + concurrent status poll): stock aborted at exactly
  15000 ms; patched waited out a kernel-timestamped **18 s** spin-up and returned
  clean — 0 aborts.
* Boot-time array spin-up: **16 task aborts** on the last pre-patch boot → **0** on
  every boot since.
* Production cold-start wakes and weekly all-disk mover runs since: **0 aborts,
  0 md errors**, standby detection correct, zero udev-induced re-wakes.

## Install

```
# 1. Get the files onto your server (any method works):
git clone https://github.com/holloway25/unraid-spinup-race-fix.git
cd unraid-spinup-race-fix

#    ...or download the ZIP from GitHub and unpack it anywhere,
#    e.g. under /boot/config/custom/

# 2. Read install.sh before running it. It is short and commented.
#    You are about to let a script from the internet modify a system
#    file on your NAS as root — you should know what it does first.

# 3. Run it:
bash install.sh
```

**What the installer will and won't do:**

- It **verifies** your live `/usr/local/sbin/sdspin` is a known stock version (md5
  listed in `known-stock-md5s`) before changing anything. If it doesn't recognise
  it, it stops and changes **nothing**. If yours isn't listed, please open an issue
  with your Unraid version and the contents of `/usr/local/sbin/sdspin`.
- It backs up your stock script to `/boot/config/custom/sdspin.stock` before patching.
- It adds one clearly-marked block to `/boot/config/go` so the patch survives
  reboots. Nothing else on your flash drive is touched.
- It does **not** spin any disk up or down, restart any service, or touch your
  array. No reboot is needed.

Requirements: `sg_raw` (sg3_utils) and `patch` — both present in stock Unraid.

**Verify it worked:**

```
grep sdspin-patch /var/log/syslog            # after next boot: "patched sdspin installed"
/usr/local/sbin/sdspin sdX status; echo $?   # against a spinning disk: expect 0
```

### After every Unraid OS update

```
grep sdspin-patch /var/log/syslog
```

* `patched sdspin installed` → all good.
* `STOCK SDSPIN CHANGED` → the update shipped a new sdspin; you are safely running
  stock. Check this repo for an updated patch, or diff the new script — if Lime Tech
  has fixed the timeout upstream, simply run `uninstall.sh` and retire this fix.

## Exit codes

The patched script keeps **stock sdspin's exact exit-code contract**, so emhttpd
(and anything else calling sdspin) behaves identically:

| Exit | `status` means | `up` / `down` means |
|------|----------------|---------------------|
| `0`  | disk is spun up | command succeeded |
| `2`  | disk is in standby (spun down) | — |
| `1`  | error / device doesn't support the query | command failed |

Notes:

- `status` exit `0` covers **all** spun-up power states, including Seagate EPC
  idle sub-states (descriptor count `0x81`/`0x82`) that stock `hdparm -C`
  reports as "unknown" — that was an hdparm display quirk, not an error.
- Installer exit codes: it exits non-zero with a printed `ERROR:` line for every
  refusal case (not root, unknown stock md5, `sg_raw` or `patch` missing, patch
  failed to apply). Any error means **nothing was changed** unless the message
  says otherwise.
- Boot-guard outcomes are logged to syslog under the tag `sdspin-patch`:
  `patched sdspin installed` (good) or `STOCK SDSPIN CHANGED or sg_raw missing -
  patch NOT applied, running stock` (safe fallback — see "After every Unraid OS
  update" above).

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

## Disclaimer — read before installing

This project modifies a script that Unraid's disk-management daemon relies on.
It is published in the hope it is useful, **without warranty of any kind**,
under the terms of the GPL-2.0 license (see `LICENSE`, sections 11–12: no
warranty, no liability).

By installing it you accept that:

- **You are responsible for your own server and data.** The author has
  validated this fix on one hardware configuration (see "Validated results").
  Your controller, drives, firmware, and Unraid version may behave differently.
- **You should have backups and current parity before changing anything** on a
  storage server — this or anything else.
- **You are expected to run the verification steps yourself** after installing
  and after every Unraid OS update. The boot guard fails safe (falls back to
  stock), but only you can confirm it did.
- If anything looks wrong, roll back first (`bash uninstall.sh` — instant, no
  reboot) and ask questions second. Please open a GitHub issue with your Unraid
  version, controller model, and the relevant syslog lines.
- This is a community workaround for an upstream limitation, not an official
  Lime Technology fix. If a future Unraid release resolves the underlying
  timeout, uninstall this and use stock.

## Status

Currently distributed as a patch + installer. A proper Unraid plugin (.plg with
version-aware self-retirement) is planned. Ideally this repo eventually becomes
unnecessary if the underlying timeout is addressed upstream.

## License

GPL-2.0. The patch modifies Unraid's `sdspin` script (credit: Lime Technology /
community dev @doron); this repo distributes only the diff and installer, not the
original script.

*Provided with no warranty. It works on my hardware; validate on yours (the README's
validation section doubles as a test plan). Use at your own risk.*
