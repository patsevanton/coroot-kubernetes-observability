import com.sun.net.httpserver.HttpServer;

import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * Демо-приложение для Java-профилирования в Coroot.
 *
 * Профилирование здесь идёт через async-profiler, который coroot-node-agent
 * подгружает динамически по JVM Attach API (флаг ENABLE_JAVA_ASYNC_PROFILER),
 * поэтому Java-агент для профилирования не нужен. OpenTelemetry Java-агент
 * (см. Dockerfile, флаг -javaagent) отвечает только за автоинструментацию
 * трейсов и к профилям CPU/alloc/lock отношения не имеет.
 */
public class DemoJava {
    private static final List<byte[]> retained = new ArrayList<>();
    private static final Object lock = new Object();

    // Экспоненциальная рекурсия: горит в CPU-профиле (флеймграф покажет naiveFib).
    private static int naiveFib(int n) {
        if (n < 2) {
            return n;
        }
        return naiveFib(n - 1) + naiveFib(n - 2);
    }

    private static void cpuBurn() {
        long total = naiveFib(35);
        for (int i = 0; i < 5_000_000; i++) {
            total += i * i;
        }
        if (total == Long.MIN_VALUE) {
            System.out.println(total);
        }
    }

    // Намеренная аллокация — видна в Memory-профиле как alloc_space/alloc_objects.
    private static void allocate() {
        for (int i = 0; i < 200_000; i++) {
            retained.add(new byte[512]);
            if (retained.size() > 50_000) {
                retained.remove(0);
            }
        }
    }

    // Два потока конкурируют за один монитор — даёт Lock-профиль (contentions/delay).
    private static void contendLock() {
        Thread a = new Thread(() -> {
            synchronized (lock) {
                try {
                    Thread.sleep(200);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
        });
        Thread b = new Thread(() -> {
            synchronized (lock) {
                try {
                    Thread.sleep(200);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
        });
        a.start();
        b.start();
        try {
            a.join();
            b.join();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private static void respond(com.sun.net.httpserver.HttpExchange exchange, String body) throws java.io.IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(200, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }

    public static void main(String[] args) throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", 8080), 0);

        server.createContext("/cpu", exchange -> {
            cpuBurn();
            respond(exchange, "burned cpu\n");
        });
        server.createContext("/alloc", exchange -> {
            allocate();
            respond(exchange, "allocated, retained=" + retained.size() + "\n");
        });
        server.createContext("/lock", exchange -> {
            contendLock();
            respond(exchange, "lock contention done\n");
        });
        server.createContext("/healthz", exchange -> respond(exchange, "ok\n"));

        server.setExecutor(java.util.concurrent.Executors.newFixedThreadPool(8));
        server.start();
        System.out.println("demo-service listening on :8080");

        Thread allocator = new Thread(() -> {
            while (true) {
                allocate();
                try {
                    Thread.sleep(500);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        });
        allocator.setDaemon(true);
        allocator.start();
    }
}