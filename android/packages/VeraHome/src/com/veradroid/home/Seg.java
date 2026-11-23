// SPDX-License-Identifier: GPL-3.0-or-later
package com.veradroid.home;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;

/** A row of mutually exclusive buttons ("segmented control"); the selected one is drawn inverted (white on black). */
class Seg extends LinearLayout {
    interface Listener { void onPick(int index); }

    private final Button[] buttons;
    private final String[] labels;
    private int selected = -1;
    private final float sp;

    Seg(Context c, String[] labels, float sp, final Listener l) {
        super(c);
        this.labels = labels;
        this.sp = sp;
        setOrientation(VERTICAL);
        buttons = new Button[labels.length];
        // 自动换行网格：超过 4 项或文案较长时每行最多排 3~4 个，避免在 6 寸屏上把选项文字挤扁/截断
        int maxLen = 0;
        for (String s : labels) if (s != null && s.length() > maxLen) maxLen = s.length();
        int cols = labels.length <= 4 ? (maxLen >= 7 && labels.length >= 3 ? 2 : labels.length) : (maxLen >= 5 ? 3 : 4);
        if (cols < 1) cols = 1;
        LinearLayout row = null;
        int gap = Ui.dp(c, 6);
        for (int i = 0; i < labels.length; i++) {
            int col = i % cols;
            if (col == 0) {
                row = new LinearLayout(c);
                row.setOrientation(HORIZONTAL);
                LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                if (i > 0) rlp.topMargin = gap;
                addView(row, rlp);
            }
            final int idx = i;
            buttons[i] = Ui.button(c, labels[i], sp, false, new View.OnClickListener() {
                @Override public void onClick(View v) { select(idx); if (l != null) l.onPick(idx); }
            });
            buttons[i].setMinWidth(0);
            buttons[i].setMinimumWidth(0);
            buttons[i].setMinHeight(Ui.dp(c, 44));
            buttons[i].setMinimumHeight(Ui.dp(c, 44));
            buttons[i].setSingleLine(false);
            buttons[i].setMaxLines(2);
            buttons[i].setPadding(gap, gap, gap, gap);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1);
            lp.leftMargin = col == 0 ? 0 : gap;
            row.addView(buttons[i], lp);
        }
        // 最后一行不满时补空白占位，保证所有按钮等宽整齐对齐（高度与按钮一致，绝不能用 1px 压扁整行）
        if (row != null && labels.length > cols && (labels.length % cols) != 0) {
            int rem = cols - (labels.length % cols);
            for (int r = 0; r < rem; r++) {
                View spc = new View(c);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, Ui.dp(c, 44), 1);
                lp.leftMargin = gap;
                row.addView(spc, lp);
            }
        }
    }

    void select(int idx) {
        if (idx == selected) return;     // 没变：不换背景，不触发重画
        selected = idx;
        Context c = getContext();
        for (int i = 0; i < buttons.length; i++) {
            Button b = buttons[i];
            boolean on = i == idx;
            b.setBackground(Ui.frame(c, on));
            b.setTextColor(new android.content.res.ColorStateList(new int[][] { { android.R.attr.state_pressed }, {} },
                new int[] { on ? android.graphics.Color.BLACK : android.graphics.Color.WHITE, on ? android.graphics.Color.WHITE : android.graphics.Color.BLACK }));
        }
    }

    int selected() { return selected; }
}
