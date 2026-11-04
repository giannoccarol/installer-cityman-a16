#!/sbin/sh
# cityman-a16-helper.sh - runs inside TWRP on the Lumia 950 XL (cityman).
#
# installer.ps1 pushes this file to /tmp and calls it over adb. The adbd of the
# Android4Lumia950 TWRP does not return remote exit codes, so every command ends
# with one line that the installer reads:
#   RESULT=OK[:message]   or   RESULT=FAIL:message
# Other output lines are shown to the user (SHA/LOG lines are parsed).
#
# POSIX sh, busybox applets only (TWRP 3.7.0_9-0 ramdisk).

BYNAME=${CITYMAN_BYNAME:-/dev/block/platform/soc.0/f9824900.sdhci/by-name}
BOOTDEVICE=${CITYMAN_BOOTDEVICE:-/dev/block/bootdevice/by-name}
SYSBLOCK=${CITYMAN_SYSBLOCK:-/sys/class/block}
DEVBLOCK=${CITYMAN_DEVBLOCK:-/dev/block}
DISK=${CITYMAN_DISK:-/dev/block/mmcblk0}

# Partitions dumped by the official partition.sh (dump_provisioned).
PROVISIONED="APDP DBI DDR DPO DPP LIMITS MODEM_FS1 MODEM_FS2 MODEM_FSC MODEM_FSG MSADP SEC SSD UEFI_BS_NV UEFI_RT_NV"
# Partitions created by the official partition.sh.
ANDROID_PARTS="aboot boot recovery misc modem cache persist persistent fsc fsg metadata ssd modemst1 modemst2 vendor system userdata"
# Partitions the official partition.sh deletes.
WINDOWS_PARTS="MainOS Data MMOS"
# Copies made by the official provision.sh (source:destination).
MODEM_COPIES="MODEM_FS1:modemst1 MODEM_FS2:modemst2 MODEM_FSC:fsc MODEM_FSG:fsg SSD:ssd"

ok() {
    if [ -n "$1" ]; then echo "RESULT=OK:$1"; else echo "RESULT=OK"; fi
    exit 0
}
fail() {
    echo "RESULT=FAIL:$1"
    exit 1
}

sha_stdin() { sha256sum | cut -d' ' -f1; }
sha_file() { sha256sum < "$1" | cut -d' ' -f1; }

# GPT partition names as the kernel sees them.
part_names() {
    for u in "$SYSBLOCK"/mmcblk0p*/uevent; do
        [ -f "$u" ] && sed -n 's/^PARTNAME=//p' "$u"
    done
}
has_part() { part_names | grep -qx "$1"; }
# Partition name -> device node (/dev/block/mmcblk0pN).
part_dev() {
    for u in "$SYSBLOCK"/mmcblk0p*/uevent; do
        [ -f "$u" ] || continue
        if grep -qx "PARTNAME=$1" "$u"; then
            echo "$DEVBLOCK/$(sed -n 's/^DEVNAME=//p' "$u")"
            return 0
        fi
    done
    return 1
}
need_tool() {
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || fail "$t is missing in this TWRP"
    done
}

# Full install, before partition.sh: the phone must still have its Windows layout.
cmd_check_windows() {
    need_tool parted dd sha256sum mkfs.fat mke2fs
    for p in $PROVISIONED; do
        has_part "$p" || fail "partition $p not found: this does not look like a Lumia 950 XL with Windows"
        [ -e "$BYNAME/$p" ] || fail "$BYNAME/$p is missing"
    done
    has_part EFIESP || fail "EFIESP partition not found"
    has_part userdata && fail "the phone already has Android partitions (userdata): use the Clean or Update mode"
    # partition.sh finds MainOS, Data and MMOS with a substring grep on 'parted print':
    # each name must match at most one line.
    pp=$(parted "$DISK" print 2>/dev/null | grep -Ev '^(Model:|Disk|Sector size|Partition Table|Number)')
    [ -n "$pp" ] || fail "parted cannot read the partition table"
    found=""
    for p in $WINDOWS_PARTS; do
        n=$(echo "$pp" | grep -c "$p")
        [ "$n" -le 1 ] || fail "more than one partition matches '$p': the official partition script cannot handle this layout"
        has_part "$p" && found="$found $p"
    done
    [ -n "$found" ] || fail "no Windows partition (MainOS, Data, MMOS) found"
    ok "${found# }"
}

# Full install: copy the provisioning partitions to DIR and print their SHA-256.
cmd_backup() {
    dir=$1
    [ -n "$dir" ] || fail "usage: backup DIR"
    rm -rf "$dir"
    mkdir -p "$dir" || fail "cannot create $dir"
    for p in $PROVISIONED; do
        dd if="$BYNAME/$p" of="$dir/$p.bin" bs=65536 2>/dev/null || fail "cannot read partition $p"
        a=$(sha_file "$BYNAME/$p")
        b=$(sha_file "$dir/$p.bin")
        if [ -z "$a" ] || [ "$a" != "$b" ]; then
            fail "the copy of $p does not match the partition"
        fi
        echo "SHA $b $p.bin"
    done
    ok
}

# LK (emmc_appsboot.mbn) in the aboot partition; $1 = expected SHA-256.
lk_matches() {
    dev=$(part_dev aboot) || return 1
    mnt=/tmp/cityman-aboot
    mkdir -p "$mnt"
    umount "$mnt" 2>/dev/null
    mount -t vfat -o ro "$dev" "$mnt" 2>/dev/null || return 1
    h=""
    [ -f "$mnt/emmc_appsboot.mbn" ] && h=$(sha_file "$mnt/emmc_appsboot.mbn")
    umount "$mnt" 2>/dev/null
    [ "$h" = "$1" ]
}

# Android partitions present. With LKSHA (full install, after partition.sh): also
# no Windows partition left and LK in aboot.
cmd_check_android() {
    lk_sha=$1
    sync
    if [ -n "$lk_sha" ]; then
        # partition.sh leaves aboot and EFIESP mounted.
        umount /aboot 2>/dev/null
        umount /efiesp 2>/dev/null
    fi
    for p in $ANDROID_PARTS; do
        has_part "$p" || fail "partition $p is missing"
    done
    if [ -n "$lk_sha" ]; then
        for p in $WINDOWS_PARTS; do
            has_part "$p" && fail "Windows partition $p still exists"
        done
        lk_matches "$lk_sha" || fail "LK: emmc_appsboot.mbn is missing or different in the aboot partition"
    fi
    ok
}

# Full install repair: copy LK (FILE, checked against SHA) into aboot.
cmd_put_lk() {
    file=$1
    want=$2
    [ -f "$file" ] || fail "usage: put-lk FILE SHA256"
    [ "$(sha_file "$file")" = "$want" ] || fail "the LK file sent to the phone is damaged"
    dev=$(part_dev aboot) || fail "aboot partition not found"
    mnt=/tmp/cityman-aboot
    mkdir -p "$mnt"
    umount "$mnt" 2>/dev/null
    if ! mount -t vfat "$dev" "$mnt" 2>/dev/null; then
        # Same as partition.sh does for aboot.
        mkfs.fat "$dev" >/dev/null 2>&1 || fail "cannot format the aboot partition"
        mount -t vfat "$dev" "$mnt" || fail "cannot mount the aboot partition"
    fi
    cp "$file" "$mnt/emmc_appsboot.mbn" || { umount "$mnt"; fail "cannot copy LK to aboot"; }
    sync
    umount "$mnt" || fail "cannot unmount aboot"
    lk_matches "$want" || fail "LK: still wrong after copying it again"
    ok
}

# Before the official provision.sh.
cmd_pre_provision() {
    need_tool parted hexdump dd
    for p in DPP persist MODEM_FS1 MODEM_FS2 MODEM_FSC MODEM_FSG SSD modemst1 modemst2 fsc fsg ssd; do
        has_part "$p" || fail "partition $p not found"
    done
    for c in $MODEM_COPIES; do
        for p in ${c%%:*} ${c##*:}; do
            [ -e "$BOOTDEVICE/$p" ] || fail "$BOOTDEVICE/$p is missing"
        done
    done
    ok
}

# After the official provision.sh: MAC files in persist, modem copies in place.
cmd_check_provision() {
    pdev=$(part_dev persist) || fail "persist partition not found"
    mnt=/tmp/cityman-persist
    mkdir -p "$mnt"
    umount "$mnt" 2>/dev/null
    mount -o ro "$pdev" "$mnt" 2>/dev/null || fail "cannot mount persist"
    wl=$(cat "$mnt/wlan_mac.bin" 2>/dev/null)
    bt=$(cat "$mnt/bdaddr.txt" 2>/dev/null)
    umount "$mnt" 2>/dev/null
    for c in $MODEM_COPIES; do
        src=${c%%:*}
        dst=${c##*:}
        s1=$(blockdev --getsize64 "$BOOTDEVICE/$src" 2>/dev/null)
        s2=$(blockdev --getsize64 "$BOOTDEVICE/$dst" 2>/dev/null)
        [ -n "$s1" ] && [ -n "$s2" ] || fail "cannot read the size of $src or $dst"
        size=$s1
        [ "$s2" -lt "$size" ] && size=$s2
        a=$(head -c "$size" "$BOOTDEVICE/$src" | sha_stdin)
        b=$(head -c "$size" "$BOOTDEVICE/$dst" | sha_stdin)
        [ "$a" = "$b" ] || fail "$dst does not contain a copy of $src (modem data)"
    done
    n=$(echo "$wl" | grep -cE '^Intf[0-3]MacAddress=[0-9A-F]{12}$')
    [ "$n" = 4 ] || fail "persist/wlan_mac.bin (Wi-Fi MAC) was not written correctly"
    echo "$bt" | grep -qE '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' || fail "persist/bdaddr.txt (Bluetooth MAC) was not written correctly"
    ok
}

# Update mode: what is installed now (reads the system partition, read-only).
cmd_installed_version() {
    mnt=/tmp/cityman-system
    mkdir -p "$mnt"
    umount "$mnt" 2>/dev/null
    mount -t ext4 -o ro "$BYNAME/system" "$mnt" 2>/dev/null || fail "cannot mount the system partition"
    props=""
    for f in "$mnt/system/build.prop" "$mnt/system/product/etc/build.prop" \
             "$mnt/build.prop" "$mnt/product/etc/build.prop"; do
        [ -f "$f" ] && props="$props $f"
    done
    if [ -z "$props" ]; then
        umount "$mnt" 2>/dev/null
        fail "no build.prop in the system partition"
    fi
    # shellcheck disable=SC2086
    sdk=$(sed -n 's/^ro\.build\.version\.sdk=//p' $props | head -n 1)
    # shellcheck disable=SC2086
    los=$(sed -n 's/^ro\.lineage\.build\.version=//p' $props | head -n 1)
    # shellcheck disable=SC2086
    dev=$(sed -n 's/^ro\.lineage\.device=//p' $props | head -n 1)
    # Google apps (NikGapps, MindTheGapps, ...): GmsCore in priv-app or its permissions file.
    gapps=no
    for d in "$mnt/system" "$mnt" "$mnt/system/product" "$mnt/product" \
             "$mnt/system/system_ext" "$mnt/system_ext"; do
        if [ -f "$d/etc/permissions/com.google.android.gms.xml" ]; then gapps=yes; fi
        for g in "$d"/priv-app/*GmsCore*; do
            [ -e "$g" ] && gapps=yes
        done
    done
    umount "$mnt" 2>/dev/null
    ok "sdk=$sdk lineage=$los device=$dev gapps=$gapps"
}

# Number of lines in the TWRP log, so that a later sideload-result reads only
# the lines of the next installation.
cmd_log_lines() {
    log=/tmp/recovery.log
    if [ -f "$log" ]; then ok "$(wc -l < "$log" | tr -d ' ')"; fi
    ok 0
}

# After 'twrp format data': /data must not hold an Android install any more.
cmd_data_check() {
    mountpoint -q /data || mount /data 2>/dev/null
    if mountpoint -q /data; then
        [ -e /data/system ] && fail "/data still contains Android data after the format"
        ok "formatted"
    fi
    ok "not-mounted"
}

# After adb sideload: result of the installation in the TWRP log.
# FROM = number of log lines before this sideload (log-lines), default 0.
cmd_sideload_result() {
    from=${1:-0}
    case "$from" in
        *[!0-9]*) fail "usage: sideload-result [FROM_LINE]" ;;
    esac
    log=/tmp/recovery.log
    [ -f "$log" ] || fail "TWRP log /tmp/recovery.log not found"
    part=/tmp/cityman-sideload.log
    tail -n +$((from + 1)) "$log" > "$part"
    grep -E 'script succeeded|script aborted|Updater process ended|Install took|E[0-9]{4}:|Error installing zip' "$part" \
        | tail -n 8 | sed 's/^/LOG /'
    if grep -qE 'script aborted|Updater process ended with ERROR|Error installing zip' "$part"; then
        fail "TWRP reports that the installation failed (see the LOG lines)"
    fi
    grep -qE 'Updater process ended with RC=0|script succeeded' "$part" \
        || fail "the TWRP log has no success line for the installation"
    ok
}

# SHA-256 of the first SIZE bytes of the boot partition.
cmd_boot_sha() {
    size=$1
    case "$size" in
        '' | *[!0-9]*) fail "usage: boot-sha SIZE" ;;
    esac
    [ -e "$BYNAME/boot" ] || fail "boot partition not found"
    if [ $((size % 4096)) -eq 0 ]; then
        h=$(dd if="$BYNAME/boot" bs=4096 count=$((size / 4096)) 2>/dev/null | sha_stdin)
    else
        h=$(head -c "$size" "$BYNAME/boot" | sha_stdin)
    fi
    [ -n "$h" ] || fail "cannot read the boot partition"
    ok "$h"
}

cmd=$1
[ $# -gt 0 ] && shift
case "$cmd" in
    check-windows) cmd_check_windows ;;
    backup) cmd_backup "$@" ;;
    check-android) cmd_check_android "$@" ;;
    put-lk) cmd_put_lk "$@" ;;
    pre-provision) cmd_pre_provision ;;
    check-provision) cmd_check_provision ;;
    installed-version) cmd_installed_version ;;
    data-check) cmd_data_check ;;
    log-lines) cmd_log_lines ;;
    sideload-result) cmd_sideload_result "$@" ;;
    boot-sha) cmd_boot_sha "$@" ;;
    *) fail "unknown helper command '$cmd'" ;;
esac
