#!/bin/sh
# VeraDroid speed benchmark: runs ON the Kindle host (busybox sh), new-model (pw6 / k49) and legacy layouts alike.
# Driven from a computer by tools/bench/run.sh (pushes this file to /dev/shm, runs it detached, collects the output).
#
#   sh vdbench.sh <label> <phases> [runs]          phases: comma list of  info boot ret thaw app turn panel mem  (or "all")
#
# Output, one line per sample (parsed by tools/bench/summarize.py):
#   I <key> <value>                      device / build facts
#   M <metric> <run> <value>             one sample; times in ms, memory in KB
#   L <phase> <run> <+ms> <host log line>   host log (veradroid.log) lines seen during that sample, relative to its start
# Times: CLOCK_MONOTONIC ms (/proc/timer_list "now at"), the same clock the display bridge (epd.log) and veradroid-input
# (input.log) stamp their lines with. Host log lines carry /proc/uptime: converted with the offset measured at start
# (equal while the device does not suspend: the benchmark keeps the screensaver off and restores the old value).
#
# Environment (all optional):
#   APPS="pkg[/activity] ..."   apps for the "app" phase (default: WeRead, EinkBro, 多看 when installed)
#   DROP=1                      drop the page cache before every cold boot / cold app start (default 0 = process-cold only)
#   TURN="cmd;cmd"              inject commands for the "turn" phase (default: swipe right-to-left on the current app)
#   TURN_APP=pkg/activity       open this before the "turn" phase (default: stay on the VeraHome desktop)
#   SETTLE_MS=2500              quiet time that counts as "screen settled"
W=/dev/shm/veradroid; X=$W/kfb; VD=/mnt/base-us/veradroid; SYS=/mnt/base-us/system/veradroid; LOG=$SYS/veradroid.log
A="sh $VD/boot/ashell.sh"
LABEL=${1:-bench}; PHASES=${2:-all}; RUNS=${3:-5}
[ "$PHASES" = all ] && PHASES=info,boot,mem,ret,thaw,app,panel,turn
SETTLE_MS=${SETTLE_MS:-2500}

mono() { awk '/^now at/ { printf "%d\n", $3 / 1000000; exit }' /proc/timer_list 2>/dev/null; }
upms() { awk '{ printf "%d\n", $1 * 1000 }' /proc/uptime; }
# monotonic - uptime (both ms); 0 when /proc/timer_list is missing (then everything is uptime)
OFS=$(( $(mono || echo 0) - $(upms) )); [ "$(mono)" ] || OFS=0
now() { if [ "$OFS" = 0 ]; then upms; else mono; fi; }
msleep() { usleep $(($1 * 1000)); }
say() { echo "$*"; }
M() { echo "M $1 $2 $3"; }
running() { p=$(cat $W/pid 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
frozen() { [ -f $W/frozen ]; }
booted() { running && [ "$($A 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n ')" = 1 ]; }
fg_pkg() { cat $X/fg 2>/dev/null; }
epd_lines() { wc -l < $W/epd.log 2>/dev/null || echo 0; }
log_lines() { wc -l < $LOG 2>/dev/null || echo 0; }

# The host log lives on the system image: between stop.sh and the next start it is not there (line counts restart at 0),
# so lines are also filtered by time: only those at/after LT0 (monotonic ms, set at the start of each sample) count.
LT0=0
# host log lines since line $1, as "L phase run +ms text" relative to t0 ($4, monotonic ms)
dump_log() { # from_line phase run t0
    tail -n +$(($1 + 1)) $LOG 2>/dev/null | awk -v ph=$2 -v r=$3 -v t0=$4 -v ofs=$OFS '
        match($0, /up=[0-9.]+\]/) { u = substr($0, RSTART + 3, RLENGTH - 4) * 1000 + ofs; txt = substr($0, RSTART + RLENGTH + 1)
            if (u >= t0 - 50) printf "L %s %d +%d %s\n", ph, r, u - t0, txt }'
}
# host log: monotonic ms of the first line (after line $1, at/after LT0) matching $2, or empty
log_time() {
    tail -n +$(($1 + 1)) $LOG 2>/dev/null | grep -- "$2" | sed -n 's/.*up=\([0-9.]*\)\].*/\1/p' | awk -v ofs=$OFS -v lt=$LT0 '{ v = int($1 * 1000 + ofs); if (v >= lt - 50) { print v; exit } }'
}
wait_log() { # from_line pattern timeout_ms -> prints ms timestamp or nothing
    wl_e=$(( $(now) + $3 ))
    while [ $(now) -lt $wl_e ]; do v=$(log_time $1 "$2"); [ -n "$v" ] && { echo $v; return 0; }; msleep 100; done
    return 1
}
# display bridge refreshes after epd.log line $1 and at/after time $2: "first last count" once the panel has been quiet
# for SETTLE_MS (or $3 ms passed). first/last = monotonic ms of the first / last refresh sent.
epd_settle() { # from_line t_from max_ms
    es_end=$(( $(now) + $3 )); es_last=; es_first=; es_n=0
    while :; do
        set -- $(tail -n +$(($1 + 1)) $W/epd.log 2>/dev/null | awk -v t=$2 '
            /epd: [0-9]+x[0-9]+\+/ { v = substr($1, 2) + 0; if (v >= t) { if (!f) f = v; l = v; n++ } }
            END { print (f ? f : 0), (l ? l : 0), n + 0 }') "$1" "$2" "$3"
        es_first=$1; es_last=$2; es_n=$3; shift 3
        nw=$(now)
        [ "$es_n" -gt 0 ] && [ $((nw - es_last)) -ge $SETTLE_MS ] && break
        [ $nw -ge $es_end ] && break
        msleep 200
    done
    echo "$es_first $es_last $es_n"
}
keep_awake_on() { KA0=$(lipc-get-prop com.lab126.powerd preventScreenSaver 2>/dev/null); lipc-set-prop -i com.lab126.powerd preventScreenSaver 1 2>/dev/null; }
keep_awake_off() { [ -n "$KA0" ] && lipc-set-prop -i com.lab126.powerd preventScreenSaver "$KA0" 2>/dev/null; }
# host scripts that have perf_mark (common.sh) log extra "perf: ..." lines while this flag exists
PF0=; [ -f /dev/shm/vdperf ] && PF0=1; touch /dev/shm/vdperf
trap 'rm -f /dev/shm/vdbench.amon; keep_awake_off; [ -f $X/ctl/timing.vdbench ] && rm -f $X/ctl/timing $X/ctl/timing.vdbench; [ -n "$PF0" ] || rm -f /dev/shm/vdperf' EXIT
keep_awake_on

start_android() { (cd / && setsid sh $VD/boot/veradroid.sh home </dev/null >/dev/null 2>&1 &); }
stop_android() { (cd / && sh $VD/boot/stop.sh </dev/null >/dev/null 2>&1); }
home() { $A 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME' >/dev/null 2>&1; }
ensure_up() { # Android running, not frozen, booted, desktop in front
    if ! running; then start_android; fi
    if frozen; then start_android; fi
    i=0; while [ $i -lt 600 ] && ! booted; do sleep 1; i=$((i + 1)); done
    i=0; while [ $i -lt 100 ] && frozen; do msleep 200; i=$((i + 1)); done
    home; sleep 3
}
pids_of() { for d in /proc/[0-9]*; do c=$(tr '\0' ' ' < $d/cmdline 2>/dev/null); case "$c" in "$1"|"$1 "*) echo ${d#/proc/} ;; esac; done; }
pss() { awk '/^Pss:/ { s += $2 } END { print s + 0 }' /proc/$1/smaps 2>/dev/null; }

ph_info() {
    say "I label $LABEL"
    say "I version $(cat $VD/version 2>/dev/null)"
    say "I model $(cat $VD/model 2>/dev/null)"
    say "I firmware $(head -1 /etc/prettyversion.txt 2>/dev/null | sed 's/^Kindle //; s/ .*//')"
    say "I kernel $(uname -r)"
    say "I memtotal_kb $(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    say "I cpus $(grep -c '^processor' /proc/cpuinfo)"
    say "I clock $([ "$OFS" = 0 ] && echo uptime || echo monotonic)"
    say "I settings $(grep -E '^(KINDLE_UI|RETURN_MODE|KFB_MODE|DISPLAY_MODE|PERF_[A-Z_]*)=' $SYS/settings.conf 2>/dev/null | tr '\n' ' ')"
}

# cold boot: stop -> start; boot_completed (ctl/booted / getprop), first refresh after the splash is released, desktop settled
ph_boot() {
    r=0
    while [ $r -lt $RUNS ]; do r=$((r + 1))
        running && { stop_android; sleep 3; }
        [ "${DROP:-0}" = 1 ] && { sync; echo 3 > /proc/sys/vm/drop_caches; sleep 1; }
        l0=$(log_lines); t0=$(now); LT0=$t0
        start_android
        tb=; tr=; e=$((t0 + 600000)); n=0
        # boot-completed marker (ctl/booted, bootwatch.sh boot_mark_setup) only on hosts that have it; otherwise getprop every ~1 s
        mk=; grep -q vd-bootmark $SYS/rootfs/init.kindle.rc 2>/dev/null || grep -q boot_mark_setup $VD/boot/lib/bootwatch.sh 2>/dev/null && mk=1
        while [ $(now) -lt $e ]; do
            n=$((n + 1))
            if [ -z "$tb" ]; then
                if [ -n "$mk" ]; then [ -f $X/ctl/booted ] && tb=$(now)
                elif [ $n -gt 30 ] && [ $((n % 8)) = 0 ] && booted; then tb=$(now); fi
            fi
            if [ -n "$tb" ] && [ -z "$tr" ]; then
                [ -f $W/bw.released ] && { tr=$(now); break; }
                v=$(log_time $l0 'boot watch: done'); [ -n "$v" ] && { tr=$v; break; }
                [ $(( $(now) - tb )) -gt 60000 ] && break
            fi
            msleep 100
        done
        [ -n "$tb" ] && M boot.boot_completed $r $((tb - t0))
        [ -n "$tr" ] && M boot.splash_released $r $((tr - t0))
        # epd.log starts empty at display_start and the bridge logs nothing while the splash holds it: every refresh line is from the release on
        set -- $(epd_settle 0 $t0 60000)
        [ "$1" -gt 0 ] && { M boot.home_first_refresh $r $(($1 - t0)); M boot.home_settled $r $(($2 - t0)); M boot.home_refreshes $r $3
            M boot.full_flashes $r $(grep -c 'full=1 .*-> 0 (' $W/epd.log 2>/dev/null); }
        tk=$(log_time $l0 'kindle ui paused\|kindle ui stopped\|kindle ui already')
        [ -n "$tk" ] && M boot.kindle_ui_paused $r $((tk - t0))
        tst=$(log_time $l0 '] started$'); [ -n "$tst" ] && M boot.host_started $r $((tst - t0))
        dump_log $l0 boot $r $t0
        # Android's own boot phases (zygote preload, package scan, system services): "Z boot run <line>"
        $A 'logcat -d -v monotonic 2>/dev/null | grep -E "Zygote *: \.\.\.preloaded|Preloading|Time to scan packages|SystemServerTiming|PackageManager: Finished scanning"; logcat -b events -d -v monotonic 2>/dev/null | grep boot_progress' 2>/dev/null | tr -d '\r' | sed "s/^/Z boot $r /"
        sleep ${BOOT_GAP:-15}
    done
}

# return to Kindle (desktop in front -> "exit" on the command FIFO) and thaw (start again while frozen)
ph_ret() {
    r=0
    while [ $r -lt $RUNS ]; do r=$((r + 1))
        ensure_up; sleep 5
        l0=$(log_lines); t0=$(now); LT0=$t0
        sp0=$(cat /tmp/veradroid-stop.pid 2>/dev/null)
        # library app answering (what framework.sh kindle_home waits for), polled from the start in parallel: the Kindle home can
        # take taps from then on, even while the host is still restarting background services
        rm -f /dev/shm/vdbench.lib
        ( e=$(( $(now) + 240000 )); while [ $(now) -lt $e ]; do
              if lipc-probe com.lab126.KPPMainApp 2>/dev/null | grep -qw go || { [ ! -f /etc/upstart/kppmainapp.conf ] && lipc-get-prop com.lab126.appmgrd activeApp >/dev/null 2>&1; }; then
                  [ $(now) -gt $((t0 + 300)) ] && { now > /dev/shm/vdbench.lib; exit 0; }
              fi
              msleep 200
          done ) & lp=$!
        ( echo exit > $X/ctl/cmd ) & wp=$!
        # freeze (RETURN_MODE=freeze): the host logs "kindle ui resumed" when framework_start is done (library asked to draw);
        # off / KINDLE_UI=stop: stop.sh runs (its log goes to the system image, which it unmounts): done = no stop.sh, no container
        tk=; e=$(( $(now) + 240000 )); sp=
        while [ $(now) -lt $e ]; do
            v=$(log_time $l0 'kindle ui resumed'); [ -z "$v" ] && v=$(log_time $l0 'frozen, kindle ui back'); [ -n "$v" ] && { tk=$v; break; }
            [ -z "$sp" ] && { sp=$(cat /tmp/veradroid-stop.pid 2>/dev/null); [ "$sp" = "$sp0" ] && sp=; }
            if [ -n "$sp" ] && ! kill -0 "$sp" 2>/dev/null && ! running && ! frozen; then tk=$(now); break; fi
            msleep 200
        done
        kill $wp 2>/dev/null
        [ -n "$tk" ] && M ret.kindle_back $r $((tk - t0))
        v=$(log_time $l0 'perf: fw: kindle screen restored'); [ -n "$v" ] && M ret.kindle_screen $r $((v - t0))
        i=0; while [ ! -s /dev/shm/vdbench.lib ] && kill -0 $lp 2>/dev/null && [ $i -lt 600 ]; do msleep 200; i=$((i + 1)); done
        kill $lp 2>/dev/null
        [ -s /dev/shm/vdbench.lib ] && M ret.library_ready $r $(( $(cat /dev/shm/vdbench.lib) - t0 ))
        dump_log $l0 ret $r $t0
        # memory on the Kindle side while Android is frozen / stopped (what the Kindle UI has to work with)
        sleep ${RET_MEM_WAIT:-20}
        M ret.kindle_memavailable_kb $r $(awk '/^MemAvailable:/ { print $2; f = 1 } END { if (!f) print 0 }' /proc/meminfo)
        M ret.kindle_swap_used_kb $r $(awk '/^SwapTotal:/ { t = $2 } /^SwapFree:/ { f = $2 } END { print t - f }' /proc/meminfo)
        # re-enter when Android was stopped (RETURN_MODE=off): a cold start; time to the desktop's first refresh
        if ! frozen; then
            [ "${REENTER_COLD:-1}" = 1 ] || continue
            rm -f $W/bw.released; t0=$(now); LT0=$t0; start_android
            e=$((t0 + 600000)); while [ $(now) -lt $e ] && ! [ -f $W/bw.released ]; do msleep 200; done
            set -- $(epd_settle 0 $t0 60000)
            [ "$1" -gt 0 ] && { M reenter.first_refresh $r $(($1 - t0)); M reenter.settled $r $(($2 - t0)); }
            continue
        fi
        l0=$(log_lines); e0=$(epd_lines); t0=$(now); LT0=$t0
        start_android
        th=$(wait_log $l0 '] thawed$' 60000)
        [ -n "$th" ] && M thaw.thawed $r $((th - t0))
        set -- $(epd_settle $e0 $t0 20000)
        [ "$1" -gt 0 ] && { M thaw.first_refresh $r $(($1 - t0)); M thaw.settled $r $(($2 - t0)); M reenter.first_refresh $r $(($1 - t0)); M reenter.settled $r $(($2 - t0)); }
        dump_log $l0 thaw $r $t0
        sleep 3
    done
}
ph_thaw() { :; }   # measured together with ret

resolve() { # pkg[/act] -> component
    case "$1" in */*) echo $1; return ;; esac
    c=$($A "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $1" 2>/dev/null | tr -d '\r' | grep / | tail -1)
    [ -z "$c" ] && c=$($A "dumpsys package $1" 2>/dev/null | tr -d '\r' | awk '/android.intent.action.MAIN:/ { getline; print $2; exit }')
    echo $c
}
# run "$@" with a time limit (busybox timeout differs between firmware generations): prints its output
tmo() { tm_s=$1; shift; "$@" > /dev/shm/vdbench.tmo 2>&1 & tm_p=$!; tm_i=0
    while kill -0 $tm_p 2>/dev/null && [ $tm_i -lt $((tm_s * 5)) ]; do msleep 200; tm_i=$((tm_i + 1)); done
    kill -0 $tm_p 2>/dev/null && { kill $tm_p 2>/dev/null; say "W timeout ${tm_s}s: $*"; }
    cat /dev/shm/vdbench.tmo; rm -f /dev/shm/vdbench.tmo; }
am_total() { sed -n 's/^TotalTime: *\([0-9]*\).*/\1/p' | tr -d '\r' | head -1; }
# WeRead's launcher is a trampoline: "am start -W" never returns and its process stays in the container after the host-side
# timeout. While the app phase runs, a guard kills "am start -W" processes seen for ~45 s.
am_guard() {
    mkdir -p /dev/shm/vdbench.am
    while [ -f /dev/shm/vdbench.amon ]; do
        for d in /proc/[0-9]*; do
            case "$(tr '\0' ' ' < $d/cmdline 2>/dev/null)" in *com.android.commands.am.Am\ start\ -W*)
                p=${d#/proc/}; n=$(( $(cat /dev/shm/vdbench.am/$p 2>/dev/null || echo 0) + 1 )); echo $n > /dev/shm/vdbench.am/$p
                [ $n -ge 9 ] && kill $p 2>/dev/null ;;
            esac
        done
        sleep 5
    done
    rm -rf /dev/shm/vdbench.am
}
ph_app() {
    ensure_up
    : > /dev/shm/vdbench.amon; am_guard & 
    [ "${EPDLOG:-0}" = 1 ] && [ ! -f $X/ctl/timing ] && touch $X/ctl/timing $X/ctl/timing.vdbench
    apps=${APPS:-}
    if [ -z "$apps" ]; then
        for p in com.tencent.weread.eink info.plateaukao.einkbro com.duokan.einkreader com.duokan.reader; do
            $A "pm path $p" 2>/dev/null | grep -q package: && apps="$apps $p"
        done
    fi
    [ -n "$apps" ] || { say "W app: none of the default apps installed"; return; }
    for a in $apps; do
        comp=$(resolve $a); pkg=${comp%%/*}
        [ -n "$comp" ] || { say "W app: cannot resolve $a"; continue; }
        n=$(echo $pkg | sed 's/.*\.//')
        r=0
        while [ $r -lt $RUNS ]; do r=$((r + 1))
            home; $A "am force-stop $pkg" >/dev/null 2>&1; sleep 3
            [ "${DROP:-0}" = 1 ] && { sync; echo 3 > /proc/sys/vm/drop_caches; sleep 1; }
            e0=$(epd_lines); t0=$(now)
            if [ "${APP_VIA:-am}" = home ]; then
                # the way the desktop opens an app (HostService: per-app display profile / density first, then the launch intent)
                echo $pkg > $X/ctl/app.tmp && mv -f $X/ctl/app.tmp $X/ctl/app
            else
                tt=$(tmo 40 $A "am start -W -n $comp" | am_total)
                [ -n "$tt" ] && M app.$n.cold_total $r $tt
            fi
            set -- $(epd_settle $e0 $t0 30000)
            [ "$1" -gt 0 ] && { M app.$n.cold_first_refresh $r $(($1 - t0)); M app.$n.cold_settled $r $(($2 - t0)); M app.$n.cold_refreshes $r $3; }
            # EPDLOG=1: every display bridge line of this cold start, relative to the am start ("E app.<name> run +ms line")
            [ "${EPDLOG:-0}" = 1 ] && tail -n +$((e0 + 1)) $W/epd.log | awk -v n=$n -v r=$r -v t0=$t0 '/^\[[0-9]+\]/ { v = substr($1, 2) + 0; $1 = ""; printf "E app.%s %d +%d%s\n", n, r, v - t0, $0 }' 
            # warm: back to the desktop, open again (process alive)
            home; sleep 3
            e0=$(epd_lines); t0=$(now)
            tt=$(tmo 40 $A "am start -W -n $comp" | am_total)
            [ -n "$tt" ] && M app.$n.warm_total $r $tt
            set -- $(epd_settle $e0 $t0 20000)
            [ "$1" -gt 0 ] && { M app.$n.warm_first_refresh $r $(($1 - t0)); M app.$n.warm_settled $r $(($2 - t0)); }
        done
        home; sleep 2
    done
    rm -f /dev/shm/vdbench.amon
}

# panel: the same file the top-edge gesture writes (action.sh run_action panel) -> PanelActivity drawn and settled
ph_panel() {
    ensure_up
    r=0
    while [ $r -lt $RUNS ]; do r=$((r + 1))
        home; sleep 3
        e0=$(epd_lines); t0=$(now)
        : > $X/ctl/.act.panel.vdb && mv -f $X/ctl/.act.panel.vdb $X/ctl/act.panel
        set -- $(epd_settle $e0 $t0 15000)
        [ "$1" -gt 0 ] && { M panel.first_refresh $r $(($1 - t0)); M panel.settled $r $(($2 - t0)); }
        $A 'input keyevent 4' >/dev/null 2>&1; sleep 2
    done
}

# page turn: injected touch -> first refresh / panel done (needs ctl/timing; we create it for the run and remove it)
ph_turn() {
    ensure_up
    [ -p $W/inject ] || { say "W turn: no inject FIFO ($W/inject)"; return; }
    VW=$(tr '\0' ' ' < /proc/$(cat $W/input.pid 2>/dev/null)/cmdline 2>/dev/null | sed -n 's/.*--w \([0-9]*\).*/\1/p')
    VH=$(tr '\0' ' ' < /proc/$(cat $W/input.pid 2>/dev/null)/cmdline 2>/dev/null | sed -n 's/.*--h \([0-9]*\).*/\1/p')
    VW=${VW:-1272}; VH=${VH:-1696}
    [ -n "$TURN_APP" ] && { $A "am start -W -n $TURN_APP" >/dev/null 2>&1; sleep 5; }
    cmds=${TURN:-"swipe $((VW * 8 / 10)) $((VH / 2)) $((VW * 2 / 10)) $((VH / 2)) 150;swipe $((VW * 2 / 10)) $((VH / 2)) $((VW * 8 / 10)) $((VH / 2)) 150"}
    [ -f $X/ctl/timing ] || { touch $X/ctl/timing $X/ctl/timing.vdbench; }
    r=0; k=0
    while [ $r -lt $((RUNS * 2)) ]; do r=$((r + 1))
        c=$(echo "$cmds" | cut -d';' -f$((k % $(echo "$cmds" | awk -F';' '{print NF}') + 1))); k=$((k + 1))
        e0=$(epd_lines); i0=$(wc -l < $W/input.log 2>/dev/null || echo 0); t0=$(now)
        echo "$c" > $W/inject
        set -- $(epd_settle $e0 $t0 ${TURN_MAX:-6000})
        td=$(tail -n +$((i0 + 1)) $W/input.log 2>/dev/null | sed -n 's/^\[\([0-9]*\)\] inject \(tap\|swipe\|down\).*/\1/p' | head -1)
        [ -n "$td" ] || td=$t0
        if [ "$1" -gt 0 ]; then
            M turn.first_refresh $r $(($1 - td)); M turn.last_refresh $r $(($2 - td))
            dn=$(tail -n +$((e0 + 1)) $W/epd.log | awk -v l=$2 '/panel done after/ { v = substr($1, 2) + 0; if (v >= l && !d) d = v } END { print d + 0 }')
            [ "$dn" -gt 0 ] && M turn.panel_done $r $((dn - td))
            M turn.refreshes $r $3
        fi
        sleep 1
    done
    [ -f $X/ctl/timing.vdbench ] && rm -f $X/ctl/timing $X/ctl/timing.vdbench
    [ -n "$TURN_APP" ] && home
}

# memory once the desktop has been idle MEM_WAIT seconds
ph_mem() {
    ensure_up
    say "I verahome $($A 'dumpsys package com.veradroid.home' 2>/dev/null | tr -d '\r' | grep -m1 versionCode | awk '{print $1}')"
    sleep ${MEM_WAIT:-30}
    r=1
    M mem.memavailable_kb $r $(awk '/^MemAvailable:/ { print $2; f = 1 } END { if (!f) print 0 }' /proc/meminfo)
    M mem.memfree_cached_kb $r $(awk '/^MemFree:|^Cached:|^Buffers:/ { s += $2 } END { print s }' /proc/meminfo)
    M mem.swap_used_kb $r $(awk '/^SwapTotal:/ { t = $2 } /^SwapFree:/ { f = $2 } END { print t - f }' /proc/meminfo)
    for p in system_server com.veradroid.home /system/bin/surfaceflinger; do
        n=$(echo $p | sed 's#.*/##; s/^com\.veradroid\.//'); s=0
        for q in $(pids_of $p); do s=$((s + $(pss $q))); done
        M mem.pss_${n}_kb $r $s
    done
}

say "I start $(date '+%F %T')"
for ph in $(echo $PHASES | tr ',' ' '); do
    say "P $ph $(date +%T)"
    ph_$ph
done
say "I end $(date '+%F %T')"
echo DONE
