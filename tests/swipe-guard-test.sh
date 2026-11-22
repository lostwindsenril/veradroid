#!/bin/sh
# Kindle 2024 / KT6 "panel vanished, nothing responds" (fix/1105-panel-swipe): the host must pass KFB_SWIPE to the display
# bridge (start argument and SWIPEOK on every settings change), default it off on kt6, and the bridge must parse SWIPEOK /
# ANIMHOLD before the ANIM prefix. Behaviour (swipe dropped / automatic switch-off + full refresh) is in tests/epd-test.sh.
set -u
R=$(cd "$(dirname "$0")/.." && pwd); fail=0
need() { grep -qE -e "$2" "$1" || { echo "FAIL $(echo "$1" | sed "s#$R/##"): $3"; fail=1; }; }
for h in pw6 k49; do
    S=$R/host/$h/boot/lib/settings.sh; C=$R/host/$h/boot/lib/container.sh
    need "$S" '^    KFB_SWIPE=1 ' "$h: KFB_SWIPE default 1"
    need "$S" '= kt6 \] && KFB_SWIPE=0' "$h: kt6 defaults to KFB_SWIPE=0"
    need "$S" 'epd_send SWIPEOK \$\{KFB_SWIPE:-1\}' "$h: settings_apply sends SWIPEOK"
    [ "$(grep -c 'KFB_ANIM_MIN KFB_SWIPE KFB_PWRDOWN' "$S")" = 2 ] || { echo "FAIL $h: KFB_SWIPE not in the publish + apply key lists"; fail=1; }
    need "$C" '--swipe \$\{KFB_SWIPE:-1\}' "$h: container.sh starts the bridge with --swipe"
    # the kt6 default comes before settings.conf (the user's choice wins)
    a=$(grep -n '= kt6 \] && KFB_SWIPE=0' "$S" | cut -d: -f1); b=$(grep -n '\. "\$SYS/settings.conf"' "$S" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || { echo "FAIL $h: kt6 default is not applied before settings.conf"; fail=1; }
done
E=$R/display/epd.c
l_anim=$(grep -n 'strncmp(line, "ANIM", 4)' "$E" | cut -d: -f1); l_hold=$(grep -n 'strncmp(line, "ANIMHOLD", 8)' "$E" | cut -d: -f1); l_ok=$(grep -n 'strncmp(line, "SWIPEOK", 7)' "$E" | cut -d: -f1)
[ "$(echo "$l_hold" | wc -l | tr -d ' ')" = 1 ] && [ "$l_hold" -lt "$l_anim" ] || { echo "FAIL epd.c: ANIMHOLD must be parsed (once) before the ANIM prefix"; fail=1; }
[ -n "$l_ok" ] && [ "$l_ok" -lt "$l_anim" ] || { echo "FAIL epd.c: SWIPEOK must be parsed"; fail=1; }
need "$E" '"--swipe"' 'epd.c: --swipe argument'
need "$E" 'if \(flash \|\| !g_is_mtk \|\| !swipe_ok \|\| swipe_broken\) return 0;' 'epd.c: maybe_animate honours the switch'
need "$E" 'swipe_ok && !swipe_broken && sscanf\(line \+ 5' 'epd.c: SWIPE one-shot honours the switch'
[ "$fail" = 0 ] && echo "SWIPE GUARD CHECKS OK" || echo "SWIPE GUARD FAILURES"
exit "$fail"
