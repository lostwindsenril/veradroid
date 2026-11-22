#!/bin/sh
# Built-in reader: page turns before the whole book is paginated (big books take 10-60 s in the background).
# 1.03 field report: tapping the left side did not go back, and at the end of a chapter tapping did not go on.
# Static checks on ReaderActivity, plus the JVM test of ReaderTurn when a JDK is installed.
cd "$(dirname "$0")/.." || exit 2
H=android/packages/VeraHome
S=$H/src/com/veradroid/home
fail=0
need()   { grep -qE "$2" "$1" || { echo "FAIL $(basename "$1"): $3"; fail=1; }; }
forbid() { grep -qE "$2" "$1" && { echo "FAIL $(basename "$1"): $3"; fail=1; } || true; }
forbid "$S/ReaderTurn.java" 'import android\.' 'ReaderTurn.java must stay plain Java (tests-jvm)'
need   "$S/ReaderActivity.java" 'pages\.isEmpty\(\) && provChapter != null\) \{' 'prev() handles the provisional page (no page table yet)'
need   "$S/ReaderActivity.java" 'private void provPrev\(\)' 'provisional previous page'
need   "$S/ReaderActivity.java" 'ReaderTurn\.prevStart\(provChapter\.text, provStart' 'previous page within the chapter'
need   "$S/ReaderActivity.java" 'if \(preChapters == null\) waitForBook\(1\)' 'chapter end before the book is read: wait, do not drop the tap'
need   "$S/ReaderActivity.java" 'preChapters = chs;' 'book read'
need   "$S/ReaderActivity.java" 'provBookReady\(\);' 'pending turn applied once the book is read'
# the built-in reader lives in the home package, for which the host sends FLIPCOUNT 0: it turns page counting on itself
need   "$S/ReaderActivity.java" 'HostLink\.epd\(on \? "FLIPCOUNT 1" : "FLIPCOUNT 0"\)' 'reader turns the KFB_FLASH page count on'
need   "$S/ReaderActivity.java" 'private void turned\(int dir\) \{[[:space:]]*$' 'turned(dir)'
grep -A1 'private void turned(int dir) {' "$S/ReaderActivity.java" | grep -q 'flipCount(true);' || { echo "FAIL ReaderActivity.java: every turn re-enables page counting"; fail=1; }
# 翻页动画 (fix/1105-reader-anim): a text page often changes less than the bridge's KFB_ANIM_MIN, so the reader asks for the slide
grep -A2 'private void turned(int dir) {' "$S/ReaderActivity.java" | grep -q 'slideTurn(dir);' || { echo "FAIL ReaderActivity.java: a turn asks for the page slide"; fail=1; }
need   "$S/ReaderActivity.java" 'turned\(-1\);' 'prev() turns backwards'
need   "$S/ReaderActivity.java" 'turned\(1\);' 'next() turns forwards'
need   "$S/ReaderActivity.java" 'HostLink\.epd\("SWIPE " \+ d \+ " "' 'slide sent as a bridge SWIPE one-shot'
need   "$S/ReaderActivity.java" 'ReaderTurn\.slideDir\(HostLink\.num\(cfg, "KFB_ANIM_MODE", 0\), "0"\.equals\(cfg\.get\("KFB_SWIPE"\)\)' 'slide follows KFB_ANIM_MODE and KFB_SWIPE'
grep -A2 'protected void onPause() {' "$S/ReaderActivity.java" | grep -q 'flipCount(false);' || { echo "FAIL ReaderActivity.java: page counting off when the reader leaves"; fail=1; }
forbid "$S/ReaderActivity.java" 'if \(start >= provChapter\.text\.length\(\)\) return;' 'old silent return at the end of a chapter'
if command -v javac >/dev/null 2>&1 && javac -version >/dev/null 2>&1; then
    o=${TMPDIR:-/tmp}/vd-turn-jvm.$$; rm -rf $o; mkdir -p $o
    javac -encoding UTF-8 -nowarn -d $o $S/ReaderTurn.java $H/tests-jvm/com/veradroid/home/ReaderTurnTest.java 2>&1 | grep -v '^Note'
    java -cp $o com.veradroid.home.ReaderTurnTest || fail=1
    rm -rf $o
else
    echo "no JDK here: JVM test skipped (install a JDK and run sh tests/reader-turn-test.sh)"
fi
[ $fail = 0 ] && echo "reader-turn: ok"
exit $fail
