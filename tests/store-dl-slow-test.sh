#!/bin/sh
# Store / font downloads (VeraHome Dl.java): leave a source that crawls after the probe (2026-11-21: "einkbro 11%, 8 KB/s, 镜像";
# direct dl.wenjin.jp from China in the evening: median 32 KB/s per connection, Cloudflare 142 KB/s). Static checks plus the
# JVM test with two local HTTP servers (tests-jvm/com/veradroid/home/DlSlowTest.java) when a JDK is installed.
cd "$(dirname "$0")/.." || exit 2
H=android/packages/VeraHome
S=$H/src/com/veradroid/home
fail=0
need()   { grep -qE "$2" "$1" || { echo "FAIL $(basename "$1"): $3"; fail=1; }; }
need "$S/Dl.java" 'static final class Slow extends java\.io\.IOException' 'slow-source exception'
need "$S/Dl.java" 'SEG_MIN = 2L << 20' 'apps from 2 MB use several connections'
need "$S/StoreActivity.java" 'Dl\.fetchOnce\(cands, out, a\.size, p, slow\)' 'store passes the slow set'
need "$S/StoreActivity.java" 'catch \(Dl\.Slow e\)' 'store switches source on Slow without counting a failure'
need "$S/FontStoreActivity.java" 'Dl\.fetchOnce\(cands, part, it\.size, p, slow\)' 'font store passes the slow set'
need "$S/StoreActivity.java" 'StoreNet\.mb\(done\)' 'progress shows KB / 0.x MB instead of 0 / 4 MB'
if command -v javac >/dev/null 2>&1 && javac -version >/dev/null 2>&1; then
    o=${TMPDIR:-/tmp}/vd-dl-jvm.$$; rm -rf $o; mkdir -p $o
    javac -encoding UTF-8 -nowarn -d $o $S/Dl.java $H/tests-jvm/android/util/Log.java $H/tests-jvm/org/json/JSONObject.java $H/tests-jvm/com/veradroid/home/DlSlowTest.java 2>&1 | grep -v '^Note' 
    timeout 120 java -cp $o com.veradroid.home.DlSlowTest || fail=1
    rm -rf $o
else
    echo "no JDK here: JVM test skipped (install a JDK and run sh tests/store-dl-slow-test.sh)"
fi
[ $fail = 0 ] && echo "store-dl-slow: ok"
exit $fail
