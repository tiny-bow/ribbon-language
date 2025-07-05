//! Backend compiling Ribbon IR.

const backend = @This();

const std = @import("std");
const pl = @import("platform");
const ir = @import("ir");
const core = @import("core");
const bytecode = @import("bytecode");
const Id = @import("Id");

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub const Artifact = packed struct {
    target: Target,
    value: *anyopaque,

    /// Free the artifact, returning it to the target.
    pub fn deinit(self: Artifact) void {
        self.target.freeArtifact(self);
    }
};

pub const Target = packed struct {
    data: *anyopaque,
    vtable: *const VTable,

    pub const Error = anyerror;

    pub fn runJob(self: Target, job: *Job) Target.Error!Artifact {
        return @call(.auto, self.vtable.runJob, .{ self.data, job });
    }

    pub fn freeArtifact(self: Target, artifact: Artifact) void {
        @call(.auto, self.vtable.freeArtifact, .{ self.data, artifact });
    }

    pub fn deinit(self: Target, compiler: *Compiler) void {
        @call(.auto, self.vtable.deinit, .{ self.data, compiler });
    }

    pub const VTable = struct {
        runJob: *const fn (self: *anyopaque, job: *Job) Target.Error!Artifact,
        freeArtifact: *const fn (self: *anyopaque, artifact: Artifact) void,
        deinit: *const fn (self: *anyopaque, compiler: *Compiler) void,
    };
};

/// The default target for compiling Ribbon IR into bytecode.
pub const BytecodeTarget = struct {
    /// Addresses of bytecode values already compiled.
    table: bytecode.Table = .{},

    /// Get a `backend.Target` object from this bytecode target.
    pub fn target(self: *BytecodeTarget) Target {
        return Target{
            .data = @ptrCast(self),
            .vtable = &.{
                .runJob = @ptrCast(&runJob),
                .freeArtifact = @ptrCast(&freeArtifact),
                .deinit = @ptrCast(&deinit),
            },
        };
    }

    /// Create a new bytecode target for the given compiler.
    pub fn init(compiler: *Compiler) !*BytecodeTarget {
        const self = try compiler.allocator.create(BytecodeTarget);
        errdefer compiler.allocator.destroy(self);

        self.* = BytecodeTarget{};

        return self;
    }

    /// Deinitialize the bytecode target, freeing all memory it owns.
    pub fn deinit(self: *BytecodeTarget, compiler: *Compiler) void {
        self.table.deinit(compiler.allocator);
        compiler.allocator.destroy(self);
    }

    /// Given a compilation job, compile the IR in its context into a bytecode artifact.
    pub fn runJob(self: *BytecodeTarget, job: *Job) Target.Error!Artifact {
        // Compile the IR context into bytecode.
        // TODO: ...
        const compiled = pl.todo(*core.Bytecode, .{job});

        // Create an artifact to return.
        return Artifact{
            .target = self.target(),
            .value = @ptrCast(compiled),
        };
    }

    /// Free compiled bytecode artifacts.
    pub fn freeArtifact(self: *BytecodeTarget, artifact: Artifact) void {
        // Free the target-specific data at the opaque pointer in the artifact.
        std.debug.assert(artifact.target == self.target());
        // TODO: ...
        pl.todo(noreturn, .{});
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
        const ctx = try self.context.getRoot().createContext();

        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);

        job.* = Job{
            .root = self,
            .context = ctx,
        };

        return job;
    }

    /// Compile the given job, returning the resulting artifact.
    pub fn compileJob(self: *Compiler, job: *Job) Target.Error!Artifact {
        std.debug.assert(job.root == self);

        const out = try self.target.runJob(job);

        // TODO: merge the job's context into the compiler state.
        // we do this when the job succeeds, so that the compiler state is a record of what was compiled.
        // hurdles:
        // * no ir merge function as of now
        // * jobs may use a different allocator than the compiler
        // * the job context may reference values in the compiler's context (?)

        return out;
    }
};

/// Data local to the compilation of a specific set of values. Created by `Compiler`, reusable.
pub const Job = struct {
    /// The root compiler storing common state between jobs
    root: *Compiler,
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
