#!/bin/sh
# Battery level in sync (fix/battery-sync): healthd runs without CAP_WAKE_ALARM (nocap_mount, standby drain fix), so its periodic
# CLOCK_BOOTTIME_ALARM timer is never created and Android's level only moved on the driver's rare battery uevents (PW6 1.03 field
# report "电量显示不同步"). The watchdog writes "change" to the battery's uevent every BAT_POKE_S s while Android is not frozen
# (and right after a thaw); VeraHome takes battery / charging from Android's sticky ACTION_BATTERY_CHANGED (HostLink.status)
# instead of ctl/status, which the host only rewrites on request.
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
for h in pw6 k49; do
    f=host/$h/boot/lib/watchdog.sh
    sh -n $f || fail "syntax $f"
    grep -q '^        if \[ -f \$W/saver_frozen \] || \[ -f \$W/frozen \] || \[ -f \$W/idlefz \]; then BAT_POKE_T=0; else bat_poke_tick; fi$' $f ||
        fail "$h: watchdog loop does not poke the battery (or pokes while frozen)"
    rm -rf $T/*; mkdir -p $T/ps/bat $T/ps/ac
    echo Battery > $T/ps/bat/type; echo USB_DCP > $T/ps/ac/type; : > $T/ps/bat/uevent; : > $T/ps/ac/uevent
    echo 1000.5 1.0 > $T/up; out=$(BAT_UPTIME=$T/up BAT_PS_DIR=$T/ps sh -c "$(awk '/^bat_poke_tick\(\)/,/^}/' $f)"'
        BAT_POKE_S=60; bat_poke_tick; echo "1:$(cat '$T'/ps/bat/uevent)/$(cat '$T'/ps/ac/uevent)"
        : > '$T'/ps/bat/uevent; bat_poke_tick; echo "2:$(cat '$T'/ps/bat/uevent)"
        BAT_POKE_T=0; bat_poke_tick; echo "3:$(cat '$T'/ps/bat/uevent)"')
    echo "$out" | grep -qx '1:change/' || fail "$h: first poke did not write change to the battery only: $out"
    echo "$out" | grep -qx '2:' || fail "$h: poked again within BAT_POKE_S: $out"
    echo "$out" | grep -qx '3:change' || fail "$h: no poke after a thaw (BAT_POKE_T=0): $out"
done
V=android/packages/VeraHome/src/com/veradroid/home
grep -q 'static Map<String, String> status(android.content.Context c)' $V/HostLink.java || fail "HostLink.status missing"
grep -q 'ACTION_BATTERY_CHANGED' $V/HostLink.java || fail "HostLink.status does not read Android's battery"
for f in HomeActivity BlocksHome ReaderActivity BlocksPanel Panel; do
    grep -q 'HostLink.status(' $V/$f.java || fail "$f still shows the battery from ctl/status only"
done
echo "battery-sync: ok"
