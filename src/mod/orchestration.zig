//! # The Build Orchestrator
//!
//! This module is the brain of the Ribbon compiler. It is responsible for managing
//! the entire build process, from discovering source files to coordinating the
//! frontend and backend services and managing the compilation cache.
//!
//! Its design is based on the "vertical slice" strategy outlined in the project's
//! implementation plan. It introduces the `CompilationSession` as a central,
//! short-lived object to hold the state for a single build run, cleanly
//! separating the persistent IR from transient build metadata.
//!
//! ## Core Responsibilities:
//! 1.  **Dependency Discovery:** Parse rmod files to find dependencies and
//!     build a complete `DependencyGraph` of the project.
//! 2.  **Build Order:** Perform a topological sort on the graph to determine the
//!     correct, linear order of compilation.
//! 3.  **Session Management:** Create and manage the `CompilationSession` that
//!     provides a unified context for all compiler services during a build.
//! 4.  **Coordination:** Invoke the `FrontendService` for each module in order,
//!     providing it with the necessary dependency information.
//! 5.  **Incrementality (Future):** Use the `interface_hash` from generated SMAs
//!     to determine which modules require recompilation.
//! 6.  **Parallelism (Future):** Schedule compilation jobs for the `BackendService`
//!     to run in parallel.

const orchestration = @This();

const std = @import("std");
const log = std.log.scoped(.orchestration);

const common = @import("common");
const core = @import("core");
const ir = @import("ir");
const frontend = @import("frontend");

test {
    //std.debug.print("semantic analysis for orchestration\n", .{});
    std.testing.refAllDecls(@This());
}

/// Information about a single module discovered during a build.
pub const ModuleInfo = struct {
    /// The canonical path to the module source file, relative to the build root.
    path: []const u8,

    /// A cryptographic hash of the canonical module path, serving as a stable,
    /// unique identifier for this module across all builds and machines.
    guid: ir.ModuleGUID,

    /// A list of the GUIDs of modules that this module directly imports.
    dependencies: common.ArrayList(ir.ModuleGUID),

    /// The cryptographic hash of this module's public interface (API/ABI).
    /// This is populated after the frontend pass and is the key to incremental builds.
    interface_hash: ?u128 = null,

    /// The path to the cached `.sma` file for this module.
    sma_path: ?[]const u8 = null,

    pub fn deinit(self: *ModuleInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.sma_path) |p| allocator.free(p);
        self.dependencies.deinit(allocator);
    }
};

/// Represents the complete dependency graph for a project.
/// The graph is a map from a module's stable GUID to its metadata.
pub const DependencyGraph = struct {
    allocator: std.mem.Allocator,
    modules: common.HashMap(ir.ModuleGUID, ModuleInfo, common.UniqueReprHashContext64(ir.ModuleGUID)),

    pub fn deinit(self: *DependencyGraph) void {
        var it = self.modules.valueIterator();
        while (it.next()) |module_info| {
            module_info.deinit(self.allocator);
        }
        self.modules.deinit(self.allocator);
    }
};

/// A short-lived object representing the state of a single build run.
/// It owns the root `ir.Context` and holds critical mapping data, cleanly
/// separating the persistent IR from transient, build-specific metadata.
pub const CompilationSession = struct {
    gpa: std.mem.Allocator,

    /// The single root IR context for this build. All child contexts for
    /// individual modules will be created under this root.
    root_context: *ir.Context,

    /// Maps a child context's ID to its module's GUID. This is the key to
    /// resolving external references during SMA dehydration.
    // context_id_to_module: common.HashMap(ir.Context.Id, ir.ModuleGUID, common.UniqueReprHashContext64(ir.Context.Id)),

    /// TODO: A reverse map from an `ir.Ref` (pointing to an external symbol)
    /// back to its original module GUID and symbol name. This will be populated
    /// during dependency rehydration in Phase 2.
    // ref_to_external_symbol: common.HashMap(ir.Ref, ExternalSymbolInfo, ...),

    pub fn init(allocator: std.mem.Allocator) !*CompilationSession {
        const self = try allocator.create(CompilationSession);
        self.* = .{
            .gpa = allocator,
            .root_context = try ir.Context.init(allocator),
            .context_id_to_module = .{},
            // .ref_to_external_symbol = .{},
        };
        return self;
    }

    pub fn deinit(self: *CompilationSession) void {
        self.context_id_to_module.deinit(self.gpa);
        // self.ref_to_external_symbol.deinit(self.gpa);
        self.root_context.deinit();
        self.gpa.destroy(self);
    }
};

/// The main orchestrator for the Ribbon build system.
pub const BuildOrchestrator = struct {
    gpa: std.mem.Allocator,
    cache_dir: std.fs.Dir,
    build_root: std.fs.Dir,

    pub fn init(allocator: std.mem.Allocator, build_root_path: []const u8, cache_dir_path: []const u8) !BuildOrchestrator {
        const build_root = try std.fs.cwd().openDir(build_root_path, .{});
        const cache_dir = try std.fs.cwd().makeOpenPath(cache_dir_path, .{});
        return .{
            .gpa = allocator,
            .cache_dir = cache_dir,
            .build_root = build_root,
        };
    }

    pub fn deinit(self: *BuildOrchestrator) void {
        self.cache_dir.close();
        self.build_root.close();
    }

    /// The main entry point for building a project.
    pub fn build(self: *BuildOrchestrator, root_module_path: []const u8) !void {
        log.info("Starting build for root module: {s}", .{root_module_path});

        // Phase 1: Build the dependency graph.
        var graph = DependencyGraph{ .allocator = self.gpa, .modules = .{} };
        defer graph.deinit();
        try self.buildDependencyGraph(root_module_path, &graph);

        // Phase 1: Topologically sort the graph to get a linear build order.
        var build_order = try self.findBuildOrder(&graph);
        defer for (build_order.items) |*scc| scc.deinit(self.gpa);
        defer build_order.deinit(self.gpa);

        log.debug("Determined build order (SCCs):", .{});
        for (build_order.items, 0..) |scc, i| {
            log.debug("  Group {d}:", .{i});
            for (scc.items) |guid| {
                const module_info = graph.modules.get(guid).?;
                log.debug("    - {s} ({x})", .{ module_info.path, guid });
            }
        }

        // --- Build Execution ---
        const session = try CompilationSession.init(self.gpa);
        defer session.deinit();

        // Phase 2: Frontend Pass (Sequential Analysis)
        // We iterate over the SCCs in topological order. All modules in an SCC
        // must be analyzed together before moving to the next SCC.
        for (build_order.items) |scc| {
            // TODO: The frontend service will need to be adapted to accept a whole
            // SCC at once to correctly handle cyclic dependencies.
            for (scc.items) |module_guid| {
                try self.runFrontendPass(session, graph.modules.get(module_guid).?);
            }
        }

        // Phase 3 & 4: Backend Pass (Incremental & Parallel)
        try self.runBackendPass(session, &graph, build_order.items);

        log.info("Build finished successfully.", .{});
    }

    /// Recursively discovers all dependencies starting from a root module and populates the graph.
    fn buildDependencyGraph(self: *BuildOrchestrator, root_path: []const u8, graph: *DependencyGraph) !void {
        var work_queue = common.ArrayList([]const u8){};
        defer work_queue.deinit(self.gpa);
        try work_queue.append(self.gpa, try self.gpa.dupe(u8, root_path));

        var visited = common.StringHashMap(void){};
        defer visited.deinit(self.gpa);

        while (work_queue.popOrNull()) |current_path| {
            defer self.gpa.free(current_path);

            if (visited.contains(current_path)) continue;
            try visited.put(self.gpa, current_path, {});

            const canonical_path = try self.canonicalizePath(current_path);
            const guid = ir.ModuleGUID.fromInt(common.hash128(canonical_path));

            // TODO: Replace this stub with a real call to a lightweight frontend parser.
            // const dependency_paths = try frontend.discoverImports(self.build_root, current_path);
            const dependency_paths = &[_][]const u8{}; // Stub

            var module_info = ModuleInfo{
                .path = try self.gpa.dupe(u8, canonical_path),
                .guid = guid,
                .dependencies = .{},
            };

            for (dependency_paths) |dep_path| {
                const dep_canonical_path = try self.canonicalizePath(dep_path);
                defer self.gpa.free(dep_canonical_path);

                const dep_guid = ir.ModuleGUID.fromInt(common.hash128(dep_canonical_path));
                try module_info.dependencies.append(self.gpa, dep_guid);
                try work_queue.append(self.gpa, try self.gpa.dupe(u8, dep_path));
            }

            try graph.modules.put(self.gpa, guid, module_info);
        }
    }

    /// Uses Tarjan's algorithm to find the Strongly Connected Components (SCCs) of the
    /// dependency graph. This correctly handles cyclic dependencies between modules.
    ///
    /// Returns a list of SCCs, where each SCC is a list of module GUIDs. The outer
    /// list is topologically sorted.
    fn findBuildOrder(self: *BuildOrchestrator, graph: *const DependencyGraph) !common.ArrayList(common.ArrayList(ir.ModuleGUID)) {
        return Tarjan.run(self, graph);
    }

    /// **PHASE 2**: Runs the frontend analysis for a single module.
    fn runFrontendPass(self: *BuildOrchestrator, session: *CompilationSession, module: ModuleInfo) !void {
        log.info("Frontend pass for: {s}", .{module.path});

        // TODO: Load the SMAs of `module.dependencies` from `self.cache_dir`.
        // TODO: Create a `frontend.AnalysisJob` or similar.
        // TODO: Pass the `session` and dependency SMAs to the `FrontendService`.
        // TODO: The `FrontendService` will rehydrate dependencies into the session's
        //       `root_context`, then analyze `module.path`, producing a new `.sma` file.
        // TODO: Save the new `.sma` to the cache.
        _ = self;
        _ = session;
    }

    /// **PHASE 3 & 4**: Schedules and runs backend compilation jobs.
    fn runBackendPass(
        self: *BuildOrchestrator,
        session: *CompilationSession,
        graph: *const DependencyGraph,
        build_order: []const common.ArrayList(ir.ModuleGUID),
    ) !void {
        log.info("Backend pass...", .{});

        // TODO (Phase 4):
        // 1. For each module in `build_order`:
        //    a. Generate the new `interface_hash` using `cbr.generateInterfaceHash`.
        //    b. Load the old SMA from the cache and compare hashes.
        //    c. If hashes differ, add the module AND all its reverse-dependencies
        //       to a "dirty set" of modules that need a backend compile.
        //
        // TODO (Phase 3 & 4):
        // 2. Create a list of `backend.Job`s from the dirty set.
        // 3. (Phase 4) Submit these jobs to a thread pool for parallel execution.
        // 4. (Phase 3) For now, just compile the final root module sequentially.
        _ = self;
        _ = session;
        _ = build_order;
        _ = graph;
    }

    /// Normalizes a path and makes it relative to the build root.
    fn canonicalizePath(self: *BuildOrchestrator, path: []const u8) ![]const u8 {
        // TODO: Implement robust path canonicalization. This is critical for
        // ensuring ModuleGUIDs are stable. It should resolve `.` and `..`
        // and be relative to `self.build_root`.
        return self.gpa.dupe(u8, path);
    }
};

const Tarjan = struct {
    orchestrator: *BuildOrchestrator,
    graph: *const DependencyGraph,

    index: u32 = 0,
    stack: common.ArrayList(ir.ModuleGUID),
    node_info: common.HashMap(ir.ModuleGUID, NodeInfo, common.UniqueReprHashContext64(ir.ModuleGUID)),
    sccs: common.ArrayList(common.ArrayList(ir.ModuleGUID)),

    const NodeInfo = struct {
        index: u32,
        low_link: u32,
        on_stack: bool = false,
    };

    fn run(o: *BuildOrchestrator, g: *const DependencyGraph) !common.ArrayList(common.ArrayList(ir.ModuleGUID)) {
        var self = Tarjan{
            .orchestrator = o,
            .graph = g,
            .stack = .{},
            .node_info = .{},
            .sccs = .{},
        };
        defer {
            self.stack.deinit(o.gpa);
            self.node_info.deinit(o.gpa);
        }

        var module_it = self.graph.modules.keyIterator();
        while (module_it.next()) |guid| {
            if (!self.node_info.contains(guid.*)) {
                try self.strongconnect(guid.*);
            }
        }

        // Tarjan's algorithm finds SCCs in reverse topological order.
        // We reverse the list to get the correct build order.
        std.mem.reverse(common.ArrayList(ir.ModuleGUID), self.sccs.items);

        return self.sccs;
    }

    fn strongconnect(self: *Tarjan, v_guid: ir.ModuleGUID) !void {
        // Set the depth index for v to the smallest unused index
        _ = try self.node_info.put(self.orchestrator.gpa, v_guid, .{
            .index = self.index,
            .low_link = self.index,
            .on_stack = true,
        });
        self.index += 1;
        try self.stack.append(self.orchestrator.gpa, v_guid);

        // Consider successors of v
        const module = self.graph.modules.get(v_guid).?;
        for (module.dependencies.items) |w_guid| {
            if (self.node_info.get(w_guid)) |w_info| {
                if (w_info.on_stack) {
                    // Successor w is in stack S and hence in the current SCC
                    const v_info = self.node_info.getPtr(v_guid).?;
                    v_info.low_link = @min(v_info.low_link, w_info.index);
                }
            } else {
                // Successor w has not yet been visited; recurse on it
                try self.strongconnect(w_guid);
                const v_info = self.node_info.getPtr(v_guid).?;
                const w_low_link = self.node_info.get(w_guid).?.low_link;
                v_info.low_link = @min(v_info.low_link, w_low_link);
            }
        }

        // If v is a root node, pop the stack and generate an SCC
        if (self.node_info.get(v_guid).?.low_link == self.node_info.get(v_guid).?.index) {
            var new_scc = common.ArrayList(ir.ModuleGUID).init(self.orchestrator.gpa);
            errdefer new_scc.deinit(self.orchestrator.gpa);

            while (true) {
                const w_guid = self.stack.pop();
                const w_info = self.node_info.getPtr(w_guid).?;
                w_info.on_stack = false;
                try new_scc.append(self.orchestrator.gpa, w_guid);
                if (w_guid == v_guid) break;
            }
            try self.sccs.append(self.orchestrator.gpa, new_scc);
        }
    }
};
