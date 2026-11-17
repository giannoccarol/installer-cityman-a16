# LineageOS 23.2 (Android 16) installer for the Lumia 950 XL (cityman)

A Windows installer for the unofficial LineageOS 23.2 (Android 16) port to the
Lumia 950 XL. It follows the [official Android4Lumia950 LK installer](https://github.com/Android4Lumia950/installer/tree/cityman-temp)
(branch `cityman-temp`) up to the point where that installer asks you to sideload
a ROM. From there it uses the Android 16 TWRP instead of flashing the LineageOS 18.1
kernel: Android 16's installer aborts on the older TWRP kernel (no `MADV_WIPEONFORK`).

Experimental. It erases Windows on the phone (full install) or all user data
(clean install). Your warranty is void and you do this at your own risk.

## Modes

| Mode | Phone before | What happens | Data |
|---|---|---|---|
| **Full** | Windows 10 Mobile or WOA, bootloader unlocked with WPInternals | Official steps (Developer Menu, boot shim and LK on EFIESP, backup of the provisioning partitions, Android partitions, recovery and modem, provisioning), then Android 16 TWRP, format data, ROM | Windows and its data are erased |
| **Clean** | LK and Android partitions already there (for example LineageOS 18.1 from the official installer, or an earlier build of this port) | Android 16 TWRP, format data, wipe cache and Dalvik, ROM | All data erased, internal storage included |
| **Update** | This LineageOS 23.2 port | Android 16 TWRP, ROM | Kept |

**Bootloader menu.** Every mode installs the LK in `lk\` (lk2nd with a driver for the
950 XL panel): in fastboot the phone shows the lk2nd menu, Continue, Reboot, Recovery,
Bootloader and Power off, with the volume keys to move and the power key to select.
The official LK leaves the screen black there. Full writes it to EFIESP in place of
the official LK. Clean and Update read the LK in the `aboot` partition and replace it
when it is a different one (for example the official LK), before the ROM;
`-KeepLk` leaves it as it is. Details in [Bootloader (LK)](#bootloader-lk).

## Requirements

- A Windows 10 or 11 PC (Windows PowerShell 5.1, included in Windows).
- [WPInternals](https://github.com/ReneLergner/WPinternals), for the full install:
  the phone must be unlocked with it, and it switches the phone to mass storage mode.
- [Android SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools)
  (`adb` and `fastboot`). The installer looks for them on `PATH`, then in a
  `platform-tools` (or `bin`) folder next to `installer.bat`, in the installer folder
  itself and in the official installer's `bin` folder. If it finds none, it offers to
  download Google's Platform Tools r37.0.1 (about 8 MB, SHA-256 checked) into
  `platform-tools\`.
- [Google USB driver](https://developer.android.com/studio/run/win-usb) installed system wide,
  so that Windows sees the phone in LK (fastboot), in TWRP and in Android.
- A battery above 50% and a good USB cable.
- For Update and Clean from Android: USB debugging enabled on the phone.

## Files

Download this repository, then put next to `installer.bat`:

| Folder | File | Where from |
|---|---|---|
| `rom\` | `lineage-23.2-YYYYMMDD-UNOFFICIAL-cityman.zip` and its `SHA256SUMS` | ROM download page |
| `twrp\` | `twrp-cityman-a16.img` | [release page](https://github.com/giannoccarol/android_device_msft_cityman/releases) of the device tree |
| `official\` | the official installer at commit `5c215fd` | downloaded by the installer in full mode (about 110 MB), or put it there yourself |
| `gapps\` | optional: one GApps zip for Android 16, arm64 (for example NikGapps core) | the GApps project's page |
| `lk\` | `emmc_appsboot.mbn`, LK with the bootloader menu on screen | included in this repository (see [Bootloader (LK)](#bootloader-lk)) |

**Google apps.** An update replaces the system partition, and GApps live there: if the
phone has GApps, put the same GApps zip in `gapps\` before an update. The installer
sideloads it right after the ROM, before rebooting. If the installed system has GApps
and `gapps\` is empty, the update stops before writing anything, because Android does
not finish booting when the GApps disappear from under their data.

The installer checks the SHA-256 of every file before it writes it: the ROM against
`SHA256SUMS` (or `-RomSha256`), the TWRP, the LK and the official files against
[`checksums.sha256`](checksums.sha256). The official files are pinned to commit
[`5c215fd`](https://github.com/Android4Lumia950/installer/commit/5c215fda5daf73866a93dfad3b6473253552dfe5)
of `cityman-temp`, the version this installer was checked with.

## Usage

Double-click `installer.bat` and choose the mode, or pass options:

```
installer.bat -Mode Update -Rom D:\roms\lineage-23.2-20261030-UNOFFICIAL-cityman.zip
```

| Option | Meaning |
|---|---|
| `-Mode Full\|Clean\|Update` | skip the menu |
| `-Rom <zip>` | ROM zip (default: the only `lineage-23.2-*-cityman.zip` in `rom\`) |
| `-RomSha256 <hash>` | expected SHA-256 of the zip, if there is no `SHA256SUMS` file |
| `-Gapps <zip>` | GApps zip sideloaded after the ROM (default: the only `.zip` in `gapps\`) |
| `-NoGapps` | update without GApps even if the installed system has them (Android may not boot until you install them or format data) |
| `-KeepLk` | Clean and Update: leave the LK in the `aboot` partition as it is |
| `-Twrp <img>` | Android 16 TWRP (default: `twrp\twrp-cityman-a16.img`) |
| `-EfiEsp <folder>` | the phone's EFIESP drive in full mode (default: folder dialog) |
| `-OfficialDir <folder>` | official installer files (default: `official\`) |
| `-AdbPath`, `-FastbootPath` | adb and fastboot executables (default: `PATH`, then `platform-tools\` next to the installer) |
| `-Resume Partition\|Modem` | resume an interrupted full install with the phone in LK: `Partition` when EFIESP is already prepared, `Modem` when the Android partitions already exist |

The full install asks for administrator rights, as the official installer does.
Every destructive step waits for you to type a word (`YES`, `ERASE`, `CONTINUE`, `UPDATE`).
A log of each run is written to `logs\`.

### Full install, step by step

1. Unlock the phone with WPInternals.
2. In WPInternals, switch the phone to mass storage mode. A full backup of the phone
   with Win32DiskImager is recommended at this point.
3. Run `installer.bat`, choose **1**, and select the phone's EFIESP drive (it may also
   be mounted inside MainOS). The installer backs up the files it replaces, then writes
   the BCD, `bootshim.efi`, `Stage2.efi`, `developermenu.efi`, the UI images, as the
   official `installer.bat` does, and LK (`emmc_appsboot.mbn`) from `lk\`.
4. Eject the phone's drives and hold the power key until it restarts. After some text
   the phone shows the lk2nd menu: it is in LK (fastboot). If Windows shows an unknown
   "Android" device, install the USB driver.
5. The installer boots the official TWRP, saves the 15 provisioning partitions
   (`APDP DBI DDR DPO DPP LIMITS MODEM_FS1 MODEM_FS2 MODEM_FSC MODEM_FSG MSADP SEC SSD
   UEFI_BS_NV UEFI_RT_NV`) to `backups\cityman-<date>\provisioned\` and checks each copy
   against the phone. Nothing is erased before this backup is complete.
6. After you type `ERASE`, it runs the official `partition.sh`: MainOS, Data and MMOS
   are deleted and the Android partitions created; LK moves from EFIESP to `aboot`.
   The installer checks the new partitions and LK.
7. In LK it writes the Android 16 TWRP to `recovery` and the official `modem.img` to
   `modem`.
8. It boots the Android 16 TWRP (`fastboot boot`) and runs the official `provision.sh`
   (Wi-Fi and Bluetooth MAC addresses into `persist`, modem data into
   `modemst1/modemst2/fsc/fsg/ssd`), then checks the result.
9. `twrp format data`, `twrp wipe cache`, `twrp wipe dalvik`.
10. ADB sideload of the ROM, check of the TWRP log, check that the `boot` partition is
    byte for byte the zip's `boot.img`, then the GApps if there is a zip in `gapps\`
    (checked in the TWRP log too), reboot.

Clean and Update start at step 8 (without provisioning): the installer puts the phone
in LK (`adb reboot bootloader` if it is in Android or TWRP), boots the Android 16 TWRP
and goes on from there. Update reads the installed system first and asks before
installing over anything that is not LineageOS 23.x for cityman; it also stops if that
system has GApps and no GApps zip was given.

The first boot takes several minutes, longer after a clean install.

## Bootloader (LK)

`lk\emmc_appsboot.mbn` is lk2nd built as lk1st (the first bootloader after the boot shim)
for the Lumia 950 XL, from the
[`cityman` branch of giannoccarol/lk2nd-cityman](https://github.com/giannoccarol/lk2nd-cityman/tree/cityman)
(see `lk\README.txt` for the commit and build options). It is the official LK
(Android4Lumia950 lk2nd `80dcd67`) with a driver for the 950 XL panel added:

- the UEFI switches the display off before LK starts, so the official LK cannot reuse
  the screen and fastboot stays black; this LK powers the panel up again (the same rails
  and voltages as the Android kernel) and drives it, then shows the lk2nd menu;
- Android is started exactly as before; the kernel sets the panel up again on its own.

To go back to the official LK: run Update with the official file in `lk\` and its
SHA-256 in `checksums.sha256`, or from TWRP mount `aboot` (vfat) and copy the official
`emmc_appsboot.mbn` over the new one. If LK did not start at all, the Developer Menu
(boot manager entry) or WPInternals mass storage mode give access to `aboot` from a PC.

## Differences from the official installer

- LK is the one in `lk\` (bootloader menu on screen) instead of the official
  `DATA\emmc_appsboot.mbn`, and Clean and Update bring it to phones installed earlier.
- After provisioning, the Android 16 TWRP is booted with `fastboot boot` and the ROM is
  installed by the installer (format, sideload, checks) instead of asking for a
  LineageOS 18.1 sideload and flashing its kernel. On this phone LK does not start the
  `recovery` partition (`fastboot reboot recovery` and `adb reboot recovery` boot the
  system), so TWRP is always started with `fastboot boot`. The Android 16 TWRP is also
  written to `recovery`, where the official one used to go.
- `partition.sh` is fixed when it is prepared: upstream looks up the partition it just
  created with `grep "${androidPartitions[i]}"`, so creating `boot` also matches
  `aboot` and `mke2fs` formats `aboot`, which holds LK. The installer replaces that
  line with an exact match at the end of the line
  (`grep -E "[[:space:]]${androidPartitions[i]}\$"`) and checks the result against
  `checksums.sha256`. It runs `partition.sh` with `yes y |` after showing which Windows
  partitions it will delete, so the script's "not found, proceed?" questions need no typing.
- The provisioning backup is made and verified on the PC before `partition.sh` runs;
  the original EFIESP files are backed up before they are replaced.
- Errors stop the installer with a message instead of being ignored (the official
  `installer.bat` sends most command output to `nul`).
- `ui\partition.sh` (an older copy of the script) is not copied to EFIESP.

## Notes for troubleshooting

- `adb: failed to read command: Success` (or `No error`) at the end of the sideload is
  common with TWRP; the installer then reads `/tmp/recovery.log` and checks the `boot`
  partition to decide whether the install worked.
- TWRP is not ready right after boot. The installer waits for `adb shell`, then for
  the `twrp` command interface, and retries `twrp sideload` until adb reports the
  `sideload` state. This applies to the official TWRP in the full install too: while
  it starts, TWRP restarts its USB connection (MTP), and a command sent at that moment
  can be lost (`error: closed`). Earlier versions sent `check-windows` without waiting
  for the interface, and the full install could stop with "No answer from the phone
  for 'check-windows'" before the backup. If adb still loses the connection, the
  installer reconnects and runs the check again (up to 4 attempts).
- "The TWRP command interface did not start within 3 minutes": TWRP answers on adb
  but does not take commands. While it waits, the installer shows what adb answers
  and, if it gives up, copies `adb devices` and the end of TWRP's `/tmp/recovery.log`
  into the log: send that log with the report. If TWRP shows a question or a password
  screen, answer it on the phone. To go on, hold power until the phone restarts in LK
  and run the installer again (a full install says which `-Resume` to use). In Clean
  or Update mode you can also install from the TWRP on the screen: Advanced > ADB
  Sideload, swipe, then `adb sideload <rom>.zip` (and the GApps zip the same way);
  for a clean install format data first (Wipe > Format Data).
- "Partitioning did not complete: partition aboot is missing" (installer versions before
  2026-11-14): the partitions were created, but the check read the partition names from
  the kernel, which does not know the names of partitions created in the same TWRP
  session. Leave the phone in TWRP, download the installer again and run
  `installer.bat -Mode Full -Resume Modem`: with the phone still in TWRP it checks the
  partitions and LK (and copies LK again if needed) before rebooting.
- Confirmation words are case-sensitive: type `YES`, `ERASE`, `FULL` in capitals. A full
  install on a phone whose EFIESP already has LK warns first: that phone has had Android,
  and Clean or Update is usually what you want.
- If a full install stops before you type `ERASE`, nothing was erased, but the phone
  starts LK instead of Windows. Leave it connected and run
  `installer.bat -Mode Full -Resume Partition`. To go back to Windows instead, copy the
  files from `backups\cityman-<date>\EFIESP` (first run) back to the phone's EFIESP
  in mass storage mode.
- The TWRP adbd does not return exit codes, so the commands the installer runs on the
  phone ([`device/cityman-a16-helper.sh`](device/cityman-a16-helper.sh)) print a
  `RESULT=OK` or `RESULT=FAIL:` line that the installer reads.
- If a full install stops, the message says how to go on. With the phone in LK,
  `installer.bat -Mode Full -Resume Partition` continues after the EFIESP step and
  `-Resume Modem` after partitioning (it writes recovery and modem, provisions and installs).
- If the phone stays in LK after a failed ROM install, run the installer again in Clean
  (or Update) mode.
- Boot loop after an update over GApps without the GApps zip (installer versions before
  2026-11-04 did not install GApps): put the GApps zip in `gapps\`, leave the phone
  connected while it restarts and run the installer in Update mode. This ROM starts adb
  early in the boot, and the installer sends the phone to the bootloader as soon as it
  appears; nothing on the phone has to be pressed. If adb never sees it, put the phone
  in LK by hand and run the installer again.
- Going back to Windows needs the original EFIESP files (in the backup folder), the
  provisioning backup and a stock FFU flashed with WPInternals.

## Tests

`tests/` contains checks that run on Linux without a phone:

- `tests/run-flow-tests.sh OFFICIAL_DIR TWRP_IMG` runs `installer.ps1` with PowerShell 7
  against a fake `adb` and `fastboot` (`tests/fake/`) that simulate LK and TWRP,
  including the `twrp sideload` race and the sideload transfer error. Scenarios: full
  install, LK repair, LK update in Clean and Update (skipped when already current or
  with `-KeepLk`), refusals at every confirmation, clean, update, update over another
  system, wrong ROM or TWRP checksum, ROM for another device, `boot` mismatch, adb and
  fastboot next to the installer or missing, TWRP that never takes commands.
- `tests/helper-tests.sh` tests the phone-side helper on a fake sysfs/by-name tree.
  Run it with the shell you want to check, for example busybox in a container.

## Credits

- **Android4Lumia950** - djokcho, EpicLPer, j0sh1x and the community: the Lumia 950/950 XL
  Android port and the [LK installer](https://github.com/Android4Lumia950/installer)
  this installer follows and whose files and scripts it downloads and runs (Developer
  Menu, boot shim, Stage2, LK, BCD, `partition.sh`, `provision.sh`, modem image, cityman
  TWRP). sonic011gamer (snaccy) for the `cityman-temp` branch (950 XL changes, TWRP with
  parted) and the installation video.
- **TeamWin**: [TWRP](https://twrp.me). The Android 16 TWRP is the Android4Lumia950
  cityman TWRP with the Android 16 kernel and a fixed linker search path.
- **lk2nd** ([msm8916-mainline/lk2nd](https://github.com/msm8916-mainline/lk2nd), Stephan
  Gerhold and contributors) and the [Android4Lumia950 lk2nd fork](https://github.com/Android4Lumia950/lk2nd)
  the LK in `lk\` is built from; the panel driver follows Qualcomm's LK display code for
  the MSM8994 reference phones and the panel settings of the Android4Lumia950 MMO kernel.
- [WPInternals](https://github.com/ReneLergner/WPinternals) (René Lergner) for unlocking
  and mass storage mode; Google for the Android SDK Platform Tools and USB driver.

The official installer files are not included in this repository: the installer
downloads them from the Android4Lumia950 repository.
