# 启动时离线扩大系统盘（老机型）。storage.sh 在 source 时把这个文件带进来，st_recover 收尾以后调 sg_start_grow。
#
# 为什么要有：系统盘镜像是安装时按 Kindle 剩余空间挑的大小（1536 / 1024 / 768 MB），之后不会自己长到合适的大小。
# 看门狗的自动扩容（storage.sh 的 st_auto_tick）只在镜像剩不到 200 MB 时扩 512 MB，而且最多只用到“Kindle 剩余 − 256 MB”；
# Kindle 当时没地方就只说一句“不能再扩大”，以后用户腾出了地方也不会再长。镜像剩得太少时 Android 会出这串问题
# （Oasis 3 模拟器，镜像 760 MB、只剩 32 MB）：zygote 不肯重定位启动镜像（“only 31.69 megabytes available after image
# generation, need at least 50”）→ dalvik-cache/arm 一直是空的 → 所有 dex2oat 失败（“Only the zygote can create the global
# boot image”）→ 大应用（微信读书 2.1.2，239 MB）全靠解释执行 → TIME_TICK 广播超时 ANR → 被杀，看起来就是黑屏退出。
#
# 做法：每次真正启动 Android（veradroid.sh，镜像还没挂上）时看一眼。镜像小于 SG_TARGET，或者里面剩不到 SG_LOW，
# 而 Kindle 那边扣掉安全余量（至少 500 MB、且不少于总容量的 10%）还放得下，就在挂载前离线扩大：
#   e2fsck -f（不干净就不动）→ 记“进行中”→ 先把镜像文件加长（每次 32 MB、落盘一次，FAT 没有稀疏文件，
#   一次写几百 MB 会把 512 MB 内存的机器卡死）→ 记“正在 resize”→ resize2fs → 再 e2fsck -f → 清掉标记。
# 断电 / 被杀：用的是 storage.sh 同一套标记（state/resize.state），下次 storage_mount 的 st_recover 会把文件加完、
#   把文件系统补到文件大小、再 e2fsck；文件系统在 resize2fs 之前一直是原来的大小，文件比文件系统长不影响挂载。
#   加长失败就把文件截回原大小（截之前 st_cut 先看超级块，文件系统比目标大就不截）。
# 每一步都有超时；resize2fs 超时被杀以后先 e2fsck -f -y，文件系统还是原大小就把文件截回去。
#
# 3.0（ext3）和 4.1（ext4）的固件都自带 /sbin/resize2fs 和 /sbin/e2fsck（PW2 5.12.2.2、Voyage 5.13.6、PW3 5.16.2.1.1、
# PW4 5.15.1.1 / 5.18.1.1.1、Oasis 2 5.15.1.1 / 5.16.2.1.1、Oasis 3 5.16.2.1 / 5.17.1 / 5.18.2.1.1、KT4 5.15–5.18 的
# 根文件系统逐个查过）；没有的话 st_tool 会用整包 bin/ 里的静态版（没有就不扩，只记日志）。
#
# 可调（不进系统盘，镜像没挂上时也读得到）：/mnt/base-us/veradroid/state/sysgrow.conf，一行一个 KEY=数字：
#   SYSGROW=0 关掉；SG_TARGET / SG_LOW / SG_KEEP_MIN / SG_KEEP_PCT 覆盖下面的默认值。桌面里关掉“自动扩大”
#   （storage.sh 的 st_cmd auto off）也会写 state/storage.auto=0，这里同样不做。
SG_TARGET=1536      # 目标大小（MB）。新机型的系统盘是 2048；老机型存储小（KT4 4 GB），1536 起
SG_LOW=300          # 镜像里剩余少于这么多 MB 也扩（就算已经 ≥ 目标）：再加 SG_STEP
SG_STEP=512
SG_MIN_GAIN=128     # 扩不到这么多就不折腾
SG_KEEP_MIN=500     # 至少给 Kindle 留这么多 MB……
SG_KEEP_PCT=10      # ……而且不少于 Kindle 总容量的这么多 %
SG_HINT=100         # 运行中系统盘剩余少于这么多 MB：记日志（桌面的设备卡片和存储空间页自己会提示）
SG_FSCK_TMO=900; SG_RESIZE_TMO=1200; SG_CHUNK_TMO=120   # 秒
SG_CONF=/mnt/base-us/veradroid/state/sysgrow.conf
SG_AUTO=/mnt/base-us/veradroid/state/storage.auto
SG_SKIP=/mnt/base-us/veradroid/state/sysgrow.skip   # 上次“想扩但扩不动”时的数字（同样的只记一次日志）

sg_conf() {
    [ -f $SG_CONF ] || return 0
    for k in SYSGROW SG_TARGET SG_LOW SG_KEEP_MIN SG_KEEP_PCT; do
        v=$(sed -n "s/^$k=\([0-9][0-9]*\)\$/\1/p" $SG_CONF 2>/dev/null | tail -1)
        st_num "$v" && eval "$k=$v"
    done
    return 0
}
sg_tmo() { if type vd_timeout >/dev/null 2>&1; then vd_timeout "$@"; else shift; "$@"; fi; }
sg_fsck() { # e2fsck -f -y 加超时。0 = 干净或已修好
    f=$(st_tool e2fsck) || return 9
    sg_tmo $SG_FSCK_TMO "$f" -f -y "$SYSTEM_IMG" >> $ST_LOG 2>&1; rc=$?
    if [ $rc -ge 4 ] && [ $rc -ne 124 ] && [ $rc -ne 143 ]; then sg_tmo $SG_FSCK_TMO "$f" -f -y "$SYSTEM_IMG" >> $ST_LOG 2>&1; rc=$?; fi
    echo "-- $(date '+%F %T') sysgrow e2fsck -f -y rc=$rc" >> $ST_LOG
    [ $rc -lt 4 ]
}
# 镜像文件加长到 MB：每次追加 32 MB 并落盘，每块都有超时。被打断的话文件只是长了一截，文件系统没动。
sg_extend() {
    cur=$(st_img_mb); [ "$1" -gt "$cur" ] || return 0
    # 文件长度不是整 MB：最后那不满 1 MB 里可能就是文件系统的块，dd 从整 MB 处写零会盖掉它。先把它补齐到整 MB。
    b=$(stat -c %s "$SYSTEM_IMG" 2>/dev/null); case "$b" in ""|*[!0-9]*) return 1 ;; esac
    if [ $((b % 1048576)) -ne 0 ]; then
        cur=$((cur + 1)); sg_tmo $SG_CHUNK_TMO truncate -s "${cur}M" "$SYSTEM_IMG" 2>/dev/null || return 1
        [ "$(stat -c %s "$SYSTEM_IMG" 2>/dev/null)" = $((cur * 1048576)) ] || return 1
    fi
    pri=; command -v nice >/dev/null 2>&1 && pri="nice -n 10"
    while [ "$cur" -lt "$1" ]; do
        n=$(($1 - cur)); [ $n -le 32 ] || n=32
        sg_tmo $SG_CHUNK_TMO $pri dd if=/dev/zero of="$SYSTEM_IMG" bs=1048576 seek=$cur count=$n conv=notrunc 2>/dev/null || return 1
        sync
        nw=$(st_img_mb); [ "$nw" -gt "$cur" ] || return 1
        cur=$nw
        [ -n "$SG_SPLASH" ] && type splash >/dev/null 2>&1 && splash "$SG_SPLASH $(( (cur - SG_FROM) * 100 / (SG_TO - SG_FROM) ))%" 36
    done
    [ "$(st_img_mb)" = "$1" ]
}

# 算要不要扩、扩到多少：目标 MB 放进 SG_PLAN（空 = 不扩），原因放进 SG_WHY。先 st_calc。别在 $(...) 里调（变量会丢）。
sg_plan() {
    SG_WHY=; SG_PLAN=
    want=
    [ "$ST_IMG" -lt "$SG_TARGET" ] && want=$SG_TARGET
    if [ "$ST_FS_FREE" -lt "$SG_LOW" ]; then
        w=$((ST_IMG + SG_STEP)); [ "$w" -ge "$SG_TARGET" ] || w=$SG_TARGET
        want=$w
    fi
    [ -n "$want" ] || { SG_WHY=enough; return 0; }
    keep=$((ST_KTOTAL * SG_KEEP_PCT / 100)); [ "$keep" -ge "$SG_KEEP_MIN" ] || keep=$SG_KEEP_MIN
    SG_KEEP=$keep
    cap=$((ST_ALLOC + ST_KFREE - keep))
    st_isfat && [ "$cap" -gt "$ST_FATCAP" ] && cap=$ST_FATCAP
    [ "$cap" -le "$ST_HARDMAX" ] || cap=$ST_HARDMAX
    to=$want; [ "$to" -le "$cap" ] || to=$cap
    to=$((to / 64 * 64))
    if [ $((to - ST_IMG)) -lt $SG_MIN_GAIN ]; then SG_WHY=nospace; return 0; fi
    SG_PLAN=$to
}

# 启动时（镜像没挂、没有 loop 指着它、没有别的调整在做）
sg_start_grow() {
    [ -f "$SYSTEM_IMG" ] || return 0
    st_mounted && return 0
    [ -z "$(img_loops)" ] || return 0
    [ -f $ST_STATE ] && return 0
    sg_conf
    [ "$SYSGROW" = 0 ] && return 0
    [ "$(cat $SG_AUTO 2>/dev/null)" = 0 ] && return 0
    st_calc
    sg_plan; to=$SG_PLAN
    if [ -z "$to" ]; then
        # 需要但扩不动：同样的数字只记一次（每次启动都写一行没有意义）
        if [ "$SG_WHY" = nospace ]; then
            k="$ST_IMG $ST_FS_FREE $ST_KFREE"
            [ "$(cat $SG_SKIP 2>/dev/null)" = "$k" ] || {
                echo "$k" > $SG_SKIP 2>/dev/null
                st_log "sysgrow: image $ST_IMG MB ($ST_FS_FREE MB free) wants to grow, but kindle has only $ST_KFREE MB free (keep $SG_KEEP MB): not growing"
            }
        fi
        return 0
    fi
    st_tool resize2fs >/dev/null && st_tool e2fsck >/dev/null || { st_log "sysgrow: no resize2fs / e2fsck: not growing $ST_IMG -> $to MB"; return 0; }
    st_battery_ok || { st_log "sysgrow: battery low, not growing $ST_IMG -> $to MB now"; return 0; }
    # 安装器不认 resize.lock：扩容期间拿着安装锁（同样的格式），这时开始的安装 / 自动更新会说“另一个安装正在进行”并退出，
    # 不会去挂一个正在加长 / resize2fs 的镜像。安装器正拿着锁就不扩（下次启动再说）。
    sg_ilock || { st_log "sysgrow: an installer is running, not growing now"; return 0; }
    if ! st_lock; then sg_iunlock; return 0; fi
    sg_grow_now "$to"
    st_unlock; sg_iunlock
    return 0
}
sg_grow_now() {
    to=$1
    SG_FROM=$ST_IMG; SG_TO=$to; from=$ST_IMG
    rm -f $SG_SKIP
    st_log "sysgrow: growing $from -> $to MB (fs free $ST_FS_FREE MB, used $ST_FS_USED MB, kindle free $ST_KFREE MB, keep $SG_KEEP MB)"
    SG_SPLASH="VeraDroid：正在扩大存储空间（$from → $to MB），请勿关机…"
    type splash >/dev/null 2>&1 && splash "$SG_SPLASH" 36
    st_state grow "$from" "$to" check
    if ! sg_fsck; then
        rm -f $ST_STATE
        st_last failed grow "$from" "$to" fsck; return 0
    fi
    st_state grow "$from" "$to" extend
    if ! sg_extend "$to"; then
        st_log "sysgrow: extending the file failed at $(st_img_mb) MB: back to $from MB"
        st_cut "$from"; sync
        rm -f $ST_STATE
        st_last failed grow "$from" "$to" extend; return 0
    fi
    sync
    st_state grow "$from" "$to" resize
    type splash >/dev/null 2>&1 && splash "VeraDroid：正在扩大存储空间（$from → $to MB）：整理文件系统，请勿关机…" 36
    r=$(st_tool resize2fs)
    sg_tmo $SG_RESIZE_TMO "$r" "$SYSTEM_IMG" >> $ST_LOG 2>&1; rc=$?
    echo "-- $(date '+%F %T') sysgrow resize2fs rc=$rc" >> $ST_LOG
    if [ $rc -ne 0 ]; then
        # 被超时杀掉或失败：先修文件系统；还是原来的大小就把文件截回去，否则留着“进行中”标记，下次启动补完
        sg_fsck
        fk=$(st_fs_kb)
        if [ -n "$fk" ] && [ "$fk" -le $((from * 1024)) ]; then
            st_cut "$from"; sync; rm -f $ST_STATE
            st_last failed grow "$from" "$to" resize2fs
        else
            st_log "sysgrow: resize2fs rc=$rc, filesystem now $((${fk:-0} / 1024)) MB: leaving the marker, the next start finishes it"
        fi
        return 0
    fi
    sync
    type splash >/dev/null 2>&1 && splash "VeraDroid：正在扩大存储空间：再次检查，请勿关机…" 36
    sg_fsck || { st_log "sysgrow: e2fsck after the resize failed (marker kept)"; return 0; }
    sync; rm -f $ST_STATE
    st_last ok grow "$from" "$to" sysgrow
    st_notify "grown $from $to"
    return 0
}

# 安装锁（cloud/static/bootstrap-legacy.sh 的格式：目录 + pid + boot + phase；只认本次开机里还活着的持有者）
SG_ILOCK=/mnt/base-us/veradroid/state/install.lock
sg_boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo noboot; }
sg_ilock_live() {
    lp=$(cat $SG_ILOCK/pid 2>/dev/null); lb=$(cat $SG_ILOCK/boot 2>/dev/null)
    [ -n "$lp" ] && [ "$lb" = "$(sg_boot_id)" ] && kill -0 "$lp" 2>/dev/null
}
sg_ilock() {
    if ! mkdir $SG_ILOCK 2>/dev/null; then
        sg_ilock_live && return 1
        rm -f $SG_ILOCK/pid $SG_ILOCK/boot $SG_ILOCK/phase; rmdir $SG_ILOCK 2>/dev/null
        mkdir $SG_ILOCK 2>/dev/null || return 1
    fi
    echo $$ > $SG_ILOCK/pid; sg_boot_id > $SG_ILOCK/boot; echo sysgrow > $SG_ILOCK/phase
}
sg_iunlock() {
    [ "$(cat $SG_ILOCK/pid 2>/dev/null)" = "$$" ] && [ "$(cat $SG_ILOCK/phase 2>/dev/null)" = sysgrow ] || return 0
    rm -f $SG_ILOCK/pid $SG_ILOCK/boot $SG_ILOCK/phase; rmdir $SG_ILOCK 2>/dev/null; return 0
}

# 安装 / 更新完以后系统盘常常还挂着（Android 没在跑）：storage_mount 看到挂着就直接返回，扩容要等到再下一次启动。
# 启动时（veradroid.sh，还没开始起容器）如果这时该扩，而且确定没人在用它，就先卸下来，让后面的 st_recover → sg_start_grow 去扩。
# 只用不带 -l 的 umount：还有人开着里面的文件就会失败，那就照旧挂着启动（不扩）。common.sh 的 storage_mount 开头调。
sg_premount() {
    [ -n "$ST_START" ] && [ -z "$ST_OWNER" ] && [ -f "$SYSTEM_IMG" ] && st_mounted || return 0
    [ -d $W/starting ] && return 0                                  # 已经在启动（--in-chroot 那一次也走这里）
    P=$(cat $W/pid 2>/dev/null); [ -n "$P" ] && kill -0 "$P" 2>/dev/null && return 0   # Android 在跑
    sg_ilock_live && return 0                                       # 安装器在跑
    [ -f /mnt/base-us/veradroid-install.lock/pid ] && kill -0 "$(cat /mnt/base-us/veradroid-install.lock/pid 2>/dev/null)" 2>/dev/null && return 0   # root-legacy
    [ -d $ST_LOCK ] && return 0
    [ -n "$(awk -v d="$SYS" 'index($2, d "/") == 1' /proc/mounts)" ] && return 0   # 里面还挂着东西：容器的残留，不碰
    sg_conf
    [ "$SYSGROW" = 0 ] && return 0
    [ "$(cat $SG_AUTO 2>/dev/null)" = 0 ] && return 0
    st_calc; sg_plan
    [ -n "$SG_PLAN" ] || return 0
    sync
    if umount "$SYS" 2>/dev/null; then
        for l in $(img_loops); do losetup -d "$(loop_dev $l)" 2>/dev/null; done
        st_log "sysgrow: image was still mounted (installer / update left it), unmounted to grow $ST_IMG -> $SG_PLAN MB"
    else
        st_log "sysgrow: image busy, not growing on this start"
    fi
    return 0
}

# 看门狗每周期调（storage.sh 的 st_auto_tick）：系统盘快没地方了就记一次日志（恢复到 SG_HINT + 50 以上再重新计）
sg_low_tick() {
    [ -f "$SYSTEM_IMG" ] || return 0
    f=$(df -kP "$SYS" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1024 }')
    st_num "$f" || return 0
    if [ "$f" -lt $SG_HINT ]; then
        [ -f $W/sg.low ] && return 0
        touch $W/sg.low
        st_log "low: system disk has only $f MB free (image $(st_img_mb) MB, kindle free $(df -kP /mnt/base-us 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1024 }') MB): apps may fail to compile; clear app caches, uninstall apps or free kindle space (the next start grows the image)"
    elif [ "$f" -ge $((SG_HINT + 50)) ]; then
        rm -f $W/sg.low
    fi
    return 0
}
