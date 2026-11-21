package com.veradroid.home;

import android.app.Activity;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * 整机系统更新（宿主的 bootstrap，不是 VeraHome 自己的 APK 更新 {@link Update}）：
 * “检查系统更新”先问服务器最新版本，有新版本就把这之间每一版的更新内容列出来，用户自己选“更新”或“以后再说”，
 * 选了更新才让宿主开始（cmd fullupdate）。以前一点就直接开始下载、退出 Android。
 *
 * 线路按内核分（和宿主 auto-update.sh 一样）：5.x = PW6 包（/api/bootstrap），4.9 = 其他机型（bootstrap-k49.json），
 * 3.x / 4.1 = 老机型（bootstrap-legacy.json）；装的是按类别编的系统（$VD/image-class）时先看那个类别的版本。
 * 更新内容来自 /api/changelog?line=…&since=当前版本（服务器上的 changelog.json）；接口还没有时只显示版本号。
 *
 * 设置里“自动更新：自动安装 / 只提醒 / 关闭”存在宿主的 $VD/autoupdate（1 / notify / 0）。只提醒时宿主发现新版本
 * 只写 $VD/update.available，桌面回到前台时（{@link #maybeNotify}）弹出同一个对话框，每个版本只弹一次。
 * 容器里看不到 $VD：版本、类别、自动更新方式、发现的新版本都从宿主状态 ctl/status 读（status.sh 的 sysversion 等）。
 */
final class SysUpdate {
    /** 测试时可以让它问别的服务器（root 才能设：setprop debug.vd.updatebase http://测试服务器:端口），平时就是官网。 */
    private static String base() {
        try {
            String b = (String) Class.forName("android.os.SystemProperties").getMethod("get", String.class, String.class).invoke(null, "debug.vd.updatebase", "");
            if (b != null && b.matches("https?://[A-Za-z0-9.:-]+")) return b;
        } catch (Throwable ignored) { }
        return "https://veradroid.wenjin.jp";
    }
    private static final String VD = "/mnt/base-us/veradroid";
    static final String[] MODE_L = { "自动安装", "只提醒", "关闭" };
    static final String[] MODE_V = { "1", "notify", "0" };
    private static volatile boolean busy;

    private SysUpdate() { }

    static String readLine(String path) {
        try {
            File f = new File(path);
            if (!f.isFile()) return null;
            BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(f), "UTF-8"));
            try { String s = r.readLine(); return s == null ? null : s.trim(); } finally { r.close(); }
        } catch (Throwable t) { return null; }
    }

    /** 宿主写的状态（ctl/status）：容器里看不到 $VD，系统版本、自动更新方式都从这里来。 */
    private static String st(String key) {
        String v = HostLink.kv(HostLink.CTL + "status").get(key);
        return v == null ? "" : v.trim();
    }

    /** 现在装的系统版本（宿主状态里的 sysversion = $VD/version）；老宿主没有这一项时返回 null。 */
    static String current() {
        String v = st("sysversion");
        return v.matches("[0-9]+(\\.[0-9]+){0,3}") ? v : null;
    }

    /** pw6 / k49 / legacy：按内核版本，和宿主 auto-update.sh 的判断一样。 */
    static String line() {
        String k = System.getProperty("os.version", "");
        if (k.startsWith("3.") || k.startsWith("4.1.")) return "legacy";
        if (k.startsWith("4.")) return "k49";
        return "pw6";
    }

    private static String metaUrl(String line) {
        long t = System.currentTimeMillis() / 1000;
        if ("legacy".equals(line)) return base() + "/static/bootstrap-legacy.json?t=" + t;
        if ("k49".equals(line)) return base() + "/static/bootstrap-k49.json?t=" + t;
        return base() + "/api/bootstrap";
    }

    /** 点分版本号：a 比 b 新。 */
    static boolean newer(String a, String b) {
        String[] x = a.split("\\."), y = b.split("\\.");
        for (int i = 0; i < Math.max(x.length, y.length); i++) {
            int p = 0, q = 0;
            try { p = i < x.length ? Integer.parseInt(x[i]) : 0; } catch (NumberFormatException ignored) { }
            try { q = i < y.length ? Integer.parseInt(y[i]) : 0; } catch (NumberFormatException ignored) { }
            if (p != q) return p > q;
        }
        return false;
    }

    private static String get(String url) throws Exception {
        HttpURLConnection h = (HttpURLConnection) new URL(url).openConnection();
        h.setConnectTimeout(15000); h.setReadTimeout(20000);
        h.setRequestProperty("User-Agent", "VeraDroid/SysUpdate");
        try {
            if (h.getResponseCode() >= 400) return null;
            InputStream in = h.getInputStream();
            java.io.ByteArrayOutputStream bo = new java.io.ByteArrayOutputStream();
            byte[] b = new byte[8192]; int n;
            while ((n = in.read(b)) > 0 && bo.size() < 512 * 1024) bo.write(b, 0, n);
            in.close();
            return bo.toString("UTF-8");
        } finally { h.disconnect(); }
    }

    static final class Info {
        String current, latest, line, error;
        List<JSONObject> entries;   // null = 服务器还没有 /api/changelog 或读不到
    }

    /** 后台线程：最新版本 + 两版之间的更新内容。 */
    static Info fetch() {
        Info i = new Info();
        i.current = current();
        i.line = line();
        try {
            String json = null;
            String ic = st("imageclass");
            if (ic.matches("[A-Za-z0-9_-]{1,32}")) json = get(base() + "/static/bootstrap-" + ic + ".json?t=" + System.currentTimeMillis() / 1000);
            if (json == null) json = get(metaUrl(i.line));
            if (json == null) { i.error = "连不上更新服务器"; return i; }
            i.latest = new JSONObject(json).optString("version", "");
            if (i.latest.length() == 0) { i.error = "服务器没有给出版本号"; return i; }
            if (i.current != null && !newer(i.latest, i.current)) return i;
            if (i.current == null) return i;   // 老宿主不报版本：只能给出最新版本号
            try {
                String cl = get(base() + "/api/changelog?line=" + i.line + "&since=" + java.net.URLEncoder.encode(i.current, "UTF-8"));
                if (cl != null) {
                    JSONArray a = new JSONObject(cl).optJSONArray("entries");
                    if (a != null) {
                        i.entries = new ArrayList<JSONObject>();
                        for (int k = 0; k < a.length(); k++) {
                            JSONObject e = a.optJSONObject(k);
                            if (e != null && !newer(e.optString("version", "0"), i.latest)) i.entries.add(e);
                        }
                    }
                }
            } catch (Throwable ignored) { }
        } catch (Throwable t) { i.error = "检查失败，请检查网络"; }
        return i;
    }

    /** “检查系统更新”：查完再弹对话框（有新版本：更新内容 + 更新 / 以后再说；没有：说一声）。 */
    static void check(final Activity a) {
        if (busy) { VeraToast.show(a, "正在检查更新…"); return; }
        if (running()) { progress(a, null); return; }   // 已经在更新：不再查一遍、不再开第二个安装器，直接看进度
        busy = true;
        VeraToast.show(a, "正在检查系统更新…");
        new Thread(new Runnable() { @Override public void run() {
            final Info i = fetch();
            busy = false;
            new Handler(Looper.getMainLooper()).post(new Runnable() { @Override public void run() {
                if (a.isFinishing()) return;
                if (i.error != null) { VeraToast.show(a, i.error); return; }
                if (i.current != null && !newer(i.latest, i.current)) {
                    new VeraDialog.Builder(a).title("已是最新版本").message("现在装的是 " + i.current + "，服务器上最新的也是 " + i.latest + "。").positive("好", null).show();
                    return;
                }
                show(a, i);
            } });
        } }, "sysupdate-check").start();
    }

    /** 自动更新选了“只提醒”、宿主发现了新版本：回到桌面时弹一次（同一个版本点过“以后再说”就不再弹）。 */
    static void maybeNotify(final Activity a) {
        final String v = st("update_available"), cur = current();
        if (v.length() == 0 || cur == null || busy || !newer(v, cur) || !"notify".equals(st("autoupdate"))) return;
        final SharedPreferences p = Store.prefs(a, "home");
        if (v.equals(p.getString("sysupdate_later", ""))) return;
        busy = true;
        new Thread(new Runnable() { @Override public void run() {
            final Info i = fetch();
            busy = false;
            new Handler(Looper.getMainLooper()).post(new Runnable() { @Override public void run() {
                if (a.isFinishing() || i.error != null || i.latest == null || i.current == null || !newer(i.latest, i.current)) return;
                if (i.latest.equals(p.getString("sysupdate_later", ""))) return;
                show(a, i);
            } });
        } }, "sysupdate-notify").start();
    }

    private static void show(final Activity a, final Info i) {
        LinearLayout box = new LinearLayout(a);
        box.setOrientation(LinearLayout.VERTICAL);
        if (i.entries == null || i.entries.isEmpty()) {
            box.addView(text(a, "更新内容暂时拿不到，可以在官网的“更新日志”页看。", 16, false, 0));
        } else {
            for (JSONObject e : i.entries) {
                String title = e.optString("title", "");
                int colon = title.indexOf('：');
                String head = e.optString("version", "") + "  ·  " + e.optString("date", "");
                box.addView(text(a, head, 17, true, 10));
                if (colon > 0 && colon + 1 < title.length()) box.addView(text(a, title.substring(colon + 1), 16, true, 2));
                JSONArray items = e.optJSONArray("items");
                if (items != null) for (int k = 0; k < items.length(); k++) box.addView(text(a, "· " + items.optString(k), 15, false, 4));
            }
        }
        box.addView(text(a, "更新时会短暂退出 Android；数据、书架、绑定账号都保留。有增量补丁时只下载变了的部分。", 13, false, 14));
        // 更新前备份关着（设置 → 设备与更新 → 更新前备份）：更新前说清楚
        if (BackupActivity.off()) box.addView(text(a, "更新前备份已关闭：这次不备份，更新出问题时无法恢复。可以在 设置 → 设备与更新 → 更新前备份 里打开。", 15, true, 10));
        // 更新内容放在固定高度的一块里一页一页翻（划动或点“上一页 / 下一页”），“更新 / 以后再说”一直在下面看得见
        LinearLayout wrap = new LinearLayout(a);
        wrap.setOrientation(LinearLayout.VERTICAL);
        final PageScrollView sv = new PageScrollView(a);
        sv.addView(box);
        int h = (int) (a.getResources().getDisplayMetrics().heightPixels * 0.5f);
        wrap.addView(sv, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, h));
        LinearLayout nav = new LinearLayout(a);
        nav.setGravity(android.view.Gravity.CENTER_VERTICAL);
        final TextView pg = Ui.text(a, "", 14, false);
        pg.setGravity(android.view.Gravity.CENTER);
        final Runnable label = new Runnable() { @Override public void run() {
            int n = sv.pages();
            pg.setText(n > 1 ? sv.currentPage() + " / " + n + " 页" : "");
        } };
        nav.addView(Ui.button(a, "上一页", 15, false, new View.OnClickListener() { @Override public void onClick(View v) { if (sv.page(-1)) sv.firePage(); } }));
        nav.addView(pg, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        nav.addView(Ui.button(a, "下一页", 15, false, new View.OnClickListener() { @Override public void onClick(View v) { if (sv.page(1)) sv.firePage(); } }));
        wrap.addView(nav);
        sv.setOnPage(label);
        sv.getViewTreeObserver().addOnGlobalLayoutListener(new android.view.ViewTreeObserver.OnGlobalLayoutListener() {
            @Override public void onGlobalLayout() { label.run(); }
        });
        new VeraDialog.Builder(a)
            .title("新版本 " + i.latest)
            .message((i.current == null ? "这次更新的内容：" : "现在是 " + i.current + "。这次更新的内容：") + (BackupActivity.off() ? "\n（更新前备份已关闭，更新出问题时无法恢复）" : ""))
            .view(wrap)
            .negative("以后再说", new Runnable() { @Override public void run() {
                Store.prefs(a, "home").edit().putString("sysupdate_later", i.latest).apply();
            } })
            .positive("更新", new Runnable() { @Override public void run() {
                HostLink.cmd("fullupdate");
                progress(a, i.latest);
            } }).show();
    }

    /** 系统更新正在进行（宿主的 ctl/update.status 一小时内有进展）。 */
    static boolean running() {
        Map<String, String> m = TaskCards.read(TaskCards.UPDATE);
        return TaskCards.active(m.get("state")) && TaskCards.now() - TaskCards.num(m, "time", 0) < 3600;
    }

    /**
     * 点了“更新”以后马上给看得见的进度（用户诊断，KT6：以前只弹一句“几秒后会退出”，可安装器要先在后台
     * 下载、核对，慢网下二三十分钟 Android 都不退出，看上去就是“点了更新一直没反应”，有人就去重装了）。
     * 对话框里放的就是“设备与关于”页那张进度卡片（跟着 ctl/update.status 走，出错时写明代码和原因）。
     */
    static void progress(final Activity a, String latest) {
        if (a.isFinishing()) return;
        LinearLayout box = new LinearLayout(a);
        box.setOrientation(LinearLayout.VERTICAL);
        box.addView(text(a, (latest == null ? "系统更新" : "更新到 " + latest) + "：先在后台下载和核对（网速慢时要十几分钟，这期间可以照常用），"
            + "都好了才退出 Android 安装，装完自动回来。关掉这个窗口不影响更新，进度也可以在 设置 → 设备与关于 里看。", 15, false, 0));
        box.addView(new TaskCards.Update(a, false), new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));
        new VeraDialog.Builder(a).title("正在更新").view(box).positive("在后台继续", null).show();
    }

    private static TextView text(Activity a, String s, float sp, boolean bold, int topDp) {
        TextView t = Ui.text(a, s, sp, bold);
        t.setTextColor(Color.BLACK);
        t.setPadding(0, Ui.dp(a, topDp), 0, 0);
        return t;
    }

    // ------------------------------------------------------------------ 设置：自动更新（宿主的 $VD/autoupdate）

    /** 现在的自动更新方式（MODE_V 里的下标）；读不到按“自动安装”（宿主默认）。 */
    static int mode() {
        String v = st("autoupdate");
        if ("0".equals(v)) return 2;
        if ("notify".equals(v)) return 1;
        return 0;
    }

    /** 选自动更新方式：交给宿主（管理请求 autoupdate，只认 VeraHome 自己的请求）。done 在主线程跑，参数是结果说明。 */
    static void setMode(final Activity a, final int idx, final View.OnClickListener done) {
        new Thread(new Runnable() { @Override public void run() {
            byte[] r = HostReq.run(a, "autoupdate", MODE_V[idx], null, 15000);
            final boolean ok = r != null && new String(r).contains("ok=1");
            new Handler(Looper.getMainLooper()).post(new Runnable() { @Override public void run() {
                VeraToast.show(a, ok ? "自动更新：" + MODE_L[idx] : "没能改自动更新设置（宿主没有回应）");
                HostLink.cmd("status");
                if (done != null) { new Handler(Looper.getMainLooper()).postDelayed(new Runnable() { @Override public void run() { done.onClick(null); } }, 1200); return; }
                if (done != null) done.onClick(null);
            } });
        } }, "sysupdate-mode").start();
    }
}
