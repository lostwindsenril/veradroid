#!/bin/sh
# Bottom edge in thirds (G_EDGE_THIRDS, docs/host-settings.md): veradroid-input reads the keys, every host defines,
# publishes, accepts and passes them on (gestures_write), and action.sh runs "eb <action>" through its whitelist
# (appopt -> ctl/act.appopt for VeraHome). The touch behaviour itself is in tests/vinput/run.py thirds_cases (Linux).
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
KEYS="G_EDGE_THIRDS G_EB_L G_EB_M G_EB_R G_EB_HOLD G_EB_HOLD_MS"
grep -q '"G_EDGE_THIRDS"' input/vinput.c && grep -q '"G_EB_HOLD_MS"' input/vinput.c || fail "vinput.c does not read the thirds keys"
for k in G_EB_L G_EB_M G_EB_R G_EB_HOLD; do grep -q "\"$k\"" input/vinput.c || fail "vinput.c: no $k"; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for h in $(ls -d host/*/ | sed 's|host/||; s|/||'); do
    S=host/$h/boot/lib/settings.sh A=host/$h/boot/action.sh
    [ -f $S ] && [ -f $A ] || continue
    for k in $KEYS; do
        grep -q "^    $k=" $S || fail "$S: no default for $k"
        [ "$(grep -c "for k in .* $k .*; do" $S)" -ge 2 ] || fail "$S: $k not in the publish / apply key lists"
        grep -q "echo \"$k=" $S || fail "$S: gestures_write does not pass $k"
    done
    grep -q '^    G_EDGE_THIRDS=0 ' $S || fail "$S: thirds must default to off (the whole bottom edge stays back)"
    # gestures_write output with the defaults and with user values
    fn=$(sed -n '/^gestures_write() {/,/^}/p' $S)
    ( W=$T; rot_deg() { echo 0; }; eval "$fn"; gestures_write ) || fail "$S: gestures_write failed"
    for l in G_EDGE_THIRDS=0 G_EB_L=appopt G_EB_M=home G_EB_R=back G_EB_HOLD=switch G_EB_HOLD_MS=500; do
        grep -qx "$l" $T/gestures || fail "$S: gestures file has no $l"
    done
    ( W=$T; rot_deg() { echo 0; }; G_EDGE_THIRDS=1 G_EB_L=panel G_EB_HOLD=none; eval "$fn"; gestures_write )
    grep -qx G_EDGE_THIRDS=1 $T/gestures && grep -qx G_EB_L=panel $T/gestures && grep -qx G_EB_HOLD=none $T/gestures || fail "$S: user values not passed"
    # action.sh: run it against a scratch W / SYS, hints off
    mkdir -p $T/$h/kfb/ctl $T/$h/sys; echo GESTURE_HINT=off > $T/$h/sys/settings.conf; : > $T/$h/al.log
    sed -e "s|^W=/dev/shm/veradroid\$|W=$T/$h|" -e "s|^SYS=.*|SYS=$T/$h/sys|" -e "s|^AL=.*|AL=$T/$h/al.log|" $A > $T/$h/action.sh
    grep -q "^W=$T/$h\$" $T/$h/action.sh || fail "$A: W= line moved, test cannot redirect it"
    for a in appopt home switch panel back; do
        rm -f $T/$h/kfb/ctl/act.*
        sh $T/$h/action.sh eb $a || fail "$A eb $a: exit $?"
        [ -e $T/$h/kfb/ctl/act.$a ] || fail "$A: eb $a did not leave ctl/act.$a"
    done
    rm -f $T/$h/kfb/ctl/*
    sh $T/$h/action.sh eb 'x;touch ../pwn'; sh $T/$h/action.sh eb rm
    [ -z "$(ls $T/$h/kfb/ctl)" ] && [ ! -e $T/$h/kfb/pwn ] || fail "$A: eb with an unknown action did something"
    # appopt also works for a corner (same whitelist)
    echo "G_TR=appopt" >> $T/$h/sys/settings.conf; sh $T/$h/action.sh tr; [ -e $T/$h/kfb/ctl/act.appopt ] || fail "$A: G_TR=appopt"
    echo "ok $h"
done
echo "edge-thirds: ok"
