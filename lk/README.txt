emmc_appsboot.mbn: LK (lk1st) for the Lumia 950 XL with the bootloader menu on screen.

Built from lk2nd, branch cityman of https://github.com/giannoccarol/lk2nd-cityman
(commit 3394d965, based on Android4Lumia950/lk2nd 80dcd678, the version of the
official LK), project lk1st-msm8994, LK2ND_BUNDLE_DTB=msm8994-msft-cityman.dtb,
LK2ND_DISPLAY=sergej_wqhd_dualdsi_cmd.

It adds a driver for the 950 XL panel, so fastboot shows the lk2nd menu
(Continue, Reboot, Recovery, Bootloader, Power off; volume keys to move, power
to select) instead of a black screen. Everything else works as in the official
LK. SHA-256 in ../checksums.sha256 (lk/emmc_appsboot.mbn).

The full install writes it to EFIESP (partition.sh moves it to aboot); Clean and
Update replace the LK in aboot when it differs (-KeepLk leaves it alone).
