package org.json;

/** JVM stand-in for the one org.json call in Dl.java (error bodies); tests-jvm only, never in the APK. */
public class JSONObject {
    private final String s;
    public JSONObject(String s) { this.s = s; }
    public String optString(String k, String def) {
        int i = s.indexOf("\"" + k + "\""); if (i < 0) return def;
        int a = s.indexOf('"', s.indexOf(':', i) + 1), b = a < 0 ? -1 : s.indexOf('"', a + 1);
        return a < 0 || b < 0 ? def : s.substring(a + 1, b);
    }
}
