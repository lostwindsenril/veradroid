#!/bin/sh
# Keep the previous odex while a background compile runs (host/pw6 + host/k49 boot/lib/compile.sh, compile_keep_*), no device:
# a fake installd does what Android 7.1's does for "cmd package compile -f": unlink oat/arm/base.odex (+ base.art),
# O_EXCL-create a new one, write it through an open fd (ELF header last), and on failure unlink the path again.
#  k1 success: base.odex is the old, complete file the whole time; afterwards the new one; old art dropped when the new
#     compile made none; nothing left behind
#  k2 failure / k3 killed: the old odex (same inode) and art are back, the partial new file is gone
#  k4 no previous odex: no guard, unchanged behaviour
#  k5 leftovers of a worker that died mid-compile are cleaned up (old odex back unless base.odex is a complete ELF)
#  k6 compile_one: a failed compile with the old odex kept does not run the light interpret-only recompile
#  k7 profile compile: the new app image replaces the old one
#  k8 prefault does not run while a dex2oat runs
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
C=${COMPILE_SH:-host/pw6/boot/lib/compile.sh}
[ -n "$COMPILE_SH" ] || { cmp -s host/pw6/boot/lib/compile.sh host/k49/boot/lib/compile.sh || fail "host/k49 compile.sh differs from host/pw6"; }
sh -n $C || fail "syntax $C"
C=$(pwd)/$C
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
# timeout without --foreground puts the shell in a background process group, where "wait" can return early (macOS)
TMO="timeout 60"; timeout --foreground 5 true 2>/dev/null && TMO="timeout --foreground 60"
P=com.tencent.weread.eink
D=$T/sys/data/app/$P-1; O=$D/oat/arm

reset() { # [noodex]
    rm -rf $T/sys $T/w $T/log $T/adb $T/samples $T/glog; mkdir -p $O $T/w $T/sys/data/system
    echo apk > $D/base.apk
    [ "$1" = noodex ] && return 0
    printf '\177ELFold' > $O/base.odex; printf 'oldart' > $O/base.art
    ln $O/base.odex $T/orig.odex 2>/dev/null || { rm -f $T/orig.odex; ln $O/base.odex $T/orig.odex; }
}
# fake installd + dex2oat for one dexopt. FI=ok|fail|kill, FIART=1: profile-guided (writes a new base.art)
fake_installd() {
    /bin/sleep 0.3
    rm -f $O/base.odex; exec 7>$O/base.odex           # unlink + create, dex2oat writes through this fd
    rm -f $O/base.art; [ "$FIART" = 1 ] && exec 8>$O/base.art
    /bin/sleep 1.2                                    # dex2oat running: the reader samples here
    case "$FI" in
    ok) printf '\177ELFnew' >&7; [ "$FIART" = 1 ] && printf 'newart' >&8; exec 7>&- 8>&-; echo Success ;;
    fail) printf 'PARTIAL' >&7; exec 7>&-; rm -f $O/base.odex $O/base.art; echo "Failure: package $P could not be compiled" ;;
    kill) printf 'PART' >&7; exec 7>&-; rm -f $O/base.odex $O/base.art; echo "Error: dex2oat killed" ;;
    esac
}
run() {
    PATH=$PATH W=$T/w X=$T/x SYS=$T/sys T=$T P=$P O=$O FI=$FI FIART=$FIART LOG=$T/glog $TMO sh -c '
        . "$0" 2>/dev/null
        t() { echo "$*" >> $T/log; }
        alive() { [ "$1" = $W/pid ]; }; lowmem_ram() { return 1; }; usleep() { /bin/sleep 0.05; }
        '"$(sed -n '/^fake_installd()/,/^}/p' "$0")"'
        adb_sh() { echo "$*" >> $T/adb; case "$*" in *"cmd package compile"*) fake_installd ;; esac; return 0; }
        adb_sh_t() { shift; adb_sh "$@"; }
        pgrep() { [ -f $T/dex ] && cat $T/dex; return 0; }
        compile_babysit() { while kill -0 $1 2>/dev/null; do /bin/sleep 0.1; done; }
        sample() { # reader: what an app starting now would open
            /bin/sleep 0.9; cat $O/base.odex > $T/s1 2>/dev/null || echo missing > $T/s1
            /bin/sleep 0.3; cat $O/base.odex > $T/s2 2>/dev/null || echo missing > $T/s2
        }
        '"$1" $C
}
leftovers() { ls -a $O | grep -q '^\.vd-'; }

# k1 success
reset; FI=ok FIART= run 'sample & compile_pm_start $P $T/out -m speed -f $P; compile_pm_wait; wait'
[ "$(cat $T/s1)" = "$(printf '\177ELFold')" ] && [ "$(cat $T/s2)" = "$(printf '\177ELFold')" ] ||
    fail "k1: during the compile base.odex read '$(cat $T/s1)' / '$(cat $T/s2)', want the old odex"
[ "$(cat $O/base.odex)" = "$(printf '\177ELFnew')" ] || fail "k1: final base.odex '$(cat $O/base.odex)', want the new one"
[ -f $O/base.art ] && fail "k1: the old app image was kept next to the new (non-profile) odex"
leftovers && fail "k1: left $(ls -a $O | grep '^\.vd-')"
grep -q "new odex of" $T/log || fail "k1: no log line"
echo "k1 ok: old odex served during the compile, new one in place after Success"

# k2 failure, k3 killed
for k in fail kill; do
    reset; FI=$k FIART= run 'sample & compile_pm_start $P $T/out -m speed -f $P; compile_pm_wait; wait'
    [ "$(cat $T/s1)" = "$(printf '\177ELFold')" ] || fail "$k: during the compile base.odex read '$(cat $T/s1)'"
    [ $O/base.odex -ef $T/orig.odex ] || fail "$k: base.odex is not the original file afterwards ($(cat $O/base.odex 2>&1))"
    [ "$(cat $O/base.art 2>/dev/null)" = oldart ] || fail "$k: old app image not back"
    leftovers && fail "$k: left $(ls -a $O | grep '^\.vd-')"
    echo "k-$k ok: the previous odex and app image are back after a $k"
done

# k4 no previous odex: no guard (unchanged behaviour)
reset noodex; FI=fail run 'compile_pm_start $P $T/out -m speed -f $P; [ -z "$cpg_" ] || echo guard > $T/g; compile_pm_wait'
[ -f $T/g ] && fail "k4: a guard was started without a previous odex"
[ -f $O/base.odex ] && fail "k4: base.odex appeared"
echo "k4 ok: no previous odex, no guard"

# k5 cleanup of leftovers: (a) partial base.odex + keep -> old back; (b) complete new base.odex + keep -> kept
reset; ln $O/base.odex $O/.vd-keep.odex; ln $O/base.art $O/.vd-keep.art; rm $O/base.odex; : > $O/base.odex; ln $O/base.odex $O/.vd-new.odex
run 'compile_keep_cleanup'
[ $O/base.odex -ef $T/orig.odex ] || fail "k5a: old odex not restored"; leftovers && fail "k5a: leftovers"
reset; ln $O/base.odex $O/.vd-keep.odex; rm $O/base.odex; printf '\177ELFdone' > $O/base.odex
run 'compile_keep_cleanup'
[ "$(cat $O/base.odex)" = "$(printf '\177ELFdone')" ] || fail "k5b: a complete odex was replaced"; leftovers && fail "k5b: leftovers"
reset; ln $O/base.odex $O/.vd-keep.odex; rm $O/base.odex; : > $O/base.odex; echo 4242 > $T/dex
run 'pgrep() { echo 4242; }; compile_dex2oat_for() { return 0; }; compile_keep_cleanup'
[ -f $O/.vd-keep.odex ] || fail "k5c: cleaned up while a dex2oat for the package still runs"; rm -f $T/dex
echo "k5 ok: leftovers cleaned up (old odex back unless base.odex is complete), not while dex2oat runs"

# k6 compile_one: failure with the old odex kept -> no light recompile, filter stays the old one
reset; FI=fail run '
    odex_filter() { compile_elf_ok $O/base.odex && echo interpret-only; }
    compile_held() { return 1; }; compile_app_running() { return 1; }; compile_user_busy() { return 1; }; compile_charging() { return 0; }
    compile_one $P speed force' 2>/dev/null
n=$(grep -c "cmd package compile" $T/adb); [ "$n" = 1 ] || fail "k6: $n compiles, want 1 (no light recompile when the old odex is still there)"
grep -q -- "-> fail.*(filter=interpret-only" $T/log || fail "k6: log: $(grep -- '->' $T/log)"
echo "k6 ok: failed compile keeps the install-time odex, no extra interpret-only pass"

# k7 profile-guided success: new app image in place
reset; FI=ok FIART=1 run 'compile_pm_start $P $T/out -m speed-profile -f $P; compile_pm_wait'
[ "$(cat $O/base.art)" = newart ] || fail "k7: base.art '$(cat $O/base.art 2>&1)', want the new image"
[ "$(cat $O/base.odex)" = "$(printf '\177ELFnew')" ] || fail "k7: odex"
echo "k7 ok: new app image in place after a profile compile"

# k8 prefault waits while a dex2oat runs (legacy has no prefault)
if grep -q "^compile_prefault()" $C; then
reset; dd if=/dev/zero of=$O/base.odex bs=1024 count=70000 2>/dev/null; echo 99 > $T/dex
run 'APP_PREFAULT_MB=64; mem_avail_mb() { echo 900; }; compile_prefault; wait'
[ -f $T/w/prefault.done ] && fail "k8: prefault marked done while dex2oat runs"
grep -qs prefault: $T/log && fail "k8: prefault read an odex while dex2oat runs"
rm -f $T/dex; run 'APP_PREFAULT_MB=64; mem_avail_mb() { echo 900; }; compile_prefault; wait'
grep -q prefault: $T/log || fail "k8: prefault did not run after the compile"
echo "k8 ok: no prefault during a compile"
fi

# k9 a stale <pkg>-1 left next to the live <pkg>-2 (install interrupted by a reboot): use the codePath from packages.xml
reset; mkdir -p $T/sys/data/app/$P-2/oat/arm; printf '\177ELFlive' > $T/sys/data/app/$P-2/oat/arm/base.odex
echo "<package name=\"$P\" codePath=\"/data/app/$P-2\" nativeLibraryPath=\"/data/app/$P-2/lib\">" > $T/sys/data/system/packages.xml
run 'echo "$(app_dir $P) $(compile_oat_dir $P)" > $T/k9'
[ "$(cat $T/k9)" = "$P-2 $T/sys/data/app/$P-2/oat/arm" ] || fail "k9: picked '$(cat $T/k9)'"
echo "k9 ok: the live code dir is used when a stale one is left"

# static: every app compile goes through compile_pm_start
n=$(grep -v '^ *#' $C | grep -c 'adb_sh "cmd package compile'); [ "$n" = 1 ] || fail "static: $n direct cmd package compile calls, want 1 (in compile_pm_start)"
echo "compile-keep: ok"
