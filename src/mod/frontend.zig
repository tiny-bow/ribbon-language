//! # The Frontend Service
// ... (module documentation remains the same) ...

const frontend = @This();

const std = @import("std");
const log = std.log.scoped(.frontend);

const common = @import("common");
const core = @import("core");
const ir = @import("ir");
const sma = @import("sma");
const analysis = @import("analysis");
const orchestration = @import("orchestration");
const meta_language = @import("meta_language");

test {
    std.testing.refAllDecls(@This());
}

/// A helper struct to encapsulate the state and logic for analyzing a single module.
const FrontendPass = struct {
    session: *orchestration.CompilationSession,
    module_info: *const orchestration.ModuleInfo,

    /// High-level function to manage the import of a single dependency.
    /// It handles creating the necessary IR context and updating the session maps.
    fn importDependency(pass: *FrontendPass, dependency_sma: *const sma.Artifact) !void {
        const allocator = pass.session.gpa;
        const root_ctx = pass.session.root_context;

        // 1. Create a new, dedicated context for the dependency module.
        const child_ctx = blk: {
            const root = root_ctx.asRoot().?;
            root.mutex.lock();
            defer root.mutex.unlock();
            break :blk try root.createContext();
        };

        // 2. Associate the new context ID with the module's GUID in the session.
        try pass.session.context_id_to_module.put(allocator, child_ctx.id, dependency_sma.header.module_guid);

        // 3. Call the low-level rehydrator in the `sma` module to do the mechanical translation.
        try dependency_sma.rehydrateInto(pass.session, child_ctx);

        // 4. TODO: Populate the session's `ref_to_external_symbol` map so that other modules
        //    can resolve symbols from this dependency. This will require iterating the
        //    SMA's public symbol table and the node_map created during rehydration.
    }

    /// The primary method that executes the frontend pass for the given module.
    pub fn run(pass: *FrontendPass) !*sma.Artifact {
        const allocator = pass.session.gpa;

        // --- Phase 2: Rehydrate Dependencies ---
        // TODO: The orchestrator will load dependency SMAs and pass them here.
        // for (dependency_smas) |dep_sma| {
        //     try pass.importDependency(dep_sma);
        // }

        // Create a new context for the module we are compiling.
        const module_ctx = blk: {
            const root = pass.session.root_context.asRoot().?;
            root.mutex.lock();
            defer root.mutex.unlock();
            break :blk try root.createContext();
        };
        try pass.session.context_id_to_module.put(allocator, module_ctx.id, pass.module_info.guid);

        // --- Analyze Source and Generate IR ---
        // TODO: Read source file from `pass.module_info.path`.
        const source_code = "// stub source code";
        var ast = try meta_language.Expr.parseSource(allocator, .{}, pass.module_info.path, source_code);
        if (ast) |*root_expr| {
            defer root_expr.deinit(allocator);
            // === TODO: Traverse `root_expr` and populate `module_ctx` ===
            common.todo(void, .{module_ctx});
        }

        // --- Dehydrate the generated IR into an SMA ---
        log.debug("Dehydrating IR for module {s}...", .{pass.module_info.path});
        const artifact = try sma.Artifact.fromIr(module_ctx, pass.module_info.guid, allocator);

        // --- Phase 4: Compute Interface Hash ---
        // TODO: Compute and set `artifact.header.interface_hash`.

        return artifact;
    }
};

/// The main entry point for the frontend service.
pub fn generateSMA(
    session: *orchestration.CompilationSession,
    module_info: *const orchestration.ModuleInfo,
) !*sma.Artifact {
    var pass = FrontendPass{
        .session = session,
        .module_info = module_info,
    };
    return pass.run();
}
