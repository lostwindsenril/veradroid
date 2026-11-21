#!/bin/sh
# Gestures the host hands to the desktop (action.sh back / home / panel / switch -> ctl/act.<name>, HostService watches ctl with inotify
# CLOSE_WRITE | MOVED_TO). Field bug 2026-11-20 (Oasis 3, legacy 0.8.12): a swipe made while
# the desktop was not listening yet left ctl/act.panel behind; action.sh used `touch`, which on an existing file only changes the
# times (IN_ATTRIB, no event), so the desktop never saw another panel gesture: every pull-down over an app showed "NO RESPONSE".
# Checks: every action.sh writes a fresh file and renames it (a new inode = MOVED_TO every time, stale file or not), the temporary
# name is not an act.* name, two gestures in a row do not collide, and HostService drops stale act.* files when it starts.
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
n=0
for h in pw6 k49 legacy; do
    a=host/$h/boot/action.sh
    [ -f $a ] || continue
    n=$((n + 1))
    sh -n $a || fail "syntax $a"
    grep -q 'touch \$X/ctl/act\.' $a && fail "$a still touches ctl/act.* (no inotify event when the file is already there)"
    # run the real script against a scratch directory (its paths are fixed: rewrite them), display bridge / host not running
    rm -rf $T/w; mkdir -p $T/w/kfb/ctl $T/sys
    sed -e "s#^W=/dev/shm/veradroid\$#W=$T/w#" -e "s#^SYS=.*#SYS=$T/sys#" -e "s#^AL=.*#AL=$T/w/actions.log#" $a > $T/action.sh
    grep -q "^W=$T/w\$" $T/action.sh || fail "$a: W= line not found (test needs updating)"
    printf "GESTURE_HINT=stuck\nG_TR=switch\n" > $T/sys/settings.conf; : > $T/w/actions.log
    # a stale act.panel from before the desktop listened
    : > $T/w/kfb/ctl/act.panel; old=$(ls -i $T/w/kfb/ctl/act.panel | awk '{print $1}')
    : > $T/w/kfb/ctl/keep; VD=$T/vd sh $T/action.sh panel
    [ -f $T/w/kfb/ctl/act.panel ] || fail "$h: act.panel not written"
    new=$(ls -i $T/w/kfb/ctl/act.panel | awk '{print $1}')
    [ "$new" != "$old" ] || fail "$h: act.panel kept its inode (rename did not happen: the desktop gets no event)"
    # two gestures at once: both arrive, nothing left over, no temporary file named act.*
    rm -f $T/w/kfb/ctl/act.*
    VD=$T/vd sh $T/action.sh tr & VD=$T/vd sh $T/action.sh tr & wait   # top-right corner bound to "switch"
    [ -f $T/w/kfb/ctl/act.switch ] || fail "$h: act.switch not written by two concurrent gestures"
    left=$(ls -a $T/w/kfb/ctl | grep -v '^\.\{1,2\}$' | grep -v '^act\.switch$' | grep -v '^keep$' | grep -v '^actions.log$')
    [ -z "$left" ] || fail "$h: left in ctl: $left"
    # the temporary name must not look like a gesture (HostService acts on any name starting with act.)
    grep -o 'ctl/[.A-Za-z]*act\.\$1\.\$\$' $a | grep -q '^ctl/\.act\.' || fail "$h: temporary file is not .act.<name>.<pid>"
done
[ $n -gt 0 ] || fail "no host action.sh found"
# desktop side: stale gestures are dropped at start, act.* handling deletes the file first
H=android/packages/VeraHome/src/com/veradroid/home/HostService.java
grep -q 'n.startsWith("act.")) { new File(HostLink.CTL + n).delete()' $H || fail "$H does not drop stale act.* files at start"
grep -q 'startsWith("act.")) {' $H || fail "$H has no act.* handler"
awk '/name.startsWith\("act."\)\) \{/{getline; print; exit}' $H | grep -q 'f.delete();' || fail "$H: act.* handler does not delete the file first"
grep -q 'FileObserver.CLOSE_WRITE | FileObserver.MOVED_TO' android/packages/VeraHome/src/com/veradroid/home/CtlWatch.java || fail "CtlWatch no longer watches MOVED_TO"
echo "gesture-ctl-test: ok ($n hosts)"
