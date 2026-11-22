package com.veradroid.home;

/** ReaderTurn: turning back / across chapters before the whole book is paginated (tests/reader-turn-test.sh). */
public class ReaderTurnTest {
    static int fail;
    static void eq(String what, int want, int got) {
        if (want != got) { System.out.println("FAIL " + what + ": want " + want + ", got " + got); fail++; }
    }
    static void ok(String what, boolean v) { if (!v) { System.out.println("FAIL " + what); fail++; } }

    public static void main(String[] a) {
        // fixed 10 chars per page, page starts skip blank lines like ReaderActivity.paginate
        ReaderTurn.Cut ten = new ReaderTurn.Cut() { public int end(String s, int i) { return Math.min(s.length(), i + 10); } };
        String s = "0123456789abcdefghij\n\nABCDEFGHIJxyz";   // pages at 0, 10, 22, 32
        eq("first page has no previous page", -1, ReaderTurn.prevStart(s, 0, ten));
        eq("page 2 -> page 1", 0, ReaderTurn.prevStart(s, 10, ten));
        eq("page 3 (after blank lines) -> page 2", 10, ReaderTurn.prevStart(s, 22, ten));
        eq("page 4 -> page 3", 22, ReaderTurn.prevStart(s, 32, ten));
        eq("mid-page resume offset -> start of the page before it", 10, ReaderTurn.prevStart(s, 15, ten));
        eq("last page of the chapter", 32, ReaderTurn.prevStart(s, Integer.MAX_VALUE, ten));
        eq("empty chapter", -1, ReaderTurn.prevStart("", Integer.MAX_VALUE, ten));
        eq("only blank lines", -1, ReaderTurn.prevStart("\n\n\r\n", Integer.MAX_VALUE, ten));
        // a cut that cannot place a single char must still make progress
        ReaderTurn.Cut stuck = new ReaderTurn.Cut() { public int end(String x, int i) { return i; } };
        eq("no endless loop on a zero-width cut", 4, ReaderTurn.prevStart("abcde", 5, stuck));
        ok("chapter has more after page 1", ReaderTurn.chapterHasMore(s, 10));
        ok("chapter has more before the blank lines", ReaderTurn.chapterHasMore(s, 20));
        ok("end of chapter", !ReaderTurn.chapterHasMore(s, s.length()));
        ok("only trailing blank lines left = end of chapter", !ReaderTurn.chapterHasMore("abc\n\n", 3));
        // walking back from the last page visits every page start that paginate() produced, in order
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < 500; i++) b.append(i % 37 == 0 ? "\n\n" : "x");
        String big = b.toString();
        java.util.List<Integer> fwd = new java.util.ArrayList<Integer>();
        for (int i = 0; i < big.length(); ) { i = ReaderTurn.skipBreaks(big, i); if (i >= big.length()) break; fwd.add(i); i = ten.end(big, i); }
        int at = ReaderTurn.prevStart(big, Integer.MAX_VALUE, ten), k = fwd.size() - 1;
        while (at >= 0) { eq("walk back page " + k, fwd.get(k), at); at = ReaderTurn.prevStart(big, at, ten); k--; }
        eq("walked back over every page", -1, k);
        // 翻页动画（KFB_ANIM_MODE）-> the bridge SWIPE direction (0 down 1 up 2 left 3 right)
        eq("animation off: no swipe", -1, ReaderTurn.slideDir(0, false, 1));
        eq("follow: next page slides left", 2, ReaderTurn.slideDir(1, false, 1));
        eq("follow: previous page slides right", 3, ReaderTurn.slideDir(1, false, -1));
        eq("fixed left", 2, ReaderTurn.slideDir(2, false, -1));
        eq("fixed right", 3, ReaderTurn.slideDir(3, false, 1));
        eq("fixed up", 1, ReaderTurn.slideDir(4, false, 1));
        eq("fixed down", 0, ReaderTurn.slideDir(5, false, 1));
        eq("host says no hardware swipe (KFB_SWIPE=0)", -1, ReaderTurn.slideDir(1, true, 1));
        eq("unknown mode", -1, ReaderTurn.slideDir(9, false, 1));
        System.out.println(fail == 0 ? "ReaderTurnTest: ok" : "ReaderTurnTest: " + fail + " failed");
        System.exit(fail == 0 ? 0 : 1);
    }
}
