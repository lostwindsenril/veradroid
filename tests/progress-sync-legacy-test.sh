#!/bin/sh
# Progress code shared by the legacy host (host/legacy/boot/lib/progress.sh) and the legacy installer (cloud/static/bootstrap-legacy.sh):
#  - the ticker subshell ends when its parent is gone (0.8.14 lost this in the installer copy during a merge)
#  - the network check gives the eips (English) line a concrete reason + the right offline zip (NC_EN / NC_OZ), as on new-model
# Any vp_* function present in both copies must be identical (they drifted apart twice).
cd "$(dirname "$0")/.." || exit 2
H=host/legacy/boot/lib/progress.sh B=cloud/static/bootstrap-legacy.sh
fail=0
for f in $H $B; do
    sh -n $f || { echo "FAIL syntax $f"; fail=1; }
    awk '/^vp_ticker_start\(\)/,/^}/' $f | grep -q 'while \[ -d /proc/\$\$ \]; do' || { echo "FAIL $f: ticker does not watch its parent"; fail=1; }
    awk '/^vp_ticker_start\(\)/,/^}/' $f | grep -q 'while :; do' && { echo "FAIL $f: endless ticker loop"; fail=1; }
    grep -q 'case "\$1" in 11|12|13) \[ -n "\${NC_EN:-}" \]' $f || { echo "FAIL $f: vp_code_en ignores NC_EN"; fail=1; }
    grep -q '3\.\*|4\.1\.\*) NC_OZ=VeraDroid-Offline-Legacy.zip' $f || { echo "FAIL $f: no offline zip name for legacy kernels"; fail=1; }
done
for fn in vp_netcheck vp_code_en vp_ticker_start vp_ticker_stop; do
    a=$(awk "/^$fn\\(\\)/,/^}/" $H | cksum); b=$(awk "/^$fn\\(\\)/,/^}/" $B | cksum)
    [ "$a" = "$b" ] || { echo "FAIL $fn differs between $H and $B"; fail=1; }
done
[ $fail = 0 ] && echo "progress-sync-legacy: ok"
exit $fail
