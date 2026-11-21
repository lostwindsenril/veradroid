#!/bin/sh
# Legacy field reports 2026-11-20 (no device): PW4 dark-area stripes (hardware dithering off by default, one-time
# migration), Oasis 3 "本地安装不了软件" (unknown sources allowed every boot, SECURITY_SETTINGS handled by VeraHome),
# Oasis 3 掌阅 ignores the page keys (PAGE_KEYS_MAP volume|page|dpad, default volume, applied at once).
set -u
cd "$(dirname "$0")/.." || exit 2
L=host/legacy/boot/lib
fail=0
bad() { echo "FAIL: $*"; fail=1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/vdlf.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
t() { echo "$*" >> "$T/log"; }

# 1. dithering: the legacy default is off; PW4 and the 4.1 models do not turn it back on
grep -q '^KFB_DITHER=0 ' host/legacy/models/old-base.conf || bad "old-base.conf: KFB_DITHER is not 0"
for m in pw4 kt4 oa2 ko3; do grep -q '^KFB_DITHER=[1-9]' host/legacy/models/$m.conf && bad "$m.conf turns hardware dithering on"; done
# dither_migrate: drops a stored 3 once, keeps a later choice
eval "$(awk '/^dither_migrate\(\) \{/{f=1} f{print} f&&/^}/{exit}' $L/settings.sh)"
type dither_migrate >/dev/null 2>&1 || bad "settings.sh: no dither_migrate"
grep -q '\[ "$MODEL_SUB" = pw4 \] && dither_migrate' $L/settings.sh || bad "settings_load does not run dither_migrate on PW4"
SYS=$T/sys; mkdir -p $SYS
printf 'KFB_CONTRAST=2.2\nKFB_DITHER=3\nKFB_FLASH=3\n' > $SYS/settings.conf
dither_migrate
grep -q '^KFB_DITHER=' $SYS/settings.conf && bad "dither_migrate kept KFB_DITHER=3"
grep -q '^KFB_CONTRAST=2.2$' $SYS/settings.conf && grep -q '^KFB_FLASH=3$' $SYS/settings.conf || bad "dither_migrate lost other settings"
echo 'KFB_DITHER=3' >> $SYS/settings.conf
dither_migrate
grep -q '^KFB_DITHER=3$' $SYS/settings.conf || bad "dither_migrate ran twice (user's later choice dropped)"

# 2. unknown sources: every boot, cheap check first
eval "$(awk '/^unknown_sources_allow\(\) \{/{f=1} f{print} f&&/^}/{exit}' $L/afterboot.sh)"
type unknown_sources_allow >/dev/null 2>&1 || bad "afterboot.sh: no unknown_sources_allow"
awk '/AB_ONCE=1/{a=1} a&&/^    unknown_sources_allow$/{print "ok"; exit}' $L/afterboot.sh | grep -q ok || bad "unknown_sources_allow not called after the once-per-version block"
adb_sh() { echo "$*" >> "$T/adb"; }
if [ -f host/legacy/user0/settings_secure.xml ]; then   # the user0 seed is not in the source tree
mkdir -p $SYS/data/system/users/0
sed 's/name="install_non_market_apps" value="1"/name="install_non_market_apps" value="0"/' host/legacy/user0/settings_secure.xml > $SYS/data/system/users/0/settings_secure.xml
unknown_sources_allow
grep -q 'settings put secure install_non_market_apps 1' "$T/adb" 2>/dev/null || bad "value 0: settings put not run"
cp host/legacy/user0/settings_secure.xml $SYS/data/system/users/0/settings_secure.xml; : > "$T/adb"
unknown_sources_allow
[ -s "$T/adb" ] && bad "value 1: settings run anyway (a JVM start every boot)"
grep -q 'name="install_non_market_apps" value="1"' host/legacy/user0/settings_secure.xml || bad "user0 seed: unknown sources off"
fi

# VeraHome: SECURITY_SETTINGS / MANAGE_UNKNOWN_APP_SOURCES / WIFI_SETTINGS land somewhere
M=android/packages/VeraHome/AndroidManifest.xml
python3 -c 'import sys,xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' $M || bad "manifest not well-formed"
blk=$(awk '/android:name="\.UnknownSourcesActivity"/{f=1} f{print} f&&/<\/activity>/{exit}' $M)
for a in android.settings.SECURITY_SETTINGS android.settings.MANAGE_UNKNOWN_APP_SOURCES; do
    printf '%s\n' "$blk" | grep -q "<action android:name=\"$a\"" || bad "UnknownSourcesActivity does not handle $a"
    [ "$(grep -c "<action android:name=\"$a\"" $M)" -ge 1 ] || bad "$a missing"
done
printf '%s\n' "$blk" | grep -q 'android:exported="true"' || bad "UnknownSourcesActivity not exported"
printf '%s\n' "$blk" | grep -q 'android.intent.category.DEFAULT' || bad "UnknownSourcesActivity: no DEFAULT category"
[ -f android/packages/VeraHome/src/com/veradroid/home/UnknownSourcesActivity.java ] || bad "UnknownSourcesActivity.java missing"
grep -q 'INSTALL_NON_MARKET_APPS, 1' android/packages/VeraHome/src/com/veradroid/home/UnknownSourcesActivity.java || bad "UnknownSourcesActivity does not turn unknown sources on"
grep -q 'android.permission.WRITE_SECURE_SETTINGS' $M || bad "VeraHome lacks WRITE_SECURE_SETTINGS"
wblk=$(awk '/android:name="\.WifiActivity"/{f=1} f{print} f&&/<\/activity>/{exit}' $M)
printf '%s\n' "$wblk" | grep -q '<action android:name="android.settings.WIFI_SETTINGS"' || bad "WifiActivity does not handle WIFI_SETTINGS"
vc=$(sed -n 's/.*android:versionCode="\([0-9]*\)".*/\1/p' $M | head -1)
[ "$vc" -ge 90 ] || bad "VeraHome versionCode $vc (89 is new-model 1.02, legacy needs 90+)"

# 3. page keys: volume by default, page / dpad on request, swap kept, settings key accepted and published
grep -q '^PAGE_KEYS_MAP=volume$' host/legacy/models/old-base.conf || bad "old-base.conf: PAGE_KEYS_MAP not volume"
eval "$(awk '/^page_keys_layout\(\) \{/{f=1} f{print} f&&/^}/{exit}' $L/memory.sh)"
R=$T/root; W=$T/w; mkdir -p $R/system/usr/keylayout $W
PAGE_KEYS=gpio-keys; PAGE_KEYS_SWAP=1
for c in "volume VOLUME_DOWN VOLUME_UP" "page PAGE_DOWN PAGE_UP" "dpad DPAD_RIGHT DPAD_LEFT" " VOLUME_DOWN VOLUME_UP"; do
    set -- $c; [ $# = 2 ] && set -- "" "$@"
    PAGE_KEYS_MAP=$1; page_keys_layout
    grep -q "^key 104   $2\$" $R/system/usr/keylayout/gpio-keys.kl && grep -q "^key 109   $3\$" $R/system/usr/keylayout/gpio-keys.kl \
        || bad "PAGE_KEYS_MAP='$1' swap: want 104=$2 109=$3, got $(tr '\n' ' ' < $R/system/usr/keylayout/gpio-keys.kl)"
done
PAGE_KEYS_MAP=dpad; page_keys_layout; [ -n "$PK_CHANGED" ] || bad "changed layout not reported"; page_keys_layout; [ -z "$PK_CHANGED" ] || bad "unchanged layout reported as changed (Android would reopen the device for nothing)"
PAGE_KEYS_SWAP=; PAGE_KEYS=fsr_keypad; PAGE_KEYS_MAP=volume; page_keys_layout
grep -q '^key 104   VOLUME_UP$' $R/system/usr/keylayout/fsr_keypad.kl || bad "Voyage (no swap): 104 should be VOLUME_UP"
grep -q 'page_keys_apply' $L/settings.sh || bad "settings_apply does not apply PAGE_KEYS_MAP at once"
grep -q 'PAGE_KEYS_MAP=volume|PAGE_KEYS_MAP=page|PAGE_KEYS_MAP=dpad' $L/settings.sh || bad "settings_apply does not validate PAGE_KEYS_MAP"
grep -q 'PAGE_KEYS_HW=' $L/settings.sh || bad "settings_publish does not tell the desktop about page keys"
grep -q 'mknod -m 666 /dev/input/event2' $L/memory.sh || bad "page_keys_apply does not recreate the node"
# combined tree: VeraHome is the new-model one; it has the page-key setting once the new-model hosts know PAGE_KEYS_MAP
if grep -q PAGE_KEYS_MAP host/pw6/boot/lib/settings.sh; then
    grep -q '"PAGE_KEYS_MAP"' android/packages/VeraHome/src/com/veradroid/home/HomeActivity.java || bad "VeraHome has no page-key setting"
fi
for f in $L/settings.sh $L/memory.sh $L/afterboot.sh; do sh -n $f || bad "syntax $f"; done
[ $fail = 0 ] && echo "legacy-field-1120-test OK"
exit $fail
