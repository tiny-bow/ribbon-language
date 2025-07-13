//! Backend compiling Ribbon IR.

const backend = @This();

const std = @import("std");
const pl = @import("platform");
const ir = @import("ir");
const core = @import("core");
const bytecode = @import("bytecode");
const Id = @import("common").Id;

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub const ArtifactId = Id.of(core.ForeignAddressId, 64);

pub const Artifact = packed struct {
    id: ArtifactId,
    value: *const anyopaque,
};

const Pass = struct {
    name: []const u8,
    run: *const fn (pass: *Pass, job: *Job) anyerror!void,
    data: ?*const anyopaque = null,
};

pub const Target = packed struct {
    data: *anyopaque,
    vtable: *const VTable,

    pub const Error = anyerror;

    /// Run a compilation job on this target.
    pub fn runJob(self: Target, job: *Job) Target.Error!Artifact {
        return self.vtable.runJob(self.data, job);
    }

    /// Add a compiled artifact and get its ID.
    pub fn addArtifact(self: Target, artifact: *const anyopaque) Target.Error!ArtifactId {
        return self.vtable.addArtifact(self.data, artifact);
    }

    /// Get an artifact by its ID.
    pub fn getArtifact(self: Target, id: ArtifactId) ?Artifact {
        return self.vtable.getArtifact(self.data, id);
    }

    /// Free a compiled artifact, returning it to the target.
    pub fn freeArtifact(self: Target, id: ArtifactId) void {
        self.vtable.freeArtifact(self.data, id);
    }

    /// Deinitialize the target, freeing all memory it owns.
    pub fn deinit(self: Target, compiler: *Compiler) void {
        self.vtable.deinit(self.data, compiler);
    }

    /// Cast the target to a specific type.
    /// * Does not check the type outside of safe modes
    pub fn forceType(self: Target, comptime T: type) *T {
        std.debug.assert(self.vtable.type_id == pl.TypeId.of(T));
        return @ptrCast(self.data);
    }

    /// Cast the target to a specific type, checking the type at runtime.
    pub fn castType(self: Target, comptime T: type) ?*T {
        if (self.vtable.type_id == pl.TypeId.of(T)) {
            return @ptrCast(self.data);
        } else {
            return null;
        }
    }

    pub const VTable = struct {
        type_id: pl.TypeId,
        runJob: *const fn (self: *anyopaque, job: *Job) Target.Error!Artifact,
        addArtifact: *const fn (self: *anyopaque, artifact: *const anyopaque) Target.Error!ArtifactId,
        getArtifact: *const fn (self: *anyopaque, id: ArtifactId) ?Artifact,
        freeArtifact: *const fn (self: *anyopaque, id: ArtifactId) void,
        deinit: *const fn (self: *anyopaque, compiler: *Compiler) void,

        /// Create a vtable for a specific target type.
        pub fn of(comptime T: type) VTable {
            comptime return .{
                .type_id = pl.TypeId.of(T),
                .runJob = @ptrCast(&T.runJob),
                .addArtifact = @ptrCast(&T.addArtifact),
                .getArtifact = @ptrCast(&T.getArtifact),
                .freeArtifact = @ptrCast(&T.freeArtifact),
                .deinit = @ptrCast(&T.deinit),
            };
        }
    };
};

/// A unique identifier for a captured node within a pattern match.
/// Allows the transformer function to retrieve specific nodes from the matched subgraph.
pub const CaptureId = enum { a, b, c, d, value, condition, address, offset, lhs, rhs };

/// Specifies the arity and operand-matching rules for a `PatternNode`.
pub const MatchCommutativity = enum {
    /// The number of operands must exactly match the pattern's operand list.
    fixed,
    /// The pattern's operands are matched against the node's operands commutatively.
    /// Example: `(i_add ?x, ?y)` will match both `i_add(A, B)` and `i_add(B, A)`.
    commutative,
};

/// Represents a pattern for a single operand (a `ir.Ref`) of an `ir.Node`.
pub const OperandPattern = union(enum) {
    /// Matches any node and does not capture it.
    any,
    /// Matches any node and captures its `ir.Ref` under the given `CaptureId`.
    capture: CaptureId,
    /// Matches a specific, literal `ir.Ref`.
    literal_ref: ir.Ref,
    /// Matches a node whose value is a specific primitive integer.
    /// This is a shortcut for matching a `primitive` node with a specific value.
    literal_primitive: u64,
    /// Matches a node by recursively applying a sub-pattern.
    sub_pattern: *const PatternNode,
    /// An escape hatch for complex checks. Matches if the provided function returns `true`.
    predicate: *const fn (ctx: *ir.Context, ref: ir.Ref) bool,
};

/// A declarative representation of a subgraph within the `ir.Context` to be matched.
pub const PatternNode = struct {
    /// The specific `ir.NodeKind` to match. If null, any kind is matched.
    kind: ?ir.NodeKind = null,

    /// An optional pattern to match against the *type* of the node being evaluated.
    /// This is a powerful constraint, e.g., "match an 'i_add' node *whose result type is i32*".
    type_pattern: ?*const PatternNode = null,

    /// A list of patterns to match against the node's operands (`ref_list`).
    operands: []const OperandPattern = &.{},

    /// The matching strategy for the operands.
    arity: MatchCommutativity = .fixed,
};

const CaptureMap = pl.UniqueReprMap(CaptureId, ir.Ref, 80);

/// Holds the results of a successful pattern match, mapping `CaptureId`s
/// to the `ir.Ref`s they captured from the live IR graph.
pub const MatchResult = struct {
    /// The `ir.Ref` of the root node of the matched subgraph.
    /// This is the node that the `PeepholePattern` will replace.
    root_ref: ir.Ref = ir.Ref.nil,

    /// A map from the capture ID to the `ir.Ref` of the captured node.
    captures: CaptureMap = .{},

    /// Deinitialize the match result, freeing all memory it owns.
    pub fn deinit(self: *MatchResult, allocator: std.mem.Allocator) void {
        self.captures.deinit(allocator);
    }
};

const UseDefMap = pl.UniqueReprMap(ir.Ref, pl.ArrayList(ir.Ref), 80);

/// A safe, high-level API for a transformer function to modify the IR graph.
/// It provides methods to create new nodes and replace the matched subgraph atomically.
pub const PatternBuilder = struct {
    job: *Job,
    match_result: *const MatchResult,

    // NOTE: For this to be efficient, `ir.Node` would ideally have a `uses: ArrayList(ir.Ref)` list.
    // Without it, `replaceUsesOf` requires a full graph scan. For now, we can build this
    // use-def map once at the beginning of the `PeepholePass`.
    use_def_map: *const UseDefMap,

    /// Replaces all uses of one node with another.
    fn replaceUsesOf(self: *PatternBuilder, old_ref: ir.Ref, new_ref: ir.Ref) !void {
        const uses = self.use_def_map.get(old_ref) orelse return;
        for (uses.items) |user_ref| {
            const user_node = self.job.context.getNode(user_ref) orelse continue;

            // This is the tricky part: we need to find `old_ref` in `user_node.bytes.ref_list`
            // and replace it with `new_ref`.
            pl.todo(noreturn, .{ user_node, new_ref });
        }
    }

    /// Atomically replaces the entire matched subgraph (`match_result.root_ref`)
    /// with `new_ref`. This function handles rewiring all uses and marking the old,
    /// now-unreachable nodes for garbage collection.
    pub fn replaceMatch(self: *PatternBuilder, new_ref: ir.Ref) !void {
        try self.replaceUsesOf(self.match_result.root_ref, new_ref);

        // TODO: Add the old root_ref and its (now-unused) children to a "to be deleted" list.
        // The PeepholePass would then run a DeadCodeElimination pass after its main loop.
    }

    // Convenience functions to create new IR nodes
    pub fn createConstant(self: *PatternBuilder, comptime T: type, value: T) !ir.Ref {
        return self.job.context.internPrimitive(value);
    }

    pub fn createInstruction(self: *PatternBuilder, op: ir.Operation, type_ref: ir.Ref, operands: []const ir.Ref) !ir.Ref {
        // TODO: implementation using ir.Context.
        pl.todo(noreturn, .{ self, op, type_ref, operands });
    }
};

/// A complete definition of a peephole optimization: a pattern to find
/// and a transformer function to execute upon a match.
pub const PeepholePattern = struct {
    /// A descriptive name for debugging and logging, e.g., "constant_fold_iadd".
    name: []const u8,

    /// The root of the pattern subgraph to match against the IR.
    match_root: PatternNode,

    /// The function that transforms the IR graph upon a successful match.
    transformer_fn: *const fn (builder: *PatternBuilder, result: *const MatchResult) anyerror!void,
};

/// A generic IR pass that applies a set of `PeepholePattern`s repeatedly
/// until no more changes can be made.
pub const PeepholePass = struct {
    patterns: []const PeepholePattern,

    /// Creates a `backend.Pass` from a slice of patterns.
    pub fn new(patterns: *const []const PeepholePattern) backend.Pass {
        return backend.Pass{
            .name = "peephole_optimizer",
            .data = @ptrCast(patterns),
            .run = &run,
        };
    }

    /// The main execution function for the pass.
    fn run(pass: *backend.Pass, job: *backend.Job) !void {
        const patterns: []const PeepholePattern = @as(*const []const PeepholePattern, @alignCast(@ptrCast(pass.data))).*;
        var changed = true;

        // NOTE: A real implementation would build a use-def map here for efficiency.
        const use_def_map: UseDefMap = undefined;

        while (changed) {
            changed = false;
            var node_it = job.context.nodes.iterator();

            while (node_it.next()) |entry| {
                const current_ref = entry.key_ptr.*;

                for (patterns) |pattern| {
                    var match_result = MatchResult{};
                    defer match_result.deinit(job.root.allocator);

                    if (try PeepholePass.tryMatch(job, &pattern.match_root, current_ref, &match_result)) {
                        var builder = PatternBuilder{
                            .job = job,
                            .match_result = &match_result,
                            .use_def_map = &use_def_map,
                        };
                        try pattern.transformer_fn(&builder, &match_result);
                        changed = true;
                        break;
                    }
                }
                if (changed) break;
            }
        }
    }

    /// Recursively tries to match a `PatternNode` against a live `ir.Ref`.
    fn tryMatch(
        job: *Job,
        pattern: *const PatternNode,
        ref: ir.Ref,
        result: *MatchResult,
    ) !bool {
        const ctx = job.context;

        // 1. Initial Node Validation
        const node = ctx.getNode(ref) orelse return false;
        const node_kind = ref.node_kind;

        // 1a. Match Node Kind
        if (pattern.kind) |pk| {
            if (node_kind != pk) return false;
        }

        // 1b. Match Node Type (Recursive Call)
        if (pattern.type_pattern) |type_pattern| {
            // We need to get the type of the current node. This assumes a convention,
            // for instance that the type is always the first operand of a `structure`
            // node with a kind of `.instruction`
            // This part of the IR design needs to be firm to make this work reliably.
            const node_type_ref = try ctx.getField(ref, .type) orelse return false;

            if (!try tryMatch(job, type_pattern, node_type_ref, result)) {
                return false;
            }
        }

        // 2. Operand Matching
        if (pattern.operands.len > 0) {
            if (node_kind.getTag() != .structure and node_kind.getTag() != .collection) {
                // The pattern expects operands, but the node is a leaf (primitive/data).
                return false;
            }

            const node_operands = node.content.ref_list.items;

            switch (pattern.arity) {
                .fixed => {
                    // 2a. Non-commutative Match
                    if (pattern.operands.len != node_operands.len) return false;

                    for (pattern.operands, 0..) |op_pattern, i| {
                        if (!try tryMatchOperand(job, op_pattern, node_operands[i], result)) {
                            return false;
                        }
                    }
                },
                .commutative => {
                    // 2b. Commutative Match
                    // This is more complex. It requires finding a permutation of `node_operands`
                    // that satisfies the `pattern.operands`.
                    if (pattern.operands.len != node_operands.len) return false;

                    // For simplicity here, we'll sketch a basic algorithm. A real implementation
                    // might need a more optimized one (e.g., bipartite matching).
                    var used_node_operands = std.bit_set.IntegerBitSet(16).initEmpty();

                    outer: for (pattern.operands) |op_pattern| {
                        inner: for (node_operands, 0..) |node_op_ref, i| {
                            // If this node operand has already been matched by another pattern operand, skip.
                            if (used_node_operands.isSet(i)) continue :inner;

                            if (try tryMatchOperand(job, op_pattern, node_op_ref, result)) {
                                // Found a match. Mark this operand as used and move to the next pattern operand.
                                used_node_operands.set(i);
                                continue :outer;
                            }
                        }
                        // If we get here, it means op_pattern found no match among the unused node operands.
                        // The entire match fails.
                        return false;
                    }
                },
            }
        }

        // 3. Success
        // If we've gotten this far, all parts of the pattern have matched.
        return true;
    }

    /// Matches a single `OperandPattern` against a live `ir.Ref`.
    fn tryMatchOperand(
        job: *Job,
        pattern: OperandPattern,
        ref: ir.Ref,
        result: *MatchResult,
    ) anyerror!bool {
        const node_kind = ref.node_kind;
        switch (pattern) {
            .any => return true,
            .capture => |id| {
                // Capture the ref. If the same ID is captured twice with different refs, it's a failure.
                // (e.g., matching `i_add(?x, ?x)` against `i_add(A, B)`).
                if (result.captures.get(id)) |existing_ref| {
                    return existing_ref == ref;
                } else {
                    try result.captures.put(job.root.allocator, id, ref);
                    return true;
                }
            },
            .literal_ref => |lit_ref| {
                return ref == lit_ref;
            },
            .literal_primitive => |lit_val| {
                const node = job.context.getNode(ref) orelse return false;
                if (node_kind.getTag() != .primitive) return false;
                return node.content.primitive == lit_val;
            },
            .sub_pattern => |sub| {
                // Recursive call for nested patterns.
                return tryMatch(job, sub, ref, result);
            },
            .predicate => |pred_fn| {
                return pred_fn(job.context, ref);
            },
        }
    }
};

/// Compilation state for the whole program, kept alive between compilation jobs.
pub const Compiler = struct {
    /// the allocator to use for compiled data
    /// * this can be different from the allocator used for `ir`
    allocator: std.mem.Allocator,
    /// the ir for the whole program compiled thus far
    context: *ir.Context,
    /// the target for this compiler to translate ir into
    target: Target,
    /// state for generating unique job/artifact ids
    fresh_id: ArtifactId = .fromInt(0),

    /// Create an ir compiler instance.
    /// * This will create a new IR context, and use the same allocator for the IR and compiled data.
    /// * The compiler can also be created with `fromContext`, which will use an existing IR context.
    pub fn init(allocator: std.mem.Allocator, comptime TargetType: type) !*Compiler {
        const self = try allocator.create(Compiler);
        errdefer allocator.destroy(self);

        self.* = Compiler{
            .allocator = allocator,
            .context = try ir.Context.init(allocator),
            .target = (try TargetType.init(self)).target(),
        };

        return self;
    }

    /// Create an ir compiler instance from an existing IR context.
    /// * This allows using a different allocator for the compiler instance;
    ///   if one is not provided, the IR context's allocator will be used.
    /// * To create both at once, use `init`.
    pub fn fromContext(context: *ir.Context, allocator: ?std.mem.Allocator, target: Target) !*Compiler {
        const gpa = allocator orelse context.gpa;

        const self = try gpa.create(Compiler);
        errdefer gpa.destroy(self);

        self.* = Compiler{
            .allocator = gpa,
            .context = context,
            .target = target,
        };

        return self;
    }

    /// Deinitialize the compiler, freeing all memory it still owns.
    pub fn deinit(self: *Compiler) void {
        self.context.deinit();
        self.target.deinit(self);
        self.allocator.destroy(self);
    }

    /// Create a new compilation job for the given IR context.
    /// * Actual compilation is done when the job is returned to the compiler.
    pub fn createJob(self: *Compiler) !*Job {
        const root = self.context.getRoot();

        root.mutex.lock();
        defer root.mutex.unlock();

        const ctx = try root.createContext();

        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);

        job.* = Job{
            .id = self.fresh_id.next(),
            .root = self,
            .context = ctx,
        };

        return job;
    }

    /// Compile the given job, returning the resulting artifact.
    pub fn compileJob(self: *Compiler, job: *Job) Target.Error!Artifact {
        std.debug.assert(job.root == self);
        const root = self.context.getRoot();

        root.mutex.lock();
        defer root.mutex.unlock();

        const out = try self.target.runJob(job);

        try root.merge(job.context);

        return out;
    }

    /// Get the target for this compiler, cast to a specific type.
    /// * Does not check the type outside of safe modes.
    pub fn getTarget(self: *Compiler, comptime T: type) *T {
        std.debug.assert(self.target.vtable.type_id == pl.TypeId.of(T));
        return @ptrCast(self.target.data);
    }

    /// Get the target for this compiler, cast to a specific type, checking the type at runtime.
    pub fn castTarget(self: *Compiler, comptime T: type) ?*T {
        if (self.target.vtable.type_id == pl.TypeId.of(T)) {
            return @ptrCast(self.target.data);
        } else {
            return null;
        }
    }

    /// Get a compiled artifact by its ID.
    pub fn getArtifact(self: *Compiler, id: ArtifactId) ?Artifact {
        return self.target.getArtifact(id);
    }

    /// Add a compiled artifact and get its ID.
    pub fn addArtifact(self: *Compiler, artifact: *const anyopaque) Target.Error!ArtifactId {
        return self.target.addArtifact(artifact);
    }

    /// Free a compiled artifact, returning it to the target.
    pub fn freeArtifact(self: *Compiler, id: ArtifactId) void {
        self.target.freeArtifact(id);
    }
};

/// Data local to the compilation of a specific set of values. Created by `Compiler`, reusable.
pub const Job = struct {
    /// The root compiler storing common state between jobs
    root: *Compiler,
    /// Identifies the job, used to ensure that the job is not reused after it has been compiled.
    id: ArtifactId,
    /// The ir segment being compiled
    context: *ir.Context,

    /// Reset the job-local state for the compilation of a new set of values.
    pub fn reset(self: *Job) void {
        self.context.clear();
    }

    /// Cancel the job, deinitializing it and freeing all memory it owns.
    pub fn deinit(self: *Job) void {
        self.context.deinit();
        self.root.allocator.destroy(self);
    }
};

/// The default target for compiling Ribbon IR into bytecode.
pub const BytecodeTarget = struct {
    compiler: *Compiler,
    artifacts: pl.UniqueReprMap(ArtifactId, core.Bytecode, 80) = .{},

    /// Get a `backend.Target` object from this bytecode target.
    pub fn target(self: *BytecodeTarget) Target {
        return Target{
            .data = @ptrCast(self),
            .vtable = comptime &Target.VTable.of(@This()),
        };
    }

    /// Create a new bytecode target for the given compiler.
    pub fn init(compiler: *Compiler) !*BytecodeTarget {
        const self = try compiler.allocator.create(BytecodeTarget);
        errdefer compiler.allocator.destroy(self);

        self.* = BytecodeTarget{ .compiler = compiler };

        return self;
    }

    /// Deinitialize the bytecode target, freeing all memory it owns.
    pub fn deinit(self: *BytecodeTarget, compiler: *Compiler) void {
        compiler.allocator.destroy(self);
    }

    /// Given a compilation job, compile the IR in its context into a bytecode artifact.
    pub fn runJob(self: *BytecodeTarget, job: *Job) Target.Error!Artifact {
        // TODO: Compile the IR context into bytecode.
        const compiled = pl.todo(core.Bytecode, .{job});

        try self.artifacts.put(self.compiler.allocator, job.id, compiled);

        return Artifact{
            .id = job.id,
            .value = @ptrCast(compiled.header),
        };
    }

    /// Add a compiled bytecode artifact and get its ID.
    pub fn addArtifact(self: *BytecodeTarget, artifact: *anyopaque) Target.Error!ArtifactId {
        const compiled: core.Bytecode = .{ .header = @alignCast(@ptrCast(artifact)) };
        const id = self.compiler.fresh_id.next();

        try self.artifacts.put(self.compiler.allocator, id, compiled);

        return id;
    }

    /// Get an artifact by its ID.
    pub fn getArtifact(self: *BytecodeTarget, id: ArtifactId) ?Artifact {
        const compiled = self.artifacts.get(id) orelse return null;

        return Artifact{
            .id = id,
            .value = @ptrCast(compiled.header),
        };
    }

    /// Free compiled bytecode artifacts.
    pub fn freeArtifact(self: *BytecodeTarget, id: ArtifactId) void {
        if (self.artifacts.fetchRemove(id)) |kv| {
            kv.value.deinit(self.compiler.allocator);
        }
    }
};
