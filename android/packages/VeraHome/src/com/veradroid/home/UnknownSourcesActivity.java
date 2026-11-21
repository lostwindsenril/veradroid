package com.veradroid.home;

import android.app.Activity;
import android.os.Bundle;
import android.provider.Settings;

/**
 * 系统里没有“设置”应用。软件包安装程序在“未知来源”关着时弹“出于安全考虑，您的手机已设置为禁止安装来源不明的应用”，
 * 它的“设置”按钮发 android.settings.SECURITY_SETTINGS；以前没有谁接，点了没反应（社区 Oasis 3 老机型 0.8.13：“本地安装不了软件”；新机型开机时已打开“未知来源”，但应用自己去开这一页时一样没人接）。
 * 也有应用自己去开这一页（或 Android 8 的 MANAGE_UNKNOWN_APP_SOURCES），没人接就是 ActivityNotFoundException 闪退。
 * 这里接住：把“未知来源”打开（桌面是平台签名的系统应用，有 WRITE_SECURE_SETTINGS；宿主开机后也会打开），
 * 提示一句就关掉，回到安装程序（它看到已允许就接着装）或原来的应用。没有界面，不留在最近任务里。
 */
public class UnknownSourcesActivity extends Activity {
    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        boolean ok;
        try {
            ok = Settings.Secure.getInt(getContentResolver(), Settings.Secure.INSTALL_NON_MARKET_APPS, 0) == 1
                    || Settings.Secure.putInt(getContentResolver(), Settings.Secure.INSTALL_NON_MARKET_APPS, 1);
        } catch (Throwable e) {
            ok = false;
        }
        // 安装程序是 startActivityForResult 开的这一页，回来时看“未知来源”是不是开了、结果是不是 OK，是就接着装
        setResult(ok ? RESULT_OK : RESULT_CANCELED);
        VeraToast.show(getApplicationContext(), ok ? "已允许安装外部来源的应用。安装没有自动继续的话，再点一次“安装”。"
                : "没能打开“允许安装外部来源的应用”，请重启 Android 后再试。");
        finish();
        overridePendingTransition(0, 0);
    }
}
