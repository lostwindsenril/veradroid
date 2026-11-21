#!/bin/sh
# Background compile after an abort (host/legacy/boot/lib/compile.sh), no device needed:
#  a. an aborted compile (foreground / running / busy) that left no odex puts the package on compile.restore;
#     once the app has exited the worker restores it with a light interpret-only compile first.
#  b. the worker picks the package before the memory check: a queued app resident in the background is asked to end
#     (compile_bg_kill / am kill) instead of blocking its own compile with "not enough free memory".
#  c. a preempt that found no dex2oat is retried on the next tick; the COMPILE_MAX_S timeout fires even after a preempt;
#     a compile that still ended with the requested filter + Success is recorded ok and not force-requeued.
# With 0.8.13's compile_nocode (an app with no usable code is compiled while in use) and the speed-profile fallback:
#  the restore uses compile_light (same filter choice as the timeout rescue), a running no-code app is left to the speed
#  retry instead of being restored twice, and b's resident target is an app that still has code (or COMPILE_RUNNING=0).
# Functions that touch Android or /proc are stubbed; /proc/uptime is faked through a cut shim.
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
C=${COMPILE_SH:-host/legacy/boot/lib/compile.sh}
sh -n $C || fail "syntax $C"
C=$(pwd)/$C

# --- static (CA_UNIT_ONLY=1 skips it, to run the unit part against an older compile.sh) ------------------------------
if [ -z "$CA_UNIT_ONLY" ]; then
w=$(sed -n '/^compile_worker()/,/^}/p' $C)
lk=$(printf '%s\n' "$w" | grep -n 'compile_bg_kill \$crun' | head -n 1 | cut -d: -f1)
lm=$(printf '%s\n' "$w" | grep -n 'if ! compile_mem_ok' | head -n 1 | cut -d: -f1)
[ -n "$lk" ] && [ -n "$lm" ] && [ "$lk" -lt "$lm" ] || fail "b: compile_worker checks memory before it picks the package / asks a resident app to end"
printf '%s\n' "$w" | grep -q 'compile_restore_next' || fail "a: compile_worker never restores aborted packages"
b=$(sed -n '/^compile_babysit()/,/^}/p' $C)
printf '%s\n' "$b" | grep -q 'killed=1' && fail "c: compile_babysit still sets killed=1 without checking the preempt"
printf '%s\n' "$b" | grep 'COMPILE_MAX_S:-540} \]' | grep -q 'killed' && fail "c: the COMPILE_MAX_S check still depends on killed"
sed -n '/^compile_preempt_pkg()/,/^}/p' $C | grep -q 'return \$cpp_r' || fail "c: compile_preempt_pkg does not say whether it stopped anything"
[ "$(grep -c 'compile_pm_start "\$1" \$W/compile.light.out -m \$rf -f' $C)" = 1 ] || fail "a: the light compile (interpret-only / speed-profile) is not done in one place (compile_light)"
sed -n '/^compile_one()/,/^}/p' $C | grep -q 'compile_light "\$pkg" \$r' || fail "a: compile_one's rescue does not use compile_light"

fi

# --- unit ---------------------------------------------------------------------------------------------------------
T=$(mktemp -d) || exit 2
trap 'kill $SP 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p $T/bin $T/w $T/x/ctl $T/sys/data/app/com.tencent.weread.eink-1 $T/sys/data/system
echo 1000 > $T/up
cat > $T/bin/cut <<EOF
#!/bin/sh
case "\$*" in *"/proc/uptime"*) cat $T/up; exit 0 ;; esac
exec $(command -v cut) "\$@"
EOF
if [ "$(uname -s)" != Linux ]; then # BSD sed -i (and no GNU \| in basic regexps) / stat -c
    cat > $T/bin/sed <<'EOF'
#!/bin/sh
[ "$1" = -i ] || exec /usr/bin/sed "$@"
e=$(printf '%s' "$2" | /usr/bin/sed -e 's/\\(/(/g; s/\\)/)/g; s/\\|/|/g')
exec /usr/bin/sed -i '' -E "$e" "$3"
EOF
    cat > $T/bin/stat <<EOF
#!/bin/sh
[ "\$1" = -c ] && [ "\$2" = %Y ] && { shift 2; exec /usr/bin/stat -f %m "\$@"; }
exec /usr/bin/stat "\$@"
EOF
fi
chmod +x $T/bin/*
P=com.tencent.weread.eink
run() { # shell snippet, run after sourcing compile.sh with stubs
    PATH=$T/bin:$PATH W=$T/w X=$T/x SYS=$T/sys T=$T P=$P timeout 60 sh -c '
        . "$0" 2>/dev/null
        t() { echo "$*" >> $T/log; }
        alive() { [ "$1" = $W/pid ]; }; lowmem_ram() { return 1; }
        adb_sh() { echo "$*" >> $T/adb; case "$*" in *"cmd package compile"*) [ -f $T/out ] && cat $T/out ;; esac; return 0; }
        adb_sh_t() { shift; adb_sh "$@"; }
        sleep() { echo $(( $(cat $T/up) + 2 )) > $T/up; command sleep 0.05; }
        pgrep() { [ -f $T/dex ] && cat $T/dex; return 0; }
        compile_fg() { cat $T/fg 2>/dev/null; }; compile_fg_abort() { return 0; }
        compile_session_pending() { return 1; }; compile_user_active() { return 1; }; compile_charging() { return 0; }
        compile_held() { return 1; }; compile_battery_ok() { return 0; }; compile_status() { :; }
        compile_app_running() { [ -f $T/running ]; }
        mem_avail_mb() { echo 500; }; compile_nap() { sleep 2; }
        odex_filter() { cat $T/filter 2>/dev/null; }
        '"$1" $C
}
reset() { rm -f $T/log $T/adb $T/out $T/fg $T/dex $T/running $T/filter $T/n $T/compiled $T/w/* 2>/dev/null; rm -rf $T/sys/data/misc; echo 1000 > $T/up; }

# c1: the first two preempts find nothing (dex2oat not started yet); the third stops it -> retried, recorded once
reset; command sleep 30 & SP=$!; echo "$P" > $T/fg
run 'compile_preempt_pkg() { n=$(( $(cat $T/n 2>/dev/null || echo 0) + 1 )); echo $n > $T/n; [ $n -ge 3 ] || return 1; kill '$SP'; return 0; }
     compile_babysit '$SP' $P'
[ "$(cat $T/n)" = 3 ] || fail "c1: preempt tried $(cat $T/n 2>/dev/null) times, want 3 (missed preempt not retried)"
[ "$(cat $T/w/compile.abort 2>/dev/null)" = foreground ] || fail "c1: abort reason '$(cat $T/w/compile.abort 2>/dev/null)'"
[ "$(grep -c 'retrying' $T/log)" = 1 ] || fail "c1: missed preempt logged $(grep -c retrying $T/log) times"
echo "c1 ok: missed preempt retried on the next tick"

# c2: the preempt never finds it, dex2oat keeps running -> the COMPILE_MAX_S timeout still kills it
reset; command sleep 30 & SP=$!; echo "$P" > $T/fg; echo $SP > $T/dex
run 'compile_preempt_pkg() { return 1; }; COMPILE_MAX_S=6; compile_babysit '$SP' $P'
kill -0 $SP 2>/dev/null && fail "c2: dex2oat still running: timeout did not fire after a missed preempt"
[ "$(cat $T/w/compile.abort 2>/dev/null)" = timeout ] || fail "c2: abort reason '$(cat $T/w/compile.abort 2>/dev/null)', want timeout"
echo "c2 ok: timeout fires after a missed preempt"

# c3: babysit wanted to stop it (busy) but dex2oat finished: speed + Success -> ok, not force-requeued
reset; echo speed > $T/filter; echo Success > $T/out
run 'compile_babysit() { echo busy > $W/compile.abort; }; compile_one $P speed force'
[ "$(cut -d" " -f2 $T/w/compile.last)" = ok ] || fail "c3: recorded '$(cat $T/w/compile.last)', want ok"
grep -q "^$P" $T/w/compile.queue 2>/dev/null && fail "c3: a finished compile was force-requeued"
[ -f $T/w/compile.needidle ] && fail "c3: needidle set after a finished compile"
echo "c3 ok: finished compile after a missed preempt recorded ok"

# a: aborted (running) and the odex is gone -> on compile.restore; while the app runs nothing; after it exits interpret-only
reset; echo Failure > $T/out
run 'compile_babysit() { echo running > $W/compile.abort; }; compile_one $P speed force'
grep -qx "$P" $T/w/compile.restore || fail "a: aborted package without odex not on compile.restore"
grep -qx "$P force" $T/w/compile.queue || fail "a: aborted package not re-queued for speed"
: > $T/running; : > $T/adb
run 'compile_restore_next' && fail "a: restored while the app is still running"
grep -q "compile -m" $T/adb && fail "a: compile started while the app is running"
rm -f $T/running
run 'compile_babysit() { echo interpret-only > $T/filter; }; compile_restore_next' || fail "a: nothing restored after the app exited"
grep -q "cmd package compile -m interpret-only -f $P" $T/adb || fail "a: no interpret-only compile: $(cat $T/adb)"
[ -s $T/w/compile.restore ] && fail "a: still on compile.restore after a successful restore"
grep -q "restored to interpret-only" $T/log || fail "a: restore not logged"
echo "a ok: aborted compile restored to interpret-only after the app exited"

# a2: timeout with a JIT profile -> compile_one's rescue (compile_light) uses speed-profile (e281fc6 kept)
reset; echo Failure > $T/out; mkdir -p $T/sys/data/misc/profiles/cur/0/$P; echo x > $T/sys/data/misc/profiles/cur/0/$P/primary.prof
run 'compile_babysit() { wait $1; tail -n 1 $T/adb | grep -q speed-profile && echo speed-profile > $T/filter || echo timeout > $W/compile.abort; }; compile_one $P speed force'
grep -q "cmd package compile -m speed-profile -f $P" $T/adb || fail "a2: timeout rescue did not use speed-profile: $(cat $T/adb)"
grep -q "restored to speed-profile (speed-profile)" $T/log || fail "a2: rescue not logged: $(cat $T/log)"
[ -s $T/w/compile.restore ] && fail "a2: a timeout went on compile.restore (rescued already)"
echo "a2 ok: timeout rescue still speed-profile, not also on the restore list"

# a3: no usable code -> babysit does not stop it when the app starts (fe83149 kept), nothing to restore
reset; command sleep 30 & SP=$!; : > $T/running; : > $T/w/compile.nocode_now
run 'compile_preempt_pkg() { echo x >> $T/n; return 0; }; ( command sleep 3; kill '$SP' ) & compile_babysit '$SP' $P'
[ -f $T/n ] && fail "a3: a no-code compile was stopped because the app runs"
echo "a3 ok: no-code app still compiled while it runs"

# b: the only queued app is resident in the background and holds the memory (150 MB free while it runs):
#    the worker asks Android to end it, then compiles it -- no "not enough free memory"
reset; : > $T/running; echo "$P force" > $T/w/compile.queue; echo speed-profile > $T/filter
run 'mem_avail_mb() { [ -f $T/running ] && echo 150 || echo 400; }
     adb_sh() { echo "$*" >> $T/adb; case "$*" in "am kill"*) rm -f $T/running ;; esac; }
     adb_sh_t() { shift; adb_sh "$@"; }
     compile_one() { echo "$1" >> $T/compiled; }
     COMPILE_RUNNING_WAIT_S=0; compile_worker'
grep -qx "$P" $T/compiled 2>/dev/null || fail "b: resident app never compiled: $(cat $T/log 2>/dev/null)"
[ "$(grep -c . $T/compiled)" = 1 ] || fail "b: compiled $(grep -c . $T/compiled) times"
grep -q "am kill $P" $T/adb || fail "b: resident app not asked to end"
grep -q "not enough free memory" $T/log 2>/dev/null && fail "b: memory wait before the resident target was freed"
echo "b ok: resident background target freed first, then compiled"

# b2: same with no code but COMPILE_RUNNING=0 (old rule: never compile a running app)
reset; : > $T/running; echo "$P force" > $T/w/compile.queue
run 'mem_avail_mb() { [ -f $T/running ] && echo 150 || echo 400; }
     adb_sh() { echo "$*" >> $T/adb; case "$*" in "am kill"*) rm -f $T/running ;; esac; }
     compile_one() { echo "$1" >> $T/compiled; }
     COMPILE_RUNNING=0 COMPILE_RUNNING_WAIT_S=0; compile_worker'
grep -q "am kill $P" $T/adb && grep -qx "$P" $T/compiled || fail "b2: COMPILE_RUNNING=0 resident app not freed + compiled"
grep -q "not enough free memory" $T/log 2>/dev/null && fail "b2: memory wait before the resident target was freed"
echo "b2 ok"

echo "compile-abort: ok"
