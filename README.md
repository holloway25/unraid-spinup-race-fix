# unraid-spinup-race-fix
Fixes "attempting task abort" errors and spurious md read errors during disk spin-up on Unraid. Replaces sdspin's hdparm calls (hard-coded 15s SG_IO timeout) with sg_raw at 45s, so power-mode polls can no longer abort mid-spin-up.
