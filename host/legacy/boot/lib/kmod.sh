# SPDX-License-Identifier: GPL-3.0-or-later
# 外挂内核模块：3.0.35（PW2 / PW3 …）和 4.1.15（PW4 / 入门款 2019 / Oasis 2 / Oasis 3）的内核没有 binder（4.1 还没有 tun、uinput；
# 3.0 没有 zram）。
# 整包里按内核版本放预编的模块：
#   $VD/kmod/<uname -r>/{binder,zram}.ko                    3.0.35：所有机型同一个内核配置（zram：Amazon 3.0.35 源码树 drivers/staging/zram，tools/kmod/build-zram.sh）
#   $VD/kmod/<uname -r>/<编号>/{binder,uinput}.ko + uname-v 4.1.15：每个机型 / 固件的内核各编一份（结构体布局按那个内核核对过），
#                                                          uname-v 是那个内核的 `uname -v`，完全一致才加载。
#                                                          uname-v 可以有多行：同一组固件（config 和全部导出 CRC 都相同、只有编译时间不同）
#                                                          共用一份模块，每行一个固件的 `uname -v`
#   $VD/kmod/extra/<uname -r>/<编号>/zram.ko                 可选模块（0.8.14 起）：4.1.15 的 5.14.1 – 5.15.1.1 固件内核没编 zram
#                                                          （5.16.2.1 起亚马逊编进内核了）。zram.ko 里带着 zsmalloc，压缩用内核自带的 LZO
#                                                          （tools/kmod/build-zram41.sh）。放在套件目录外面：套件的编号（kmod.sets）和
#                                                          kmod.id 都不变，0.8.13 及以前的自动更新照常。
#                                                          只在选中的套件就是 <编号> 时加载；加载失败只记日志，不影响启动。
# 内核换了（固件升级）而没有对应的模块时一律不加载：宁可起不来（有提示），也不把按别的内核编的模块塞进去。
# 设备节点已经存在的就不加载；模块不会卸载（下次启动直接复用）。
kmod_dir() {
    d=$VD/kmod/$(uname -r)
    [ -d "$d" ] || return 1
    if ls $d/*.ko >/dev/null 2>&1; then echo $d; return 0; fi
    v=$(uname -v)
    for s in $d/*/; do
        [ -f "${s}uname-v" ] && kmod_unamev_has "${s}uname-v" "$v" && { echo ${s%/}; return 0; }
    done
    return 1
}
# kmod_unamev_has 文件 版本串：文件里有一行和版本串完全一样（整行比较，不当正则；最后一行没有换行也算）
kmod_unamev_has() {
    while IFS= read -r kul || [ -n "$kul" ]; do [ "$kul" = "$2" ] && return 0; done < "$1"
    return 1
}
kmod_load() {
    d=$(kmod_dir) || { [ -d $VD/kmod/$(uname -r) ] && t "kmod: no modules for this kernel build ($(uname -v))"; return 0; }
    for m in tun uinput binder zram; do
        [ -f "$d/$m.ko" ] || continue
        grep -q "^$m " /proc/modules && continue
        # 内核里已经有这个设备就不加载。按 /proc/misc 判断，不看 /dev 里的节点：下面 mknod 补建的 /dev/uinput 在模块卸掉后还在，
        # 看节点的话就再也不会加载 uinput（模拟器里卸载后重启 VeraDroid 时出现过）
        case $m in
            binder) grep -qw vndbinder /proc/misc && continue ;;
            tun)    grep -qw tun /proc/misc && continue ;;
            uinput) grep -qw uinput /proc/misc && continue ;;
            zram)   [ -e /sys/block/zram0 ] && continue ;;
        esac
        a=; [ $m = zram ] && a="num_devices=1"   # legacy：Amazon 3.0.35 源码树 drivers/staging/zram 编的（tools/kmod/build-zram.sh）
        ko=$d/$m.ko
        # 3.0.35 的几代固件内核版本号一样，但 Voyage 5.13 的内核开着 CONFIG_COMPAT_BRK：task_struct 里多一个字段，
        # 后面的 pid / tgid 都错开 4 字节。按 PW3 配置编的 binder 在它上面读到的进程号全是乱的（日志里 "binder: 0:0"、
        # 事务目标是一串负数），system_server 一启动就崩、Android 永远开不了机（kv-5136 模拟器实测）。按那份配置另编一个。
        if [ $m = binder ] && [ -f "$d/binder-compatbrk.ko" ] && zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_COMPAT_BRK=y'; then
            ko=$d/binder-compatbrk.ko
        fi
        if insmod "$ko" $a 2>>$LOG; then t "kmod: loaded $m (${ko##*/})"; else t "kmod: insmod ${ko##*/} failed"; fi
    done
    # 可选模块（只有 4.1 的套件有）：ZRAM_MB=0 时不加载
    x=$VD/kmod/extra/$(uname -r)/${d##*/}
    if [ "$d" != "$VD/kmod/$(uname -r)" ] && [ -f "$x/zram.ko" ] && [ "${ZRAM_MB:-0}" -gt 0 ] 2>/dev/null \
       && ! grep -q '^zram ' /proc/modules && [ ! -e /sys/block/zram0 ]; then
        if insmod "$x/zram.ko" num_devices=1 2>>$LOG; then t "kmod: loaded zram (extra/${d##*/})"; else t "kmod: insmod extra/${d##*/}/zram.ko failed"; fi
    fi
    # 没有 devtmpfs 自动建节点时，按 /proc/misc 里的次设备号补建（misc 主设备号 10）
    for n in vndbinder:vndbinder tun:net/tun uinput:uinput; do
        name=${n%%:*}; node=/dev/${n#*:}
        [ -e $node ] && continue
        minor=$(awk -v m=$name '$2==m{print $1}' /proc/misc 2>/dev/null)
        [ -n "$minor" ] || continue
        mkdir -p "$(dirname $node)"; mknod $node c 10 $minor && t "kmod: mknod $node"
    done
    return 0
}
