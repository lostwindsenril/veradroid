#!/bin/sh
# su_hide (host/*/boot/lib/slim.sh): apps must not see /system/xbin/su. Packed apps (ijiami's libijm_linker: "which su",
# su under /system/xbin/ /system/bin/ /sbin/ ...) kill themselves when it is there (不背单词 5.11.10 on the PW6 emulator:
# SIGSEGV 12/12 starts with su, past the packer once it was renamed). Checks: renamed to vdsu (same inode), idempotent,
# a new image that brings su back is renamed again, HIDE_SU=0 puts it back, called before the container starts.
set -u
R0=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
rc=0; fail() { echo "FAIL $*"; rc=1; }
for h in pw6 k49 legacy; do
    lib=$R0/host/$h/boot/lib/slim.sh
    grep -q '^su_hide()' "$lib" || { fail "$h: no su_hide in slim.sh"; continue; }
    grep -q '^    HIDE_SU=1 ' "$R0/host/$h/boot/lib/settings.sh" || fail "$h: HIDE_SU default missing in settings.sh"
    # called once, after slim_apply and before the container starts
    awk '/^slim_apply$/ { s = NR } /^su_hide$/ { h = NR; n++ } /^container_start/ { c = NR }
         END { exit !(n == 1 && s && h > s && c > h) }' "$R0/host/$h/boot/veradroid.sh" || fail "$h: su_hide not called between slim_apply and container_start"
    R=$T/$h; mkdir -p $R/system/xbin; echo su-binary > $R/system/xbin/su; chmod 755 $R/system/xbin/su
    ino=$(ls -i $R/system/xbin/su | awk '{print $1}')
    out=$( t() { echo "$*"; }; . "$lib"; HIDE_SU=1; su_hide; su_hide )
    [ ! -e $R/system/xbin/su ] || fail "$h: su still there"
    [ "$(ls -i $R/system/xbin/vdsu 2>/dev/null | awk '{print $1}')" = "$ino" ] || fail "$h: vdsu is not the same file"
    [ -x $R/system/xbin/vdsu ] || fail "$h: vdsu lost its mode"
    [ "$(echo "$out" | grep -c 'hidden')" = 1 ] || fail "$h: second run not quiet: $out"
    # an image update brings su back (new inode): renamed over the old vdsu
    echo su-new > $R/system/xbin/su; ( t() { :; }; . "$lib"; su_hide )
    [ ! -e $R/system/xbin/su ] && [ "$(cat $R/system/xbin/vdsu)" = su-new ] || fail "$h: su from a new image not hidden"
    # default (HIDE_SU unset) hides too
    echo su-3 > $R/system/xbin/su; ( t() { :; }; . "$lib"; unset HIDE_SU; su_hide )
    [ ! -e $R/system/xbin/su ] || fail "$h: HIDE_SU unset did not hide"
    # HIDE_SU=0: put back
    ( t() { :; }; . "$lib"; HIDE_SU=0; su_hide )
    [ -f $R/system/xbin/su ] && [ ! -e $R/system/xbin/vdsu ] || fail "$h: HIDE_SU=0 did not put su back"
    # no xbin (demo rootfs): nothing happens, no error
    ( t() { :; }; R=$T/none; . "$lib"; su_hide ) || fail "$h: no xbin dir failed"
done
[ $rc = 0 ] && echo "su-hide-test: ok"
exit $rc
