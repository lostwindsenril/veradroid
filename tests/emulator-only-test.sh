#!/bin/sh
# Emulator-only models (3.0 / 4.1 kernels) on the experimental path: confirm gate, self-test library, redaction, purge uninstall.
set -eu
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $*"; exit 1; }
B=cloud/static/bootstrap.sh; E=cloud/static/VeraDroid-Experimental.sh; O=cloud/static/VeraDroid-Offline.sh; L=host/legacy/boot
for f in $B $E $O $L/lib/tester.sh $L/uninstall.sh $L/stop.sh $L/veradroid.sh host/legacy/entries/*.sh; do sh -n "$f" || fail "syntax $f"; done
# real-device models never see the confirm step
grep -q 'case "$(uname -r)" in 3.\*) EMU=' $E || fail "Experimental.sh: confirm step not limited to 3.0 / 4.1 kernels"
grep -q 'export VD_EMUONLY_OK=1' $E || fail "Experimental.sh: no confirmation token"
grep -q 'export VD_EMUONLY_OK=1' $O || fail "Offline.sh: no confirmation token"
grep -q '\[ $((now - cu)) -ge 10 \] && \[ $((now - cu)) -le 120 \]' $E || fail "Experimental.sh: second tap window not 10-120 s"
# 0.92+: the shared bootstrap.sh refuses emulator-only models; they install through VeraDroid-Legacy.sh, which asks for
# the second tap and fetches the legacy installer (static/bootstrap-legacy.sh, published separately from the legacy branch)
LG=cloud/static/VeraDroid-Legacy.sh; sh -n $LG || fail "syntax $LG"
grep -q 'imx41) show "老机型：请改用官网“老机型安装”脚本，本机未改动"; exit 1' $B || fail "bootstrap: PW4 / Oasis 3 not sent to the legacy installer"
grep -q 'legacy) \[ "${VD_LEGACY_TEST:-0}" = 1 \] || { show "老机型' $B || fail "bootstrap: 3.0-kernel models installable from the shared installer"
grep -q 'export VD_EMUONLY_OK=1' $LG || fail "Legacy.sh: no confirmation token"
grep -q '\[ $((now - cu)) -ge 10 \] && \[ $((now - cu)) -le 120 \]' $LG || fail "Legacy.sh: second tap window not 10-120 s"
grep -q 'BS_URL="$BASE/static/bootstrap-legacy.sh"' $LG || fail "Legacy.sh: emulator-only models not routed to the legacy installer"
grep -q '^test_begin$' $L/veradroid.sh || fail "veradroid.sh: no test watcher"
grep -q 'test_after_stop "$uc_line"' $L/stop.sh || fail "stop.sh: no return-to-Kindle record"
grep -q 'nk" != "$(cat "$VD/kmod.id"' $L/lib/auto-update.sh || fail "auto-update: kernel-module changes installed silently"
grep -q 'KLIB_SKIP=1' $L/lib/container.sh || fail "container: Kindle library bound into Android on emulator-only models"
# redaction: no book names / personal paths survive
T=$(mktemp -d); trap 'rm -rf $T' EXIT
VD=$T/vd; SYS=$T/sys; W=$T/w; LOG=$T/log; mkdir -p $VD $W; echo emulator-only > $VD/tested
t() { :; }; alive() { return 1; }
. $L/lib/tester.sh
out=$(printf '%s\n' 'open /storage/emulated/0/Books/My Secret.epub ok' 'documents/vdtest/SecretTitle-1.epub missing' \
    '/data/media/0/KindleLibrary/Diary.txt' 'file=Report.PDF size=3' 'keep x: has files no longer on the device (e.g. documents/a b.mobi)' | redact)
echo "$out" | grep -q -i -E 'secret|diary|report\.pdf|a b\.mobi|My Secret' && fail "redact leaks: $out"
# state + report
tset run.n 1; tset boot.result PASS; tset boot.s 42; tset chk.net "PASS|ok"; [ "$(tget boot.s)" = 42 ] || fail "tset/tget"
tset boot.s 43; [ "$(tget boot.s)" = 43 ] || fail "tset does not overwrite"
test_report; grep -q '开机完成（sys.boot_completed）：43 秒' $VD/TEST-RESULT.txt || fail "report: boot line"
grep -q '\[PASS\] 网络：ok' $VD/TEST-RESULT.txt || fail "report: check line"
rm -f $VD/tested; tset x y; [ -z "$(tget x)" ] || fail "tset active on a real-device model"
echo "EMULATOR-ONLY OK"
