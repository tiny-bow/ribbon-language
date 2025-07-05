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

pub const Artifact = struct {
    target: Target,
    value: *anyopaque,

    /// Free the artifact, returning it to the target.
    pub fn deinit(self: Artifact) void {
        self.target.freeArtifact(self);
    }
};

pub const Target = packed struct {
    data: *anyopaque,
    vtable: *VTable,

    pub const Error = anyerror;

    pub fn runJob(self: Target, job: *Job) Target.Error!Artifact {
        return @call(.auto, self.vtable.runJob, .{ self.data, job });
    }

    pub fn freeArtifact(self: Target, artifact: Artifact) void {
        @call(.auto, self.vtable.freeArtifact, .{ self.data, artifact });
    }

    pub const VTable = struct {
        runJob: *const fn (self: *const anyopaque, job: *Job) Target.Error!Artifact,
        freeArtifact: *const fn (self: *const anyopaque, artifact: Artifact) void,
    };
};

/// The default target for compiling Ribbon IR into bytecode.
pub const BytecodeTarget = struct {
    /// Addresses of bytecode values already compiled.
    table: bytecode.Table,

    /// Get a `backend.Target` object from this bytecode target.
    pub fn target(self: *BytecodeTarget) Target {
        return Target{
            .data = self,
            .vtable = &.{
                .runJob = @ptrCast(&runJob),
                .freeArtifact = @ptrCast(&freeArtifact),
            },
        };
    }

    /// Given a compilation job, compile the IR in its context into a bytecode artifact.
    pub fn runJob(self: *const BytecodeTarget, job: *Job) Target.Error!Artifact {
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
    pub fn freeArtifact(self: *const BytecodeTarget, artifact: Artifact) void {
        // TODO: ...
        pl.todo(noreturn, .{ self, artifact });
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
    pub fn init(allocator: std.mem.Allocator) !*Compiler {
        const self = try allocator.create(Compiler);
        errdefer allocator.destroy(self);

        self.* = Compiler{
            .allocator = allocator,
            .context = try ir.Context.init(allocator),
            .table = .{},
        };

        return self;
    }

    /// Create an ir compiler instance from an existing IR context.
    /// * This allows using a different allocator for the compiler instance;
    ///   if one is not provided, the IR context's allocator will be used.
    /// * To create both at once, use `init`.
    pub fn fromContext(context: *ir.Context, allocator: ?std.mem.Allocator) !*Compiler {
        const gpa = allocator orelse context.gpa;

        const self = try gpa.create(Compiler);
        errdefer gpa.destroy(self);

        self.* = Compiler{
            .allocator = gpa,
            .context = context,
            .table = .{},
        };

        return self;
    }

    /// Deinitialize the compiler, freeing all memory it still owns.
    pub fn deinit(self: *Compiler) void {
        self.context.deinit();
        self.table.deinit(self.allocator);
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
            .table = .{},
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
        self.table.clear();
        self.context.clear();
    }

    /// Cancel the job, deinitializing it and freeing all memory it owns.
    pub fn deinit(self: *Job) void {
        self.table.deinit(self.root.allocator);
        self.context.deinit();
        self.root.allocator.destroy(self);
    }
};
