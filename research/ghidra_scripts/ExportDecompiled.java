// Decompiles every function in the current program into one C file, with each
// function's address and callers, so the whole binary can be searched as text.
// @category Export
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.stream.Collectors;

public class ExportDecompiled extends GhidraScript {
    @Override
    public void run() throws Exception {
        String out = getScriptArgs().length > 0 ? getScriptArgs()[0] : "decompiled.c";
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);

        int done = 0, failed = 0;
        try (PrintWriter w = new PrintWriter(new FileWriter(out))) {
            FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
            while (it.hasNext() && !monitor.isCancelled()) {
                Function f = it.next();
                String callers = f.getCallingFunctions(monitor).stream()
                        .map(c -> c.getName() + "@" + c.getEntryPoint())
                        .limit(20)
                        .collect(Collectors.joining(", "));
                w.printf("// ==== %s @ %s | callers: %s%n", f.getName(), f.getEntryPoint(), callers);
                DecompileResults r = decompiler.decompileFunction(f, 60, monitor);
                if (r.decompileCompleted()) {
                    w.println(r.getDecompiledFunction().getC());
                    done++;
                } else {
                    w.println("// decompile failed: " + r.getErrorMessage());
                    failed++;
                }
            }
        }
        decompiler.dispose();
        println("Exported " + done + " functions, " + failed + " failed, to " + out);
    }
}
