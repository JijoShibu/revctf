// Verify the running JVM before analysis, regardless of the selected post-script.
// @category Revctf
import ghidra.app.util.headless.HeadlessScript;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

public class RevctfMemoryGuard extends HeadlessScript {
    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        // Fail closed: only enable continuation after measurement and evidence writing.
        setHeadlessContinuationOption(HeadlessContinuationOption.ABORT);
        if (args.length != 2) {
            printerr("REVCTF-ERROR: memory guard arguments missing");
            return;
        }
        long requested = Long.parseLong(args[1]) * 1024L * 1024L;
        long measured = Runtime.getRuntime().maxMemory();
        boolean valid = measured > 0 && requested > 0 && measured <= requested;
        String evidence = "requested_heap_bytes=" + requested + "\nmeasured_heap_bytes=" + measured
            + "\nverified=" + (valid ? "1" : "0") + "\n";
        // Record the actual Linux cgroup limit when available (v2). Older systems
        // retain the heap check and explicitly report that this measurement is absent.
        String processLimit = "unavailable";
        try {
            for (String line : Files.readAllLines(Paths.get("/proc/self/cgroup"))) {
                if (line.startsWith("0::")) {
                    processLimit = new String(Files.readAllBytes(Paths.get(
                        "/sys/fs/cgroup" + line.substring(3), "memory.max")), StandardCharsets.UTF_8).trim();
                }
            }
        } catch (Exception ignored) { /* optional process measurement */ }
        evidence += "measured_process_limit_bytes=" + processLimit + "\n";
        Files.write(Paths.get(args[0]), evidence.getBytes(StandardCharsets.UTF_8));
        if (!valid) {
            printerr("REVCTF-ERROR: actual Java heap exceeds the requested allowance");
            return;
        }
        setHeadlessContinuationOption(HeadlessContinuationOption.CONTINUE);
    }
}
