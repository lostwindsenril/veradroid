#!/bin/sh
# Standby drain fix (fix/standby-drain): healthd runs through bin/vdnocap without CAP_BLOCK_SUSPEND / CAP_WAKE_ALARM, so a
# frozen Android cannot hold a kernel wakeup source (EPOLLWAKEUP) and block the Kindle's suspend all night.
#   static part (any OS): the hosts mount it, identically, after alarmfix_mount; the bundles carry the binary; the
#   container as a whole keeps its capabilities (zygote capset()s CAP_BLOCK_SUSPEND for system_server).
#   Linux part: vdnocap.c builds; "vdnocap PROG" drops the two caps from the bounding set (as root) and execs PROG;
#   called by another name it execs /dev/vdlib/<name>.real.
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
for h in pw6 k49 legacy; do
    c=host/$h/boot/lib/container.sh
    grep -q '^nocap_mount() {' $c || fail "$c: no nocap_mount"
    awk '/^        alarmfix_mount /{a=NR} /^        nocap_mount /{n=NR} END{exit !(a && n == a + 1)}' $c || fail "$c: run_in_ns does not call nocap_mount right after alarmfix_mount"
    sed -n '/^nocap_mount() {/,/^}/p' $c > /tmp/vd-nc.$$.$h
    grep -q 'capsh\|CAPBSET' $c && fail "$c: drops capabilities for the whole container (zygote would abort)"
    grep -q 'mount --bind \$R/sbin/healthd \$R/dev/vdlib/healthd.real' $c || fail "$c: original healthd not kept at /dev/vdlib/healthd.real"
    grep -q 'vdnocap /bin/sh -c' $c || fail "$c: wrapper is mounted without a test run"
done
cmp -s /tmp/vd-nc.$$.pw6 /tmp/vd-nc.$$.k49 && cmp -s /tmp/vd-nc.$$.pw6 /tmp/vd-nc.$$.legacy || { rm -f /tmp/vd-nc.$$.*; fail "nocap_mount differs between hosts"; }
rm -f /tmp/vd-nc.$$.*
for h in pw6 k49; do
    b=host/$h/bin/vdnocap
    [ -s $b ] || continue   # prebuilt binaries are not in the source tree
    head -c 20 $b | od -An -tx1 | tr -d ' \n' | grep -q '^7f454c46010101' || fail "$b is not a 32-bit LSB ELF"
    [ "$(od -An -j18 -N2 -tu2 $b | tr -d ' ')" = 40 ] || fail "$b is not ARM"
    od -An -j16 -N2 -tu2 $b | tr -d ' ' | grep -qx 2 || fail "$b is not a static executable (ET_EXEC)"
done
[ ! -s host/pw6/bin/vdnocap ] || cmp -s host/pw6/bin/vdnocap host/k49/bin/vdnocap || fail "pw6 / k49 vdnocap differ"
[ -f tools/vdnocap/vdnocap.c ] && [ -f tools/cross/build-vdnocap.sh ] || fail "vdnocap source / build script missing"
grep -q 'PR_CAPBSET_DROP' tools/vdnocap/vdnocap.c || fail "vdnocap.c does not drop from the bounding set"
if [ "$(uname -s)" = Linux ] && command -v cc >/dev/null 2>&1; then
    T=$(mktemp -d) || exit 2; trap 'rm -rf "$T"' EXIT
    cc -O2 -Wall -o $T/vdnocap tools/vdnocap/vdnocap.c || fail "vdnocap.c does not build"
    out=$($T/vdnocap /bin/sh -c 'echo ran; grep ^CapBnd /proc/self/status' 2>/dev/null) || fail "vdnocap PROG did not run PROG"
    case "$out" in ran*) ;; *) fail "vdnocap PROG output: $out" ;; esac
    if [ "$(id -u)" = 0 ]; then
        bnd=$(echo "$out" | awk '/CapBnd/ { print $2 }')
        [ $(( (0x$bnd >> 35) & 3 )) = 0 ] || fail "CAP_WAKE_ALARM / CAP_BLOCK_SUSPEND still in the bounding set: $bnd"
    fi
    ln -s vdnocap $T/healthd
    err=$($T/healthd 2>&1); rc=$?
    [ $rc = 127 ] && echo "$err" | grep -q '/dev/vdlib/healthd.real' || fail "called as healthd it did not exec /dev/vdlib/healthd.real (rc=$rc: $err)"
fi
echo "nocap: ok"
