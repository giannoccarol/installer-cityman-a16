#!/usr/bin/env bash
# Runs installer.ps1 with PowerShell 7 (pwsh) against fake adb/fastboot (tests/fake).
# Nothing touches a real phone. Needs: pwsh, python3, unzip.
#
#   tests/run-flow-tests.sh OFFICIAL_DIR TWRP_IMG
#     OFFICIAL_DIR  checkout of Android4Lumia950/installer at 5c215fd (branch cityman-temp)
#     TWRP_IMG      twrp-cityman-a16.img
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
OFFICIAL=${1:?official installer dir}
TWRP=${2:?twrp-cityman-a16.img}
T=$(mktemp -d "${TMPDIR:-/tmp}/cityman-installer-test.XXXXXX")
PASS=0; FAIL=0

# Official installer copy with CRLF shell scripts (as a Windows git checkout may give).
mkdir -p "$T/official"
ln -s "$OFFICIAL/DATA" "$T/official/DATA"; ln -s "$OFFICIAL/ui" "$T/official/ui"
sed 's/$/\r/' "$OFFICIAL/partition.sh" > "$T/official/partition.sh"
sed 's/$/\r/' "$OFFICIAL/provision.sh" > "$T/official/provision.sh"

# Small fake ROM zip and its SHA256SUMS.
mkdir -p "$T/rom"
ROM="$T/rom/lineage-23.2-20261030-UNOFFICIAL-cityman.zip"
python3 -I - "$ROM" <<'PY'
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('META-INF/com/android/metadata', 'ota-type=BLOCK\npost-sdk-level=36\npre-device=cityman,talkman,angler\n')
    z.writestr('META-INF/com/google/android/update-binary', 'fake')
    z.writestr('boot.img', b'ANDROID!' + os.urandom(3 * 4096 - 8))
PY
(cd "$T/rom" && sha256sum "$(basename "$ROM")" > SHA256SUMS)
TWRP_SHA=$(sha256sum "$TWRP" | cut -c1-64)
OFF_TWRP_SHA=$(sha256sum "$OFFICIAL/DATA/twrp.img" | cut -c1-64)
MODEM_SHA=$(sha256sum "$OFFICIAL/DATA/modem.img" | cut -c1-64)
ROM_SHA=$(sha256sum "$ROM" | cut -c1-64)

# run NAME INITIAL_STATE STDIN [installer args...]
run() {
    local name=$1 state=$2 input=$3; shift 3
    export FAKE_STATE="$T/$name"; export FAKE_ROM="$ROM"
    mkdir -p "$FAKE_STATE"; echo "$state" > "$FAKE_STATE/state"
    local defaults=()
    case " $* " in *" -Twrp "*) ;; *) defaults+=(-Twrp "$TWRP") ;; esac
    case " $* " in *" -Rom "*) ;; *) defaults+=(-Rom "$ROM") ;; esac
    printf '%b' "$input" | pwsh -NoProfile -File "$REPO/installer.ps1" -NoElevate \
        -AdbPath "$HERE/fake/adb" -FastbootPath "$HERE/fake/fastboot" \
        "${defaults[@]}" "$@" > "$FAKE_STATE/out.txt" 2>&1
    echo $? > "$FAKE_STATE/rc"
}
check() {  # check NAME DESCRIPTION COMMAND...
    local name=$1 desc=$2; shift 2
    if ( cd "$T/$name" && eval "$*" ) >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "  ok   $name: $desc"
    else FAIL=$((FAIL + 1)); echo "  FAIL $name: $desc"; fi
}

echo "work dir: $T"

# 1. Full install from Windows (phone already rebooted into LK after EFIESP).
mkdir -p "$T/efiesp/EFI/Microsoft/BOOT" "$T/efiesp/Windows/System32/BOOT"
echo original-bcd > "$T/efiesp/EFI/Microsoft/BOOT/BCD"
run full fastboot '\nYES\nERASE\n' -Mode Full -EfiEsp "$T/efiesp" -OfficialDir "$T/official"
check full 'exit code 0' '[ "$(cat rc)" = 0 ]'
check full 'BCD replaced by the official one' 'cmp -s "$OFFICIAL/DATA/BCD" "$T/efiesp/EFI/Microsoft/BOOT/BCD"'
check full 'LK, Stage2, bootshim, developermenu, ui copied' 'cmp -s "$OFFICIAL/DATA/emmc_appsboot.mbn" "$T/efiesp/emmc_appsboot.mbn" && cmp -s "$OFFICIAL/DATA/Stage2.efi" "$T/efiesp/Stage2.efi" && cmp -s "$OFFICIAL/DATA/bootshim.efi" "$T/efiesp/Windows/System32/BOOT/bootshim.efi" && cmp -s "$OFFICIAL/DATA/developermenu.efi" "$T/efiesp/Windows/System32/BOOT/developermenu.efi" && [ -f "$T/efiesp/Windows/System32/BOOT/ui/boot.ums.waiting.bmpx" ]'
check full 'original BCD backed up' 'grep -q original-bcd "$REPO"/backups/cityman-*/EFIESP/EFI/Microsoft/BOOT/BCD'
check full '15 provisioning partitions pulled + SHA256SUMS' '[ "$(ls "$REPO"/backups/cityman-*/provisioned/*.bin | wc -l)" = 15 ] && ls "$REPO"/backups/cityman-*/provisioned/SHA256SUMS'
check full 'fixed partition.sh (LF) was run' '[ -f partitioned ]'
check full 'official TWRP booted first, then A16 TWRP' 'grep -c "fastboot boot" calls.log | grep -qx 2 && grep -q "fastboot boot .*DATA/twrp.img" calls.log'
check full 'recovery = A16 TWRP, modem = official modem.img' 'grep -qx "recovery $TWRP_SHA" flashed && grep -qx "modem $MODEM_SHA" flashed'
check full 'provision.sh run' '[ -f provisioned ]'
check full 'format data, wipe cache, wipe dalvik' 'diff <(printf "format data\nwipe cache\nwipe dalvik\n") wiped'
check full 'ROM sideloaded after retrying twrp sideload' '[ "$(cat installed)" = "sideload $ROM_SHA" ] && [ "$(cat n-sideload)" = 2 ]'
check full 'rebooted at the end' '[ "$(cat state)" = off ]'
rm -rf "$REPO/backups"

# 2. Full install where LK is missing from aboot after partition.sh.
rm -rf "$T/efiesp"; mkdir -p "$T/efiesp/EFI/Microsoft/BOOT" "$T/efiesp/Windows/System32/BOOT"; echo x > "$T/efiesp/EFI/Microsoft/BOOT/BCD"
FAKE_LK_BAD=1 run full-lk fastboot '\nYES\nERASE\n' -Mode Full -EfiEsp "$T/efiesp" -OfficialDir "$T/official"
check full-lk 'exit code 0' '[ "$(cat rc)" = 0 ]'
check full-lk 'LK copied again with put-lk' '[ -f lk-fixed ] && grep -q "put-lk /tmp/emmc_appsboot.mbn" calls.log'
rm -rf "$REPO/backups"

# 3. Full install, user does not type ERASE: nothing erased.
FAKE_LK_BAD= run full-stop fastboot '\nYES\nno\n' -Mode Full -EfiEsp "$T/efiesp" -OfficialDir "$T/official"
check full-stop 'exit code 1' '[ "$(cat rc)" = 1 ]'
check full-stop 'partition.sh not run' '[ ! -f partitioned ]'
check full-stop 'backup done before asking' '[ "$(ls "$REPO"/backups/cityman-*/provisioned/*.bin | wc -l)" = 15 ]'
rm -rf "$REPO/backups"

# 4. Clean install from Android.
run clean device 'ERASE\n' -Mode Clean
check clean 'exit code 0' '[ "$(cat rc)" = 0 ]'
check clean 'only the A16 TWRP booted, nothing flashed' '[ "$(cat booted-image)" = "$TWRP_SHA" ] && [ ! -f flashed ] && [ ! -f partitioned ]'
check clean 'format data, wipe cache, wipe dalvik' 'diff <(printf "format data\nwipe cache\nwipe dalvik\n") wiped'
check clean 'ROM sideloaded, rebooted' '[ "$(cat installed)" = "sideload $ROM_SHA" ] && [ "$(cat state)" = off ]'

# 5. Clean install, user does not confirm: no wipe, no sideload.
run clean-stop device 'nope\n' -Mode Clean
check clean-stop 'exit code 1, no wipe, no sideload' '[ "$(cat rc)" = 1 ] && [ ! -f wiped ] && [ ! -f installed ]'

# 6. Update (phone on LineageOS 23.2): no wipe.
run update device '' -Mode Update
check update 'exit code 0' '[ "$(cat rc)" = 0 ]'
check update 'no wipe' '[ ! -f wiped ]'
check update 'ROM sideloaded, rebooted' '[ "$(cat installed)" = "sideload $ROM_SHA" ] && [ "$(cat state)" = off ]'

# 7. Update over LineageOS 18.1: asks, user refuses.
FAKE_INSTALLED='sdk=30 lineage=18.1 device=talkman' run update-other device 'no\n' -Mode Update
check update-other 'exit code 1, no sideload' '[ "$(cat rc)" = 1 ] && [ ! -f installed ]'
check update-other 'message about LineageOS 23.2' 'grep -q "not the LineageOS 23.2 cityman build" out.txt'

# 8. Update starting from fastboot.
run update-fb fastboot '' -Mode Update
check update-fb 'exit code 0 from fastboot' '[ "$(cat rc)" = 0 ] && [ "$(cat installed)" = "sideload $ROM_SHA" ]'

# 9. Wrong ROM checksum: stops before touching the phone.
run bad-rom device '' -Mode Update -RomSha256 0000000000000000000000000000000000000000000000000000000000000000
check bad-rom 'exit code 1, phone untouched' '[ "$(cat rc)" = 1 ] && ! grep -qE "fastboot boot|reboot" calls.log'
check bad-rom 'clear message' 'grep -q "does not match its checksum" out.txt'

# 10. Wrong TWRP image (the official one): stops before touching the phone.
run bad-twrp device '' -Mode Update -Twrp "$OFFICIAL/DATA/twrp.img"
check bad-twrp 'exit code 1, phone untouched' '[ "$(cat rc)" = 1 ] && ! grep -qE "fastboot boot|reboot" calls.log'
check bad-twrp 'clear message' 'grep -q "not the expected file" out.txt'

# 11. boot partition differs after the sideload: error, no reboot.
FAKE_BOOT_BAD=1 run bad-boot device '' -Mode Update
check bad-boot 'exit code 1, not rebooted' '[ "$(cat rc)" = 1 ] && [ "$(cat state)" = recovery ]'
check bad-boot 'clear message' 'grep -q "does not match boot.img" out.txt'

# 12. ROM for another device.
python3 -I - "$T/other.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('META-INF/com/android/metadata', 'post-sdk-level=36\npre-device=talkman\n')
    z.writestr('META-INF/com/google/android/update-binary', 'fake')
    z.writestr('boot.img', b'ANDROID!')
PY
run other-dev device '' -Mode Update -Rom "$T/other.zip" -RomSha256 "$(sha256sum "$T/other.zip" | cut -c1-64)"
check other-dev 'exit code 1, message' '[ "$(cat rc)" = 1 ] && grep -q "not for the Lumia 950 XL" out.txt'

# 13. Full install resumed after partitioning (phone in LK).
run resume-modem fastboot '' -Mode Full -Resume Modem -OfficialDir "$T/official"
check resume-modem 'exit code 0, no EFIESP step, no partition.sh' '[ "$(cat rc)" = 0 ] && [ ! -f partitioned ] && ! grep -q "Developer Menu, boot shim" out.txt'
check resume-modem 'recovery + modem written, provisioned, wiped, installed' 'grep -qx "modem $MODEM_SHA" flashed && [ -f provisioned ] && [ -f wiped ] && [ "$(cat installed)" = "sideload $ROM_SHA" ]'
rm -rf "$REPO/backups"

# 14. Full install resumed after EFIESP, phone found in Android-less TWRP state.
run resume-part fastboot 'ERASE\n' -Mode Full -Resume Partition -OfficialDir "$T/official"
check resume-part 'exit code 0, partitioned without EFIESP step' '[ "$(cat rc)" = 0 ] && [ -f partitioned ] && ! grep -q "Developer Menu, boot shim" out.txt'
rm -rf "$REPO/backups"

# 15. -Resume outside Full mode is refused.
run resume-bad device '' -Mode Update -Resume Modem
check resume-bad 'exit code 1, phone untouched' '[ "$(cat rc)" = 1 ] && ! grep -qE "fastboot boot|reboot" calls.log'

rm -rf "$REPO/work" "$REPO/logs"
echo "passed: $PASS, failed: $FAIL (outputs in $T)"
[ $FAIL -eq 0 ]
