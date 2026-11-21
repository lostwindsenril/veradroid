# SPDX-License-Identifier: GPL-3.0-or-later
# 休眠 / 屏保：电源键和闲置休眠仍归 Kindle 的 powerd（lab126_gui 没停）。powerd 进入 / 退出屏保时广播
# goingToScreenSaver / outOfScreenSaver：进入时让容器停止写屏（ctl/sleep），画屏保；退出时去掉标记并要求整屏重绘。
screensaver_show() {
    # 每次休眠轮换一张。用户自己放的图优先（有就只用它们）：
    #   Kindle 上的 veradroid/screensaver/（USB 可见），或 Android 里的 Screensaver 文件夹（传书网页可传）。
    # 没有用户图时用 Kindle 自带的屏保图；固件里找不到才用封面缓存 / 包里的 default.png。
    # 透明背景的 PNG 不清屏，直接叠在正在读的那一页上；JPG 和不透明 PNG 先清成白底再居中按比例铺满。
    list=$W/saver.list
    : > "$list"
    # 桌面“屏保”页的选择（saver.sh）：kindle = 跳过用户图；one = 只用那一张；rotate / 没选过 = 下面原来的做法
    smode=; sone=
    type saver_choice >/dev/null 2>&1 && saver_choice
    [ "$smode" = one ] && [ -n "$sone" ] && echo "$sone" >> "$list"
    # 用户图：两个文件夹里的 png / jpg / webp / bmp / gif ……（saver_is_img，大小写都行）；saver.sh 太旧时只认 png / jpg / jpeg
    if [ "$smode" != kindle ] && [ ! -s "$list" ]; then
        for f in "$VD"/screensaver/* "$SYS"/data/media/0/Screensaver/*; do
            [ -f "$f" ] || continue
            case "$f" in */default.png|*/default.PNG) continue ;; esac
            if type saver_is_img >/dev/null 2>&1; then saver_is_img "$f" || continue
            else case "$f" in *.[pP][nN][gG]|*.[jJ][pP][gG]|*.[jJ][pP][eE][gG]) ;; *) continue ;; esac; fi
            echo "$f" >> "$list"
        done
    fi
    if [ ! -s "$list" ]; then
        # 用户没放图：用 Kindle 自带的屏保图（和原系统休眠时看到的一样）
        # 只要 bg_ss*（成人版的那组）：同一目录里还有儿童模式的 bg_kids_ss* 和一张纯黑的 bg_kcblackbackground.png
        # （PW6 5.19.5 实测），全收进来会轮到儿童图和整屏黑。固件没有 bg_ss* 时才退到这个目录里别的图（仍跳过 kids / 黑底）。
        for f in /usr/share/blanket/screensaver/bg_ss*.png; do
            [ -f "$f" ] && echo "$f" >> "$list"
        done
        if [ ! -s "$list" ]; then
            for f in /usr/share/blanket/screensaver/*.png; do
                case "${f##*/}" in *kids*|*black*) continue ;; esac
                [ -f "$f" ] && echo "$f" >> "$list"
            done
        fi
    fi
    if [ ! -s "$list" ]; then
        # 这个固件上没找到自带屏保图：退回最近的书封面缓存，再不行用包里的 default.png
        for f in $(ls -t /mnt/us/system/thumbnails/thumbnail_* /mnt/base-us/system/thumbnails/thumbnail_* 2>/dev/null | head -10); do
            [ -f "$f" ] && echo "$f" >> "$list"
        done
        [ -f "$VD/screensaver/default.png" ] && echo "$VD/screensaver/default.png" >> "$list"
    fi
    n=$(wc -l < "$list" 2>/dev/null | tr -d ' ')
    [ "${n:-0}" -gt 0 ] || return 0
    i=$(cat "$W/saver.index" 2>/dev/null || echo 0)
    case "$i" in ''|*[!0-9]*) i=0 ;; esac
    # 轮到的这张用不了（格式不认识、坏图、fbink 画不出来）就试下一张，最多试 8 张；都不行用 Kindle 自带的
    k=0
    while [ $k -lt "$n" ] && [ $k -lt 8 ]; do
        k=$((k + 1))
        i=$(( (i % n) + 1 ))
        img=$(sed -n "${i}p" "$list")
        [ -n "$img" ] || continue
        sdraw=$img
        type saver_resolve >/dev/null 2>&1 && saver_resolve "$img"
        [ -n "$sdraw" ] || continue
        saver_draw "$sdraw" "$img" && { echo "$i" > "$W/saver.index"; return 0; }
    done
    echo "$i" > "$W/saver.index"
    for f in /usr/share/blanket/screensaver/bg_ss*.png "$VD/screensaver/default.png"; do
        [ -f "$f" ] && [ "$f" != "$img" ] || continue
        saver_draw "$f" "$f" && return 0
    done
    return 0
}
# 画一张屏保：$1 = 要画的文件（可能是桌面转好的灰度 PNG），$2 = 原图（写日志用）。画上了返回 0。
saver_draw() {
    sv_note=; [ "$1" != "$2" ] && sv_note=" (converted copy)"
    if [ -x "$FBINK" ]; then
        # PNG 文件头第 26 个字节是颜色类型：4 / 6 带透明通道
        ct=$(dd if="$1" bs=1 skip=25 count=1 2>/dev/null | od -An -tu1 2>/dev/null | tr -d ' ')
        case "$(dd if="$1" bs=1 skip=1 count=3 2>/dev/null)" in PNG) ;; *) ct= ;; esac
        if [ "$ct" = 4 ] || [ "$ct" = 6 ]; then
            "$FBINK" -q -f -i "$1" -g w=-2,h=-2,halign=CENTER,valign=CENTER >/dev/null 2>&1 && { t "screensaver: $2$sv_note (transparent, over the page)"; return 0; }
        else
            "$FBINK" -q -c -f -i "$1" -g w=-2,h=-2,halign=CENTER,valign=CENTER >/dev/null 2>&1 && { t "screensaver: $2$sv_note"; return 0; }
        fi
        t "screensaver: fbink could not draw $2$sv_note"
    fi
    # 没有带图片支持的 fbink 时退回 Kindle 自带的 eips（PW6 上只认 PNG：看文件头，不看扩展名）
    case "$(dd if="$1" bs=1 skip=1 count=3 2>/dev/null)" in
    PNG) /usr/sbin/eips -g "$1" >/dev/null 2>&1 && { t "screensaver: $2$sv_note (eips)"; return 0; } ;;
    esac
    return 1
}
sleep_watch() {
    # Do not subscribe to lipc-wait-event: on PW6/5.19 it writes its monitor
    # lines to the console even with stdout redirected, and those lines were
    # visible over VeraHome (outOfScreenSaver/goingToScreenSaver columns).
    # powerd exposes a read-only "state" property (active / screenSaver /
    # suspended), so poll it once a second. No event output can leak.
    cur=$(lipc-get-prop -s com.lab126.powerd state 2>/dev/null)
    while :; do
        st=$(lipc-get-prop -s com.lab126.powerd state 2>/dev/null)
        case "$st" in
        screenSaver|screenSaverOn|suspended|sleeping)
            if [ "$cur" != saver ]; then
                sw0=$(cut -d' ' -f1 /proc/uptime)
                touch $X/ctl/sleep
                # 设了锁屏密码：冻结前先让桌面把锁屏盖上（显示桥已被 ctl/sleep 挡住，看不到），醒来时第一帧就是锁屏
                type lock_request >/dev/null 2>&1 && lock_request
                usleep 300000
                # Freeze Android first; otherwise its last frame can overwrite
                # the screensaver image right after eips draws it.
                # 正在装 APK（afterboot.sh 写 $W/installing）时不冻结：冻在 dex2oat 中间、几小时后解冻，PackageManager
                # 线程还卡着，system_server 会被自己的 Watchdog 杀掉（用户诊断）。ctl/sleep 已经挡住显示桥；
                # 机器真睡下去（suspended）时整个系统一起停，uptime 也停，不会触发 Watchdog。
                # 先画屏保，再冻结（用户报告 PW4 0.8.8：按电源键“要等 1 分钟左右才有反应”）。以前是先冻结：android_freeze 里的 sync
                # 在真机上要把 vfat 上镜像文件的脏页写完（刚装完应用 / 在编译 / 在换页时可以是几十秒），逐个进程发 SIGSTOP 也要
                # 扫一遍 /proc，这段时间屏幕一直停在原来的画面上。显示桥已经被 ctl/sleep 挡住（上面等的 0.3 秒让在途的那一帧
                # 落完），Android 的帧盖不到屏保上。
                screensaver_show; sv=1
                t "screensaver: drawn $(awk -v a=$sw0 -v b=$(cut -d' ' -f1 /proc/uptime) 'BEGIN{printf "%.1f", b-a}') s after powerd went to $st"
                if alive $W/installing; then
                    touch $W/saver_nofreeze; t "screensaver: an apk is being installed, android left running"
                else
                    # KINDLE_UI=freeze：每分钟整点的 TIME_TICK 刚发出时别冻（应用在换页时处理得慢，冻在半路醒来就超时）：
                    # 显示桥已经挡住，先画屏保，等到这一分钟的第 12 秒再冻
                    if [ "$(kindle_ui_mode 2>/dev/null)" = freeze ]; then
                        sec=$(date +%S); sec=${sec#0}
                        [ "${sec:-0}" -lt 12 ] && sleep $((12 - sec))
                    fi
                    android_freeze && touch $W/saver_frozen
                fi
                type wifi_ps_restore >/dev/null 2>&1 && wifi_ps_restore
                [ "${sv:-0}" = 1 ] || screensaver_show
                cur=saver
                date +%s > $W/saver.t0      # 醒来时看冻了多久（SAVER_EXIT_H，freeze.sh saver_exit_check）
                t "screensaver on, android frozen ($(awk -v a=$sw0 -v b=$(cut -d' ' -f1 /proc/uptime) 'BEGIN{printf "%.1f", b-a}') s after powerd went to $st)"
                type tset >/dev/null 2>&1 && [ -f $W/saver_frozen ] && tset sleep.ok "$(date +%H:%M:%S)"
            fi ;;
        active|charging)
            if [ "$cur" = saver ]; then
                type saver_exit_check >/dev/null 2>&1 && saver_exit_check
                if [ -f $W/saver_nofreeze ]; then rm -f $W/saver_nofreeze
                elif [ "$(kindle_ui_mode 2>/dev/null)" = freeze ]; then android_thaw_staged ${THAW_SS_DELAY:-3} 2>/dev/null
                else android_thaw 2>/dev/null; fi
                type lock_reset_check >/dev/null 2>&1 && { lock_reset_check; lock_request; }
                ( usleep 500000; trust_unlock ) &
                rm -f $W/saver_frozen
                rm -f $X/ctl/sleep
                epd_send REDRAW
                t "screensaver off, android thawed"
                type tset >/dev/null 2>&1 && [ -n "$(tget sleep.ok)" ] && { tset wake.ok "$(date +%H:%M:%S)"; test_report; }
            fi
            cur=active ;;
        esac
        # 以前每秒 lipc-get-prop 一次（每次一条新的 lipc / dbus 连接，powerd 还往 syslog 记警告）。现在等 powerd 的进 / 出屏保事件，
        # 最多 5 秒再看一次状态（事件恰好落在两次之间也最多晚 5 秒）；lipc-wait-event 用不了时退回每秒一次（host/pw6 fix/power 91b61ad 的简化版）
        lipc-wait-event -s 5 com.lab126.powerd goingToScreenSaver,outOfScreenSaver </dev/null >/dev/null 2>&1 || sleep 1
    done
}
