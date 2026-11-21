#!/bin/sh
# Optional newer WebView (WEBVIEW=alt, docs/webview-alt.md; host/*/boot/lib/container.sh webview_*):
# - off by default; 512 MB models and installs without a verified download always use the image's WebView 52;
# - turning it on downloads the pinned tar.gz (direct link first, then the main site, resumable), checks both sha256 pins,
#   unpacks to $VD/webview-alt/app/webview.apk; a bad download is removed and never used;
# - switching engines parks each app's app_webview as app_webview.vd-<engine> and restores it on the way back;
#   nothing is copied between engines (119 does not migrate 52's cookie / localStorage files; 52 cannot read 119's);
#   going back to 52 drops WebViewChromiumPrefs.xml (52 would wipe the restored profile as a "downgrade");
# - switched off (WEBVIEW=stock): the next boot removes the download and every app_webview.vd-alt;
# - the settings page only offers the switch when the host publishes WEBVIEW_ALT_OK=1; settings_apply accepts stock|alt only;
# - the installer carries veradroid/webview-alt over an update (VD_USER_DIRS); uninstall removes it with the program dir.
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
for h in pw6 k49; do
    c=host/$h/boot/lib/container.sh; s=host/$h/boot/lib/settings.sh
    grep -q '^    webview_prepare ' $c || fail "$c: container_start does not call webview_prepare"
    grep -q '^        webview_mount ' $c || fail "$c: run_in_ns does not call webview_mount"
    grep -q '^    WEBVIEW=stock ' $s || fail "$s: WEBVIEW default is not stock"
    grep -q 'USB_ASK UPDATE_BACKUP WEBVIEW; do eval' $s || fail "$s: settings_publish does not publish WEBVIEW"
    grep -q 'IDLE_FREEZE_EXCLUDE USB_ASK WEBVIEW; do$' $s || fail "$s: settings_apply does not accept WEBVIEW"
    grep -q 'WEBVIEW=stock|WEBVIEW=alt|WEBVIEW=default) ;;' $s || fail "$s: WEBVIEW values not validated"
    grep -q "WEBVIEW_ALT_OK=" $s || fail "$s: WEBVIEW_ALT_OK not published"
    grep -q 'webview_dl$' $s || fail "$s: settings_apply does not start the download"
    grep -q 'webview) case "$a" in get|cancel)' host/$h/boot/lib/cmd.sh || fail "$h: cmd.sh has no webview get|cancel"
    grep -q '! webview_ok && ! lowmem_ram && webview_dl' host/$h/boot/lib/afterboot.sh || fail "$h: afterboot does not resume the download"
    grep -q 'pm disable $WEBVIEW_ALT_PKG/org.chromium.android_webview' host/$h/boot/lib/afterboot.sh && grep -q 'services.VariationsSeedServer' host/$h/boot/lib/afterboot.sh || fail "$h: 119 background services not disabled"
    grep -q '^VD_USER_DIRS=".*webview-alt' host/$h/boot/lib/tidy.sh || fail "$h: tidy.sh VD_USER_DIRS does not carry webview-alt"
    sed -n '/^WEBVIEW_ALT_VER=/,/^container_start()/p' $c > /tmp/vd-wv.$$.$h
done
grep -q '^VD_USER_DIRS=".*webview-alt' cloud/static/bootstrap.sh || fail "bootstrap.sh VD_USER_DIRS does not carry webview-alt"
cmp -s /tmp/vd-wv.$$.pw6 /tmp/vd-wv.$$.k49 || { rm -f /tmp/vd-wv.$$.*; fail "webview_* differs between pw6 and k49"; }
rm -f /tmp/vd-wv.$$.*
grep -q '^WEBVIEW_ALT_SHA=[0-9a-f]\{64\}$' host/pw6/boot/lib/container.sh || fail "tar.gz sha256 not pinned"
grep -q '^WEBVIEW_ALT_SIZE=[0-9]\{8,\}$' host/pw6/boot/lib/container.sh || fail "tar.gz size not pinned"
grep -q '^WEBVIEW_ALT_APK_SHA=5158f50ab9e73241ae5534fde8fee9ea6d81d65e8e781a0750eb2cfe0445c902$' host/pw6/boot/lib/container.sh || fail "apk sha256 not pinned to the contributor build"
grep -q '^WEBVIEW_ALT_OV_SHA=[0-9a-f]\{64\}$' host/pw6/boot/lib/container.sh || fail "overlay sha256 not pinned"
grep -q 'packageName="com.embrith.webview"' android/webview-alt/overlay/res/xml/config_webview_packages.xml && grep -q '<signature>MII' android/webview-alt/overlay/res/xml/config_webview_packages.xml || fail "overlay does not list com.embrith.webview with its certificate"
grep -c '<webviewprovider ' android/webview-alt/overlay/res/xml/config_webview_packages.xml | grep -qx 1 || fail "overlay must list only the optional engine (else the stored com.android.webview choice wins)"
J=android/packages/VeraHome/src/com/veradroid/home/HostSettingsActivity.java
grep -q '"WEBVIEW_ALT_OK"' $J || fail "settings page does not gate the switch on WEBVIEW_ALT_OK"
grep -q '"webview.status"' $J && grep -q '"webview " + webviewAct' $J || fail "settings page does not show progress / send webview get|cancel"

T=$(mktemp -d) || exit 2
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
# run CODE with the webview_* functions; LOWRAM=1 pretends a 512 MB model; $T/pins (if any) replaces the pinned values.
# VAR=x run ... only inside ( ) or $( ): sh keeps such assignments after a function call
run() { PINS=$T/pins VD=$T/vd SYS=$T/sys W=$T/w R=$T/r X=$T/x LOG=$T/log sh -c 't() { echo "LOG $*"; }; lowmem_ram() { [ "${LOWRAM:-0}" = 1 ]; };
    eval "$(sed -n "/^WEBVIEW_ALT_VER=/,/^container_start()/p" host/pw6/boot/lib/container.sh | sed "\$d")"; [ -f "$PINS" ] && . "$PINS"; '"$1"; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }
mkdir -p $T/w $T/x/ctl $T/vd $T/sys/data/data/a/app_webview $T/sys/data/data/b $T/sys/data/data/c/app_webview $T/sys/data/dalvik-cache/arm
echo stock-a > $T/sys/data/data/a/app_webview/Cookies; echo stock-c > $T/sys/data/data/c/app_webview/Cookies
: > $T/sys/data/dalvik-cache/arm/system@app@webview@webview.apk@classes.dex

# ---- the download: a local server with bundles/<file>, pins for a small fake package
mkdir -p $T/pkg/app $T/pkg/overlay $T/srv/bundles; head -c 300000 /dev/urandom > $T/pkg/app/webview.apk; echo notice > $T/pkg/webview_licenses.notice
head -c 5000 /dev/urandom > $T/pkg/overlay/webview-alt-overlay.apk
( cd $T/pkg && tar czf $T/srv/bundles/webview-alt-test.tar.gz app overlay webview_licenses.notice )
cat > $T/pins <<EOF
WEBVIEW_ALT_FILE=webview-alt-test.tar.gz
WEBVIEW_ALT_SHA=$(sha $T/srv/bundles/webview-alt-test.tar.gz)
WEBVIEW_ALT_SIZE=$(wc -c < $T/srv/bundles/webview-alt-test.tar.gz | tr -d ' ')
WEBVIEW_ALT_APK_SHA=$(sha $T/pkg/app/webview.apk)
WEBVIEW_ALT_APK_SIZE=300000
WEBVIEW_ALT_OV_SHA=$(sha $T/pkg/overlay/webview-alt-overlay.apk)
EOF
P=$(( 20000 + $$ % 20000 ))
( cd $T/srv && exec python3 -m http.server $P --bind 127.0.0.1 ) >/dev/null 2>&1 &
SRV=$!; i=0; while ! curl -fs -o /dev/null http://127.0.0.1:$P/ 2>/dev/null; do i=$((i+1)); [ $i -gt 50 ] && fail "test server did not start"; sleep 0.2; done
[ "$(run 'webview_urls' | head -1)" = "https://dl.wenjin.jp/bundles/webview-alt-test.tar.gz?v=$(sed -n 's/^WEBVIEW_ALT_SHA=\(........\).*/\1/p' $T/pins)" ] || fail "direct link is not tried first"
[ "$(run 'webview_urls' | sed -n 2p | cut -d'?' -f1)" = https://veradroid.wenjin.jp/bundles/webview-alt-test.tar.gz ] || fail "main site not second"
[ "$(VD_BASE=http://127.0.0.1:$P run 'webview_urls' | wc -l | tr -d ' ')" = 1 ] || fail "a test server base still gets the direct link"
printf 'VD_BASE=http://127.0.0.1:%s\nVD_DIRECT=http://127.0.0.1:%s/x\n' $P $P > $T/vd/network.conf
[ "$(run 'webview_urls' | tr '\n' ' ')" = "http://127.0.0.1:$P/x/bundles/webview-alt-test.tar.gz?v=$(sed -n 's/^WEBVIEW_ALT_SHA=\(........\).*/\1/p' $T/pins) http://127.0.0.1:$P/bundles/webview-alt-test.tar.gz?v=$(sed -n 's/^WEBVIEW_ALT_SHA=\(........\).*/\1/p' $T/pins) " ] || fail "network.conf VD_BASE / VD_DIRECT not used"
printf 'BASE=http://127.0.0.1:%s\n' $P > $T/vd/network.conf
[ "$(run 'webview_urls' | cut -d'?' -f1 | tr '\n' ' ')" = "http://127.0.0.1:$P/bundles/webview-alt-test.tar.gz " ] || fail "network.conf BASE (auto-update's name) not used"
rm -f $T/vd/network.conf
[ "$(WEBVIEW=alt run webview_mode)" = stock ] || fail "alt chosen without a download"
out=$(LOWRAM=1 run 'webview_dl; cat $X/ctl/webview.status'); case "$out" in *state=error*) ;; *) fail "512 MB model started a download: $out" ;; esac
# first source broken (404), second good
out=$(VD_BASE=http://127.0.0.1:$P VD_DIRECT=http://127.0.0.1:$P/nothere run 'webview_dl_run; cat $X/ctl/webview.status')
case "$out" in *state=ready*) ;; *) fail "download did not finish: $out" ;; esac
[ "$(sha $T/vd/webview-alt/app/webview.apk)" = "$(sha $T/pkg/app/webview.apk)" ] && [ -s $T/vd/webview-alt/overlay/webview-alt-overlay.apk ] || fail "apk / overlay not unpacked"
[ -f $T/vd/webview-alt/ok ] && [ ! -e $T/vd/webview-alt.dl ] && [ ! -e $T/vd/webview-alt.new ] || fail "ok marker / leftovers"
run webview_ok || fail "webview_ok false after a good download"
[ "$(WEBVIEW=alt run webview_mode)" = alt ] || fail "WEBVIEW=alt with the download not alt"
[ "$(run webview_mode)" = stock ] || fail "default is not stock"
[ "$(WEBVIEW=alt LOWRAM=1 run webview_mode)" = stock ] || fail "512 MB model got alt"
out=$(WEBVIEW=alt LOWRAM=1 run webview_prepare); case "$out" in *"alt requested but not used (512MB)"*) ;; *) fail "512 MB: no log line: $out" ;; esac
mv $T/vd/webview-alt/overlay $T/ov.keep; [ "$(WEBVIEW=alt run webview_mode)" = stock ] || fail "used without the overlay"; mv $T/ov.keep $T/vd/webview-alt/overlay
# a changed apk (other size / no matching ok line) is not used
cp -p $T/vd/webview-alt/ok $T/ok.bak; echo "x y" > $T/vd/webview-alt/ok
[ "$(WEBVIEW=alt run webview_mode)" = stock ] || fail "apk without a matching ok marker used"
cp -p $T/ok.bak $T/vd/webview-alt/ok
# a server with the wrong content: removed, error (a short partial file would be kept for resuming)
mkdir -p $T/srv2/bundles; head -c $(wc -c < $T/srv/bundles/webview-alt-test.tar.gz) /dev/urandom > $T/srv2/bundles/webview-alt-test.tar.gz   # right size, wrong content
( cd $T/srv2 && exec python3 -m http.server $((P+1)) --bind 127.0.0.1 ) >/dev/null 2>&1 &
SRV2=$!; i=0; while ! curl -fs -o /dev/null http://127.0.0.1:$((P+1))/ 2>/dev/null; do i=$((i+1)); [ $i -gt 50 ] && break; sleep 0.2; done
mv $T/vd/webview-alt $T/vd/webview-alt.keep
out=$(VD_BASE=http://127.0.0.1:$((P+1)) run 'webview_dl_run; cat $X/ctl/webview.status'); kill $SRV2 2>/dev/null
case "$out" in *state=error*) ;; *) fail "wrong content not reported: $out" ;; esac
[ ! -e $T/vd/webview-alt ] && [ ! -s $T/vd/webview-alt.dl/webview-alt-test.tar.gz ] || fail "a bad download was kept"
rm -rf $T/vd/webview-alt.dl; mv $T/vd/webview-alt.keep $T/vd/webview-alt

# first boot with the default: nothing moves, nothing to purge but the download is removed (switch is off)
cp -a $T/vd/webview-alt $T/wv.keep
run webview_prepare >/dev/null
[ "$(cat $T/w/webview.mode)" = stock ] && [ "$(cat $T/sys/webview.last)" = stock ] || fail "stock boot: mode files"
[ -f $T/sys/data/data/a/app_webview/Cookies ] && [ ! -e $T/sys/data/data/a/app_webview.vd-stock ] || fail "stock boot moved profiles"
[ ! -e $T/vd/webview-alt ] || fail "switch off: download not removed"
cp -a $T/wv.keep $T/vd/webview-alt

# stock -> alt: stock parked, alt starts empty, compiled code of the old package dropped
out=$(WEBVIEW=alt run webview_prepare); case "$out" in *"webview: stock -> alt"*) ;; *) fail "no switch log: $out" ;; esac
[ "$(cat $T/w/webview.mode)" = alt ] || fail "mode not alt"
[ -d $T/vd/webview-alt/app ] || fail "WEBVIEW=alt boot removed the download"
[ "$(cat $T/sys/data/data/a/app_webview.vd-stock/Cookies)" = stock-a ] || fail "stock profile of a not parked"
[ ! -e $T/sys/data/data/a/app_webview ] || fail "stock profile of a handed to 119"
[ ! -e $T/sys/data/data/b/app_webview ] && [ ! -e $T/sys/data/data/b/app_webview.vd-stock ] || fail "app without WebView data got some"
[ ! -e $T/sys/data/dalvik-cache/arm/system@app@webview@webview.apk@classes.dex ] || fail "old webview dalvik-cache kept"
mkdir -p $T/sys/data/data/a/app_webview; echo alt-a > $T/sys/data/data/a/app_webview/Cookies   # 119 makes its own profile
[ ! -e $T/sys/data/data/c/app_webview ] || fail "stock profile of c handed to 119"
mkdir -p $T/sys/data/data/b/app_webview; echo alt-b > $T/sys/data/data/b/app_webview/Cookies   # b first used WebView under alt

# same mode again: nothing moves
(WEBVIEW=alt run webview_prepare >/dev/null)
[ "$(cat $T/sys/data/data/a/app_webview/Cookies)" = alt-a ] || fail "second alt boot touched profiles"

# the download disappears (WEBVIEW still alt): back to stock, profiles swapped back, alt data kept for a re-download
mv $T/vd/webview-alt $T/vd/webview-alt.keep
(WEBVIEW=alt run webview_prepare >/dev/null)
[ "$(cat $T/w/webview.mode)" = stock ] && [ "$(cat $T/sys/data/data/a/app_webview/Cookies)" = stock-a ] || fail "missing download: not back to stock"
[ "$(cat $T/sys/data/data/a/app_webview.vd-alt/Cookies)" = alt-a ] || fail "missing download (switch on): alt data removed"
mv $T/vd/webview-alt.keep $T/vd/webview-alt
(WEBVIEW=alt run webview_prepare >/dev/null)
[ "$(cat $T/sys/data/data/a/app_webview/Cookies)" = alt-a ] && [ "$(cat $T/sys/data/data/b/app_webview/Cookies)" = alt-b ] || fail "alt profiles not restored"

mkdir -p $T/sys/data/data/a/shared_prefs $T/sys/data/data/b/shared_prefs
echo '<int name="lastVersionCodeUsed" value="604514100" />' > $T/sys/data/data/a/shared_prefs/WebViewChromiumPrefs.xml
echo '<int name="lastVersionCodeUsed" value="604514100" />' > $T/sys/data/data/b/shared_prefs/WebViewChromiumPrefs.xml
echo keep > $T/sys/data/data/a/shared_prefs/app.xml
# switched off: stock restored, alt data and the download removed, b (alt-only) starts empty, c gets its stock profile back
out=$(run webview_prepare); case "$out" in *"webview: alt -> stock"*) ;; *) fail "no switch-back log: $out" ;; esac
case "$out" in *"switched off: downloaded WebView 119 and 2 apps"*) ;; *) fail "no purge log: $out" ;; esac
[ "$(cat $T/sys/data/data/a/app_webview/Cookies)" = stock-a ] || fail "stock profile of a not restored"
[ "$(cat $T/sys/data/data/c/app_webview/Cookies)" = stock-c ] || fail "stock profile of c not restored"
[ ! -e $T/sys/data/data/b/app_webview ] || fail "alt-only profile of b handed to WebView 52"
ls -d $T/sys/data/data/*/app_webview.vd-* >/dev/null 2>&1 && fail "app_webview.vd-* left after switching off"
[ ! -e $T/vd/webview-alt ] || fail "download left after switching off"
[ ! -e $T/sys/data/data/a/shared_prefs/WebViewChromiumPrefs.xml ] && [ ! -e $T/sys/data/data/b/shared_prefs/WebViewChromiumPrefs.xml ] || fail "WebView 52 would see a downgrade and wipe the restored profile"
[ "$(cat $T/sys/data/data/a/shared_prefs/app.xml)" = keep ] || fail "the app's own prefs touched"

# settings_apply: only stock|alt|default are taken
for h in pw6 k49; do
    v=$(sed -n '/^settings_apply()/,/^}/p' host/$h/boot/lib/settings.sh | grep -c 'WEBVIEW=\*) continue')
    [ "$v" = 1 ] || fail "$h: other WEBVIEW values not rejected"
done
echo "webview-alt: ok"
