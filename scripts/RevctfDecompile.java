// Headless output using Ghidra's Java API, without a Python runtime dependency.
// Author: Jijo Shibu <jijoshibu@gmail.com>
//@category RevCTF
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

public class RevctfDecompile extends GhidraScript {
    private static final int MAX_FUNCTIONS = 200;

    @Override
    protected void run() throws Exception {
        boolean light = getScriptArgs().length > 0 && "1".equals(getScriptArgs()[0]);
        DecompInterface decompiler = new DecompInterface();
        println("=== REVCTF-GHIDRA-BEGIN ===");
        try {
            List<Function> first = new ArrayList<>();
            List<Function> rest = new ArrayList<>();
            int excluded = 0;
            for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
                String name = function.getName().toLowerCase(Locale.ROOT);
                if (name.equals("main") || name.contains("flag") || name.contains("check") ||
                        name.contains("verify") || name.contains("decrypt")) {
                    first.add(function);
                } else if (!name.startsWith("_") && !name.startsWith("frame_dummy") &&
                        !name.startsWith("register_tm") && !name.startsWith("deregister")) {
                    rest.add(function);
                } else {
                    excluded++;
                }
            }
            first.addAll(rest);
            println("Program: " + currentProgram.getName());
            println("Coverage: " + first.size() + " functions selected; " + excluded +
                    " runtime/helper functions excluded");
            if (!light && !decompiler.openProgram(currentProgram)) {
                throw new IllegalStateException("Decompiler could not open program");
            }
            int attempted = 0;
            int recovered = 0;
            for (Function function : first) {
                monitor.checkCancelled();
                if (attempted >= MAX_FUNCTIONS) {
                    println("REVCTF-PARTIAL: function limit reached; " +
                            (first.size() - attempted) + " selected functions not analyzed");
                    break;
                }
                attempted++;
                println("/* ---- " + function.getName() + " @ " + function.getEntryPoint() + " ---- */");
                if (light) {
                    continue;
                }
                try {
                    DecompileResults result = decompiler.decompileFunction(function, 60, monitor);
                    if (result == null || !result.decompileCompleted() || result.getDecompiledFunction() == null) {
                        println("REVCTF-PARTIAL: function decompilation failed");
                        continue;
                    }
                    // The bounded launcher limits capture size. Do not discard later lines.
                    println(result.getDecompiledFunction().getC());
                    recovered++;
                } catch (Exception error) {
                    println("REVCTF-PARTIAL: " + function.getName() + ": " + error);
                }
            }
            println("Coverage: " + attempted + " attempted; " + recovered + " decompiled");
            if (light) {
                println("REVCTF-PARTIAL: inventory only; decompilation was not completed");
            }
        } catch (Exception error) {
            println("REVCTF-ERROR: " + error);
        } finally {
            decompiler.dispose();
            println("=== REVCTF-GHIDRA-END ===");
        }
    }
}
