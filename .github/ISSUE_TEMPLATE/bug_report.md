---
name: Task-abort / read-error report
about: Spin-up task aborts, or md read errors on a healthy disk
title: ""
labels: []
---

<!--
BEFORE OPENING: please confirm this is the sdspin timeout race and not a real
disk/media/transport fault. See the README section "What this does NOT fix".
UNC, critical medium errors, pending/reallocated sectors, SATA CRC, and link
resets are OUT OF SCOPE for this patch and are almost always a failing disk,
cable, backplane, or controller.
-->

**Unraid version**
<!-- e.g. 7.3.2 -->

**Storage controller / HBA**
<!-- e.g. LSI SAS3224, or onboard SATA. Include firmware if you know it. -->

**Affected drive(s)**
<!-- model + capacity, and whether low-current spin-up / Seagate EPC is enabled -->

**Is the patch installed?**
<!-- paste the output of both:
       grep sdspin-patch /var/log/syslog
       md5sum /usr/local/sbin/sdspin
     (the md5 should match sdspin.patched if the guard applied) -->

**SMART summary for the affected disk**
<!-- pending + reallocated sector counts, and whether an extended self-test
     passes. A CLEAN SMART is expected for the sdspin race — pending or
     reallocated sectors point to a real disk fault instead. -->

**Relevant syslog lines**
<!-- 10-20 lines AROUND the spin-up / error burst. The signatures that mean
     THIS patch:  opcode=0x85 , timeout 15000 ms , Sense 02/04/00 ,
     md: diskN read error .
     If you instead see  UNC / critical medium error / link resets , that's a
     disk/transport fault and out of scope here. -->

**What you've already checked**
<!-- Backups current? Parity valid? Did `bash uninstall.sh` change the
     behaviour? Does the issue only happen at spin-up? -->
