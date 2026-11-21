package android.util;

/** JVM stand-in for the few android.util.Log calls in plain-Java classes under test (tests-jvm only, never in the APK). */
public final class Log {
    private Log() { }
    public static int i(String tag, String msg) { System.out.println("I/" + tag + ": " + msg); return 0; }
    public static int w(String tag, String msg) { System.out.println("W/" + tag + ": " + msg); return 0; }
}
