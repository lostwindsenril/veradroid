package com.veradroid.home;

/**
 * 阅读器在整本书分完页之前的翻页（纯 Java，tests-jvm/ReaderTurnTest 直接测）。
 *
 * 打开一本书时先只排正在读的那一页（ReaderActivity.showFirst / showProv），整本书在后台读完、分完页才有页表。
 * 大书（上千章的网文）要十几秒到几十秒；以前这段时间里“上一页”什么也不做（prev() 只认页表），
 * 翻到一章的最后一页时整本还没读进来，“下一页”也什么都不做——看起来就是点左边不回翻、章末点了不进下一章。
 * 这里用和整本分页（ReaderActivity.paginate）同样的切法，从章首排到当前位置，找出上一页的起点。
 */
final class ReaderTurn {
    private ReaderTurn() { }

    /** 从 from 开始一页排到哪里（ReaderActivity.pageEnd：画笔、宽高、行距都和正文一样）。 */
    interface Cut { int end(String s, int from); }

    /** 跳过页首的空行（每页都不以空行开头；和 ReaderActivity.paginate 一致）。 */
    static int skipBreaks(String s, int i) {
        while (i < s.length() && (s.charAt(i) == '\n' || s.charAt(i) == '\r')) i++;
        return i;
    }

    /**
     * 这一章里、起点在 before 之前的最后一页的起点；before 前面没有页了（已经是本章第一页）返回 -1。
     * before = Integer.MAX_VALUE：本章最后一页的起点（往回翻进上一章时用）；空章返回 -1。
     */
    static int prevStart(String s, int before, Cut cut) {
        int i = 0, last = -1;
        while (i < s.length()) {
            i = skipBreaks(s, i);
            if (i >= s.length() || i >= before) break;
            last = i;
            int e = cut.end(s, i);
            i = e > i ? e : i + 1;       // 排不下一个字也要往前走，不会死循环
        }
        return last;
    }

    /** 这一页 [start, end) 之后本章还有字吗（没有 = 本章最后一页，下一页要进下一章）。 */
    static boolean chapterHasMore(String s, int end) {
        return skipBreaks(s, Math.max(0, end)) < s.length();
    }
}
