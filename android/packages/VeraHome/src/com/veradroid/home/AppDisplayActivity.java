// SPDX-License-Identifier: GPL-3.0-or-later
package com.veradroid.home;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/**
 * 应用优化（长按应用 → 刷新方式、全刷间隔、对比度、字号、后台保活）：每个应用单独一套设置，“跟随”= 用全局的。
 *
 * 选项是一张表（{@link Knob}）：键、标题、可选值。宿主可以在 /dev/kfb/appknobs 里加选项或换掉内置的（同一个键），
 * 桌面不用改就能显示新的宿主设置。一行一个：
 * <pre>KEY|标题|标签=值,标签=值…</pre>
 * “跟随”自动加在最前面；“#”开头的行不看。保存时只改这页上有的键，profile 里这页不认识的键原样留着。
 * 保持后台不是显示设置，存在桌面自己的偏好里（Cleaner.keepAlive），这一页只是多一个入口；
 * 宿主要是在 appknobs 里声明了 KEEPALIVE 这个键，就交给宿主（存进 profile），不再用桌面的偏好。
 */
public class AppDisplayActivity extends Activity {
    static final String KNOBS = HostLink.KFB + "appknobs";
    static final String KEEP_KEY = "KEEPALIVE";
    /** 只对某些应用的选项（宿主的后台瘦身 appslim.sh 等）：一行 "<包名> KEY|标题|标签=值,…"。 */
    static final String KNOBS_PKG = HostLink.KFB + "appknobs.pkg";

    /** appknobs.pkg 里属于这个包的选项行（去掉包名）。 */
    static List<String> pkgLines(List<String> lines, String pkg) {
        List<String> out = new ArrayList<String>();
        if (pkg == null || pkg.length() == 0) return out;
        for (String l : lines) if (l != null && l.startsWith(pkg + " ")) out.add(l.substring(pkg.length() + 1));
        return out;
    }

    /** 一个选项：labels[0] / values[0] 是“跟随”（值 null = 这个键不写）。 */
    static final class Knob {
        final String key, title;
        final String[] labels, values;
        Seg seg;
        Knob(String key, String title, String[] labels, String[] values) { this.key = key; this.title = title; this.labels = labels; this.values = values; }

        int index(String v) {
            if (v == null) return 0;
            for (int i = 1; i < values.length; i++) if (values[i].equals(v)) return i;
            return 0;
        }

        /** "KEY|标题|标签=值,标签=值"；格式不对返回 null。 */
        static Knob parse(String line) {
            if (line == null) return null;
            line = line.trim();
            if (line.length() == 0 || line.startsWith("#")) return null;
            String[] a = line.split("\\|", 3);
            if (a.length < 3 || !a[0].trim().matches("[A-Z][A-Z0-9_]{0,31}") || a[1].trim().length() == 0) return null;
            List<String> l = new ArrayList<String>(), v = new ArrayList<String>();
            l.add("跟随"); v.add(null);
            for (String o : a[2].split(",")) {
                int eq = o.lastIndexOf('=');
                if (eq <= 0 || eq == o.length() - 1) continue;
                String val = o.substring(eq + 1).trim();
                if (!val.matches("[0-9A-Za-z._-]{1,16}")) continue;
                l.add(o.substring(0, eq).trim()); v.add(val);
            }
            if (l.size() < 2) return null;
            return new Knob(a[0].trim(), a[1].trim(), l.toArray(new String[0]), v.toArray(new String[0]));
        }
    }

    static String[] withFollow(String... a) { String[] r = new String[a.length + 1]; r[0] = "跟随"; System.arraycopy(a, 0, r, 1, a.length); return r; }
    static String[] vals(String... a) { String[] r = new String[a.length + 1]; System.arraycopy(a, 0, r, 1, a.length); return r; }

    /** 内置的选项（宿主一直认得的 KFB_* 键）。hasScroll：老机型的显示桥没有快速滑动 / 图片灰度。 */
    static List<Knob> builtinKnobs(boolean hasScroll) {
        List<Knob> k = new ArrayList<Knob>();
        k.add(new Knob("KFB_MODE", "刷新方式", withFollow("均衡", "灰度最准", "最快"), vals("0", "1", "2")));
        k.add(new Knob("KFB_FLASH", "每几页全刷", withFollow("每页", "3", "6", "10"), vals("1", "3", "6", "10")));
        if (hasScroll) {
            k.add(new Knob("KFB_SCROLLDU", "快速滑动（滚动时先黑白快刷，停下再补灰度）", withFollow("开", "关"), vals("300", "0")));
            k.add(new Knob("KFB_IMG", "图片灰度（漫画 / 图片用 16 级灰，不用黑白点阵）", withFollow("开", "关"), vals("25", "0")));
        }
        k.add(new Knob("KFB_CONTRAST", "对比度", withFollow("1.0", "1.3", "1.5", "2.0", "2.5"), vals("1.0", "1.3", "1.5", "2.0", "2.5")));
        k.add(new Knob("KFB_LIGHTF", "浅色过滤（浅灰 / 米色底变纯白，闪刷少）", withFollow("关", "弱", "中", "强"), vals("0", "1", "2", "3")));
        k.add(new Knob("KFB_DARKEN", "深色加深（浅灰字变黑）", withFollow("关", "开"), vals("0", "1")));
        k.add(new Knob("KFB_ANIM_MODE", "翻页动画", withFollow("开", "关"), vals("1", "0")));
        return k;
    }

    /** 内置的 + 宿主声明的（同一个键宿主的盖住内置的，新键排在后面）。 */
    static List<Knob> knobs(boolean hasScroll, List<String> hostLines) {
        List<Knob> k = builtinKnobs(hasScroll);
        if (hostLines != null) for (String line : hostLines) {
            Knob h = Knob.parse(line);
            if (h == null) continue;
            int at = -1;
            for (int i = 0; i < k.size(); i++) if (k.get(i).key.equals(h.key)) at = i;
            if (at >= 0) k.set(at, h); else k.add(h);
        }
        return k;
    }

    /** 把这一页选的值写回 spec：这一页上有的键按选择写（“跟随”= 去掉），这一页不认识的键原样留着。 */
    static String merge(String oldSpec, List<Knob> ks, int[] picked) {
        java.util.Map<String, String> m = AppProf.parse(oldSpec);
        for (int i = 0; i < ks.size(); i++) {
            Knob k = ks.get(i);
            int p = picked[i];
            if (p <= 0 || p >= k.values.length || k.values[p] == null) m.remove(k.key); else m.put(k.key, k.values[p]);
        }
        StringBuilder sb = new StringBuilder();
        for (java.util.Map.Entry<String, String> e : m.entrySet()) {
            if (sb.length() > 0) sb.append(';');
            sb.append(e.getKey()).append('=').append(e.getValue());
        }
        return sb.toString();
    }

    static List<String> readLines(String path) {
        List<String> out = new ArrayList<String>();
        try {
            java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(path));
            try { String l; while ((l = r.readLine()) != null && out.size() < 64) out.add(l); } finally { r.close(); }
        } catch (Exception ignored) { }
        return out;
    }

    private String pkg, label;
    private Seg font, keep;
    private List<Knob> knobs;
    private boolean newHost, hasScroll, hostKeep;
    private java.util.Map<String, String[]> table;
    private TextView status;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        pkg = getIntent().getStringExtra("pkg");
        label = getIntent().getStringExtra("label");
        if (pkg == null) pkg = "";
        if (label == null || label.length() == 0) label = pkg;
        Window w = getWindow();
        w.setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(Color.WHITE));
        w.setWindowAnimations(0);
        w.clearFlags(android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.WHITE);
        root.setPadding(dp(18), dp(12), dp(18), dp(16));
        LinearLayout hd = new LinearLayout(this);
        hd.setOrientation(LinearLayout.HORIZONTAL); hd.setGravity(Gravity.CENTER_VERTICAL);
        hd.addView(Icons.bar(this, Icons.Kind.BACK, 28, new View.OnClickListener() {
            @Override public void onClick(View v) { finish(); }
        }));
        TextView t = Ui.text(this, label + " · 应用优化", 23, true); t.setPadding(dp(10), 0, 0, 0);
        hd.addView(t); root.addView(hd);
        View hdRule = Ui.rule(this, 2, Color.BLACK);
        root.addView(hdRule);
        Blocks.restyleTop(this, root, hd, hdRule, "Optimise / per app", label + " · 应用优化", null);
        newHost = AppProf.host();
        // 老机型（legacy）的显示桥没有快速滑动 / 图片灰度：宿主发布的设置里没有这两个键就不显示
        hasScroll = HostLink.kv(HostLink.KFB + "settings").containsKey("KFB_SCROLLDU");
        if (newHost) table = AppProf.table();
        List<String> hostLines = null;
        if (newHost) { hostLines = readLines(KNOBS); hostLines.addAll(pkgLines(readLines(KNOBS_PKG), pkg)); }
        knobs = knobs(hasScroll, hostLines);
        for (Knob k : knobs) if (KEEP_KEY.equals(k.key)) hostKeep = true;
        String src = newHost ? AppProf.lookup(table, pkg)[0] : "";
        TextView hint = Ui.text(this, (newHost
            ? (src.startsWith("u") ? "已为这个应用单独设置。" : src.equals("b") ? "现在用的是内置推荐（" + AppProf.summary(AppProf.lookup(table, pkg)[1]) + "）。" : "现在跟随全局设置。")
              + "“跟随”用全局设置；保存后马上生效，切到这个应用时自动换上。“恢复默认”回到内置推荐。"
            : "“跟随”用全局设置；改完下次打开这个应用时生效。") + "字号只在这个应用在前台时用，回到桌面恢复全局字号。", 14, false);
        hint.setTextColor(Blocks.on(this) ? Color.BLACK : Color.DKGRAY); hint.setPadding(0, dp(8), 0, dp(8)); root.addView(hint);
        // 按钮放在最上面：项目多了以后放在底下会被挤出屏幕（小屏机型更是）
        LinearLayout row = new LinearLayout(this); row.setGravity(Gravity.RIGHT);
        row.addView(Ui.button(this, newHost ? "恢复默认" : "恢复跟随", 16, false, new View.OnClickListener() {
            @Override public void onClick(View v) {
                Store.prefs(AppDisplayActivity.this, "home").edit().remove("appdisp_" + pkg).commit();
                AppFont.set(AppDisplayActivity.this, pkg, 0f);
                if (newHost) AppProf.save(pkg, ""); else HostLink.cmd("appdisp home");
                finish();
            }
        }));
        row.addView(Ui.button(this, "完成", 16, true, new View.OnClickListener() {
            @Override public void onClick(View v) { save(); finish(); }
        }));
        root.addView(row);

        for (Knob k : knobs) {
            if (!newHost && !k.key.startsWith("KFB_")) continue;   // 老宿主只认 appdisp 的 KFB_* 键
            k.seg = seg(root, k.title, k.labels);
        }
        font = seg(root, "字号（小 0.85 倍 · 标准 · 大 1.4 倍 · 特大 2 倍）", AppFont.LABELS);
        if (!hostKeep && Cleaner.userApp(this, pkg))
            keep = seg(root, "保持后台（不被自动清理和“全部关闭”关掉；切换应用里的锁是同一个开关）", new String[] { "关", "开" });

        status = Ui.text(this, "", 13, false); status.setTextColor(Blocks.on(this) ? Color.BLACK : Color.DKGRAY);
        status.setPadding(0, dp(10), 0, dp(6)); root.addView(status);

        if (Blocks.on(this)) {
            View sh = Blocks.sheet(this, root, false);
            root.setPadding(root.getPaddingLeft(), Ui.dp(this, 14), root.getPaddingRight(), root.getPaddingBottom());
            setContentView(pageScroll(sh));
        } else
        setContentView(pageScroll(root));
        // 方块风格：整屏白底（不透明的窗口下面不画，留着上下的空会是黑的），单子在上面
        w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, Blocks.on(this) ? ViewGroup.LayoutParams.MATCH_PARENT : ViewGroup.LayoutParams.WRAP_CONTENT);
        load();
    }

    /** 一屏放不下时整页翻（墨水屏上不拖动、不惯性）。 */
    private View pageScroll(View v) {
        PageScrollView sv = new PageScrollView(this);
        sv.setFillViewport(true);
        sv.addView(v, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return sv;
    }

    private Seg seg(LinearLayout root, String title, String[] labels) {
        TextView h = Ui.text(this, title, 14, true); h.setTextColor(Blocks.on(this) ? Color.BLACK : Color.DKGRAY);
        h.setPadding(0, dp(10), 0, dp(4)); root.addView(h);
        Seg s = new Seg(this, labels, 13, null);
        root.addView(s, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return s;
    }

    private String currentSpec() {
        return newHost ? AppProf.lookup(table, pkg)[1] : Store.prefs(this, "home").getString("appdisp_" + pkg, "");
    }

    private void load() {
        java.util.Map<String, String> m = AppProf.parse(currentSpec());
        for (Knob k : knobs) if (k.seg != null) k.seg.select(k.index(m.get(k.key)));
        font.select(AppFont.index(AppFont.get(this, pkg)));
        if (keep != null) keep.select(Cleaner.keepAlive(this, pkg) ? 1 : 0);
    }

    private void save() {
        int[] picked = new int[knobs.size()];
        for (int i = 0; i < picked.length; i++) picked[i] = knobs.get(i).seg == null ? -1 : knobs.get(i).seg.selected();
        // 这一页没显示的键（seg == null）不动：merge 里 -1 会去掉它，所以先从列表里拿掉
        List<Knob> shown = new ArrayList<Knob>();
        List<Integer> sp = new ArrayList<Integer>();
        for (int i = 0; i < picked.length; i++) if (picked[i] >= 0) { shown.add(knobs.get(i)); sp.add(picked[i]); }
        int[] p2 = new int[sp.size()];
        for (int i = 0; i < p2.length; i++) p2[i] = sp.get(i);
        String spec = merge(currentSpec(), shown, p2);
        AppFont.set(this, pkg, AppFont.VALUES[Math.max(0, font.selected())]);
        if (keep != null) Cleaner.setKeepAlive(this, pkg, keep.selected() == 1);
        if (newHost) {
            // 全选“跟随”：有内置推荐的应用存成 "-"（不然内置的会回来），没有的就删掉这一行
            AppProf.save(pkg, spec.length() > 0 ? spec : AppProf.builtin(table, pkg) ? "-" : "");
            return;
        }
        Store.prefs(this, "home").edit().putString("appdisp_" + pkg, spec).commit();
        HostLink.cmd(spec.length() == 0 ? "appdisp home" : "appdisp " + pkg + "|" + spec);
    }

    private int dp(int v) { return Ui.dp(this, v); }
}
