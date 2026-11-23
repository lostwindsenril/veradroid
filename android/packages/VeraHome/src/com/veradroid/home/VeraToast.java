// SPDX-License-Identifier: GPL-3.0-or-later
package com.veradroid.home;

import android.app.Activity;
import android.app.Dialog;
import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.TextView;

/** Custom black-on-white toast; AOSP's Toast is not used anywhere in VeraDroid. */
final class VeraToast {
    private VeraToast() { }

    static void show(Context c, String msg) {
        if (!(c instanceof Activity)) { overlay(c, msg); return; }
        final Activity a = (Activity) c;
        if (a.isFinishing() || a.isDestroyed()) return;
        final Dialog d = new Dialog(a);
        d.requestWindowFeature(Window.FEATURE_NO_TITLE);
        d.setCanceledOnTouchOutside(true);
        TextView t = Ui.text(a, msg, 16, false);
        t.setTextColor(Color.BLACK);
        t.setPadding(Ui.dp(a, 18), Ui.dp(a, 12), Ui.dp(a, 18), Ui.dp(a, 12));
        t.setBackground(Ui.frame(a, false));
        if (Blocks.on(a)) {   // 方块风格：带投影的直角框，粗体字
            t.setBackground(Blocks.frame(a));
            Fonts.apply(t, true);
            t.setPadding(Ui.dp(a, 18), Ui.dp(a, 12), Ui.dp(a, 18) + Blocks.shade(a), Ui.dp(a, 12) + Blocks.shade(a));
        }
        t.setMaxLines(4);
        d.setContentView(t);
        try {
            d.show();
        } catch (android.view.WindowManager.BadTokenException e) {
            return;
        } catch (Throwable e) {
            return;
        }
        Window w = d.getWindow();
        if (w != null) {
            w.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            w.setWindowAnimations(0);
            w.setLayout(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            w.setGravity(Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
            WindowManager.LayoutParams lp = w.getAttributes();
            lp.y = Ui.dp(a, 82);   // 悬浮在底部导航栏和翻页条上方，不遮挡按键
            w.setAttributes(lp);
            w.addFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE);
            // 不压暗背景：墨水屏上压暗 = 整屏变灰再变回来，两次全屏重绘
            w.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
        }
        new Handler(Looper.getMainLooper()).postDelayed(new Runnable() {
            @Override public void run() { try { if (d.isShowing() && !a.isFinishing()) d.dismiss(); } catch (Throwable ignored) { } }
        }, 2200);
    }

    /**
     * 没有 Activity 的时候（下拉面板、服务里）：一个悬浮小窗口（和面板同一种窗口类型），在屏幕下方停 2.2 秒，不抢焦点、不挡点按。
     */
    private static void overlay(Context c, String msg) {
        try {
            final Context ctx = c.getApplicationContext();
            final WindowManager wm = (WindowManager) ctx.getSystemService(Context.WINDOW_SERVICE);
            TextView t = Ui.text(ctx, msg, 16, Blocks.on(ctx));
            t.setTextColor(Color.BLACK);
            t.setMaxLines(3);
            if (Blocks.on(ctx)) {
                t.setBackground(Blocks.frame(ctx));
                t.setPadding(Ui.dp(ctx, 18), Ui.dp(ctx, 12), Ui.dp(ctx, 18) + Blocks.shade(ctx), Ui.dp(ctx, 12) + Blocks.shade(ctx));
            } else {
                t.setBackground(Ui.frame(ctx, false));
                t.setPadding(Ui.dp(ctx, 18), Ui.dp(ctx, 12), Ui.dp(ctx, 18), Ui.dp(ctx, 12));
            }
            WindowManager.LayoutParams lp = new WindowManager.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_SYSTEM_ALERT,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE, android.graphics.PixelFormat.TRANSLUCENT);
            lp.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;
            lp.y = Ui.dp(ctx, 60);
            lp.windowAnimations = 0;
            lp.setTitle("VeraToast");
            final android.view.View v = t;
            wm.addView(v, lp);
            new Handler(Looper.getMainLooper()).postDelayed(new Runnable() {
                @Override public void run() { try { wm.removeViewImmediate(v); } catch (Throwable ignored) { } }
            }, 2200);
        } catch (Throwable e) { android.util.Log.w("VeraHome", "toast: " + e); }
    }
}
