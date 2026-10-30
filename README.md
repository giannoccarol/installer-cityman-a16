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

## Requirements

- A Windows 10 or 11 PC (Windows PowerShell 5.1, included in Windows).
- [WPInternals](https://github.com/ReneLergner/WPinternals), for the full install:
  the phone must be unlocked with it, and it switches the phone to mass storage mode.
- [Android SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools)
  (`adb` and `fastboot`), with their folder added to `PATH`. In full mode the installer
  falls back to the copy in the official installer's `bin` folder if they are not on `PATH`.
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

The installer checks the SHA-256 of every file before it writes it: the ROM against
`SHA256SUMS` (or `-RomSha256`), the TWRP and the official files against
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
| `-Twrp <img>` | Android 16 TWRP (default: `twrp\twrp-cityman-a16.img`) |
| `-EfiEsp <folder>` | the phone's EFIESP drive in full mode (default: folder dialog) |
| `-OfficialDir <folder>` | official installer files (default: `official\`) |
| `-AdbPath`, `-FastbootPath` | adb and fastboot executables |
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
   the BCD, `bootshim.efi`, `Stage2.efi`, `developermenu.efi`, the UI images and LK
   (`emmc_appsboot.mbn`), as the official `installer.bat` does.
4. Eject the phone's drives and hold the power key until it restarts. After some text
   the screen goes black: the phone is in LK (fastboot). If Windows shows an unknown
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
    byte for byte the zip's `boot.img`, reboot.

Clean and Update start at step 8 (without provisioning): the installer puts the phone
in LK (`adb reboot bootloader` if it is in Android or TWRP), boots the Android 16 TWRP
and goes on from there. Update reads the installed system first and asks before
installing over anything that is not LineageOS 23.x for cityman.

The first boot takes several minutes, longer after a clean install.

## Differences from the official installer

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
  `sideload` state.
- The TWRP adbd does not return exit codes, so the commands the installer runs on the
  phone ([`device/cityman-a16-helper.sh`](device/cityman-a16-helper.sh)) print a
  `RESULT=OK` or `RESULT=FAIL:` line that the installer reads.
- If a full install stops, the message says how to go on. With the phone in LK,
  `installer.bat -Mode Full -Resume Partition` continues after the EFIESP step and
  `-Resume Modem` after partitioning (it writes recovery and modem, provisions and installs).
- If the phone stays in LK after a failed ROM install, run the installer again in Clean
  (or Update) mode.
- Going back to Windows needs the original EFIESP files (in the backup folder), the
  provisioning backup and a stock FFU flashed with WPInternals.

## Tests

`tests/` contains checks that run on Linux without a phone:

- `tests/run-flow-tests.sh OFFICIAL_DIR TWRP_IMG` runs `installer.ps1` with PowerShell 7
  against a fake `adb` and `fastboot` (`tests/fake/`) that simulate LK and TWRP,
  including the `twrp sideload` race and the sideload transfer error. Scenarios: full
  install, LK repair, refusals at every confirmation, clean, update, update over another
  system, wrong ROM or TWRP checksum, ROM for another device, `boot` mismatch.
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
- [WPInternals](https://github.com/ReneLergner/WPinternals) (René Lergner) for unlocking
  and mass storage mode; Google for the Android SDK Platform Tools and USB driver.

The official installer files are not included in this repository: the installer
downloads them from the Android4Lumia950 repository.
