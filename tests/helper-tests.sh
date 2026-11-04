#!/bin/sh
# Unit tests for device/cityman-a16-helper.sh on a fake sysfs/by-name tree.
# Run with the shell to test, e.g. busybox:  docker run --rm -v "$PWD:/r:ro" alpine sh /r/tests/helper-tests.sh
# Commands that need mount (check-provision, installed-version, LK checks) are not covered.
HERE=$(cd "$(dirname "$0")" && pwd)
H="$HERE/../device/cityman-a16-helper.sh"
T=$(mktemp -d)
PASS=0; FAIL=0
export CITYMAN_SYSBLOCK="$T/sys" CITYMAN_BYNAME="$T/byname" CITYMAN_DEVBLOCK="$T/dev" CITYMAN_DISK="$T/disk"
mkdir -p "$T/bin" "$T/byname"
for t in mkfs.fat mke2fs; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$t"; chmod +x "$T/bin/$t"; done
# Fake parted: prints one line per partition name, like 'parted print'.
cat > "$T/bin/parted" <<'P'
#!/bin/sh
echo "Model: MMC (sd/mmc)"; echo "Number  Start  End  Size  File system  Name  Flags"
n=1; for u in "$CITYMAN_SYSBLOCK"/mmcblk0p*/uevent; do echo " $n  1MB  2MB  1MB  $(sed -n 's/^PARTNAME=//p' "$u")"; n=$((n+1)); done
P
chmod +x "$T/bin/parted"
export PATH="$T/bin:$PATH"

mkparts() {  # mkparts NAME... : fake sysfs + by-name entries with random content
    rm -rf "$T/sys" "$T/byname"; mkdir -p "$T/sys" "$T/byname"
    i=1
    for n in "$@"; do
        mkdir -p "$T/sys/mmcblk0p$i"
        printf 'MAJOR=179\nMINOR=%s\nDEVNAME=mmcblk0p%s\nDEVTYPE=partition\nPARTN=%s\nPARTNAME=%s\n' $i $i $i "$n" > "$T/sys/mmcblk0p$i/uevent"
        dd if=/dev/urandom of="$T/byname/$n" bs=1024 count=$((i + 3)) 2>/dev/null
        i=$((i + 1))
    done
}
expect() {  # expect DESC PATTERN COMMAND...
    desc=$1; pat=$2; shift 2
    out=$("$@" 2>&1)
    last=$(echo "$out" | tail -n 1)
    if echo "$last" | grep -qE "$pat"; then PASS=$((PASS + 1)); echo "  ok   $desc"
    else FAIL=$((FAIL + 1)); echo "  FAIL $desc"; echo "$out" | sed 's/^/       /'; fi
}

PROV="APDP DBI DDR DPO DPP LIMITS MODEM_FS1 MODEM_FS2 MODEM_FSC MODEM_FSG MSADP SEC SSD UEFI_BS_NV UEFI_RT_NV"
ANDR="aboot boot recovery misc modem cache persist persistent fsc fsg metadata ssd modemst1 modemst2 vendor system userdata"

mkparts $PROV EFIESP MainOS Data
expect 'check-windows: MainOS and Data found' '^RESULT=OK:MainOS Data$' sh "$H" check-windows
mkparts $PROV EFIESP Data
expect 'check-windows: WOA layout (Data only)' '^RESULT=OK:Data$' sh "$H" check-windows
mkparts $PROV EFIESP Data userdata
expect 'check-windows: refuses a phone with Android partitions' '^RESULT=FAIL:.*userdata' sh "$H" check-windows
mkparts $PROV EFIESP Data MyData
expect 'check-windows: refuses names partition.sh would confuse' "^RESULT=FAIL:more than one partition matches 'Data'" sh "$H" check-windows
mkparts APDP DBI EFIESP Data
expect 'check-windows: refuses a layout without provisioning partitions' '^RESULT=FAIL:partition DDR not found' sh "$H" check-windows
mkparts $PROV EFIESP
expect 'check-windows: refuses when no Windows partition is left' '^RESULT=FAIL:no Windows partition' sh "$H" check-windows

mkparts $PROV EFIESP Data
expect 'backup: 15 partitions' '^RESULT=OK$' sh "$H" backup "$T/bk"
n=$(ls "$T/bk" | wc -l); ok=1
for p in $PROV; do cmp -s "$T/byname/$p" "$T/bk/$p.bin" || ok=0; done
if [ "$n" -eq 15 ] && [ $ok = 1 ]; then PASS=$((PASS + 1)); echo "  ok   backup: copies identical"; else FAIL=$((FAIL + 1)); echo "  FAIL backup: copies"; fi
lines=$(sh "$H" backup "$T/bk" | grep -c '^SHA [0-9a-f]\{64\} [A-Z0-9_]*\.bin$')
if [ "$lines" -eq 15 ]; then PASS=$((PASS + 1)); echo "  ok   backup: 15 SHA lines"; else FAIL=$((FAIL + 1)); echo "  FAIL backup: $lines SHA lines"; fi
rm -f "$T/byname/SEC"
expect 'backup: fails if a partition cannot be read' '^RESULT=FAIL:' sh "$H" backup "$T/bk"

mkparts $PROV EFIESP $ANDR
expect 'check-android: all partitions' '^RESULT=OK$' sh "$H" check-android
mkparts $PROV EFIESP aboot boot recovery
expect 'check-android: missing partitions' '^RESULT=FAIL:partition misc is missing' sh "$H" check-android

mkparts boot
want=$(head -c 8192 "$T/byname/boot" | sha256sum | cut -d' ' -f1)
expect 'boot-sha: size multiple of 4096' "^RESULT=OK:$want$" sh "$H" boot-sha 8192
want=$(head -c 5000 "$T/byname/boot" | sha256sum | cut -d' ' -f1)
expect 'boot-sha: other size' "^RESULT=OK:$want$" sh "$H" boot-sha 5000
expect 'boot-sha: rejects a bad size' '^RESULT=FAIL:usage' sh "$H" boot-sha 12a

if [ -w /tmp ] && [ ! -e /tmp/recovery.log ]; then
    printf 'I:Installing zip\nscript succeeded: result was [1.000000]\nUpdater process ended with RC=0\nInstall took 211 second(s).\n' > /tmp/recovery.log
    expect 'sideload-result: success' '^RESULT=OK$' sh "$H" sideload-result
    printf 'E3004: This package is for device: cityman\nscript aborted: E3004\nUpdater process ended with ERROR: 1\nError installing zip file\n' > /tmp/recovery.log
    expect 'sideload-result: abort' '^RESULT=FAIL:TWRP reports' sh "$H" sideload-result
    printf 'I:something else\n' > /tmp/recovery.log
    expect 'sideload-result: no result line' '^RESULT=FAIL:the TWRP log has no success line' sh "$H" sideload-result
    # ROM installed (4 lines), then GApps: only the lines after the ROM count.
    printf 'I:Installing zip\nscript succeeded: result was [1.000000]\nUpdater process ended with RC=0\nInstall took 211 second(s).\n' > /tmp/recovery.log
    expect 'log-lines: line count' '^RESULT=OK:4$' sh "$H" log-lines
    printf 'I:Installing zip\nUpdater process ended with ERROR: 1\nError installing zip file\n' >> /tmp/recovery.log
    expect 'sideload-result FROM: GApps failure not hidden by the ROM' '^RESULT=FAIL:TWRP reports' sh "$H" sideload-result 4
    printf 'I:Installing zip\nI:no result yet\n' > /tmp/recovery.log
    printf 'I:Installing zip\nUpdater process ended with RC=0\n' >> /tmp/recovery.log
    expect 'sideload-result FROM: success after FROM' '^RESULT=OK$' sh "$H" sideload-result 2
    printf 'I:Installing zip\nUpdater process ended with RC=0\nI:Installing zip\n' > /tmp/recovery.log
    expect 'sideload-result FROM: earlier success does not count' '^RESULT=FAIL:the TWRP log has no success line' sh "$H" sideload-result 2
    expect 'sideload-result FROM: rejects a bad value' '^RESULT=FAIL:usage' sh "$H" sideload-result 2x
    rm -f /tmp/recovery.log /tmp/cityman-sideload.log
else
    echo "  skip sideload-result (/tmp/recovery.log exists or /tmp not writable)"
fi
expect 'unknown command' "^RESULT=FAIL:unknown helper command 'nope'" sh "$H" nope

rm -rf "$T"
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
