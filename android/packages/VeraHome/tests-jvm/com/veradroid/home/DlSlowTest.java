package com.veradroid.home;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.File;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Random;
import java.util.Set;

/**
 * Dl slow-source switching (2026-11-21 field report "einkbro 11%, 8 KB/s, 镜像"): a mirror that answers the 256 KB probe
 * quickly and then crawls must be left for the main site, keeping the bytes already downloaded; a single source is never
 * given up. Two local HTTP servers with Range support; the "mirror" serves the probe at full speed and everything else at
 * about 8 KB/s; the main site answers the probe 400 ms later, so the probe picks the mirror (as in the field). Run by tests/store-dl-slow-test.sh.
 */
public class DlSlowTest {
    static byte[] data;
    static int fails;

    static HttpServer server(final long bps, final int[] hits) throws Exception { return server(bps, hits, 0); }

    /** probeMs: extra wait before answering the 256 KB probe (the main site's longer first byte through Cloudflare). */
    static HttpServer server(final long bps, final int[] hits, final long probeMs) throws Exception {
        HttpServer s = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        s.createContext("/", (HttpExchange x) -> {
            hits[0]++;
            String r = x.getRequestHeaders().getFirst("Range");
            long a = 0, b = data.length - 1;
            if (r != null && r.startsWith("bytes=")) {
                String[] p = r.substring(6).split("-", -1);
                a = Long.parseLong(p[0]); if (!p[1].isEmpty()) b = Math.min(b, Long.parseLong(p[1]));
                x.getResponseHeaders().set("Content-Range", "bytes " + a + "-" + b + "/" + data.length);
                x.sendResponseHeaders(206, b - a + 1);
            } else x.sendResponseHeaders(200, data.length);
            boolean probe = a == 0 && b == 262143;
            if (probe && probeMs > 0) try { Thread.sleep(probeMs); } catch (InterruptedException e) { }
            OutputStream o = x.getResponseBody();
            try {
                for (long i = a; i <= b; ) {
                    int n = (int) Math.min(4096, b - i + 1);
                    o.write(data, (int) i, n); i += n;
                    if (bps > 0 && !probe) Thread.sleep(n * 1000L / bps);
                }
            } catch (Exception e) { /* client went away */ }
            try { o.close(); } catch (Exception e) { }
        });
        s.setExecutor(java.util.concurrent.Executors.newCachedThreadPool());
        s.start();
        return s;
    }

    static void check(boolean ok, String what) { System.out.println((ok ? "ok   " : "FAIL ") + what); if (!ok) fails++; }

    /** Downloads like StoreActivity.download: on Slow go on with the same slow set, other errors retry a few times. */
    static long run(List<String> cands, File out, Set<String> slow, int[] slowHits) throws Exception {
        long t0 = System.currentTimeMillis();
        for (int tries = 0; tries < 6; tries++) {
            try { Dl.fetchOnce(cands, out, data.length, null, slow); if (out.length() == data.length) break; }
            catch (Dl.Slow e) { slowHits[0]++; tries--; }
            catch (java.io.IOException e) { System.out.println("retry: " + e); }
        }
        return System.currentTimeMillis() - t0;
    }

    public static void main(String[] args) throws Exception {
        Dl.WARM_MS = 2500; Dl.WINDOW_MS = 2000; Dl.SLOW_BPS = 48 << 10;
        File dir = Files.createTempDirectory("vd-dl").toFile();
        for (int size : new int[] { 4417011, 1500000 }) {      // EinkBro's size (segmented) and a small app (one connection)
            data = new byte[size]; new Random(size).nextBytes(data);
            int[] mh = {0}, fh = {0};
            HttpServer mirror = server(8 << 10, mh), main = server(0, fh, 400);
            String mu = "http://127.0.0.1:" + mirror.getAddress().getPort() + "/api/store/download/10";
            String fu = "http://127.0.0.1:" + main.getAddress().getPort() + "/api/store/download/10?device_id=x&token=y";
            List<String> cands = new ArrayList<String>(Arrays.asList(mu, fu));
            File out = new File(dir, "a" + size + ".apk"); Dl.clear(out);
            Set<String> slow = new HashSet<String>(); int[] sh = {0};
            long ms = run(cands, out, slow, sh);
            check(out.length() == size && Arrays.equals(Files.readAllBytes(out.toPath()), data), size + " B: complete and identical after switching");
            check(sh[0] == 1 && slow.contains(mu) && !slow.contains(fu), size + " B: mirror given up once (" + sh[0] + "), main kept");
            check(ms < 20000, size + " B: done in " + ms + " ms (8 KB/s alone would take " + (size / 8192) + " s)");
            // a single slow source is never given up: finishes (slowly) without Slow
            byte[] small = Arrays.copyOf(data, 262144 + 200000); data = small;
            File o2 = new File(dir, "b" + size + ".apk"); Dl.clear(o2);
            HttpServer only = server(64 << 10, new int[] {0});
            List<String> one = Arrays.asList("http://127.0.0.1:" + only.getAddress().getPort() + "/x");
            int[] sh2 = {0}; long ms2 = run(one, o2, new HashSet<String>(), sh2);
            check(o2.length() == data.length && sh2[0] == 0, size + " B: one slow source is kept (" + ms2 + " ms, slow=" + sh2[0] + ")");
            mirror.stop(0); main.stop(0); only.stop(0);
        }
        System.out.println(fails == 0 ? "DlSlowTest: ok" : "DlSlowTest: " + fails + " failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
