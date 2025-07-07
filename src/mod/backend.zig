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

pub const ArtifactId = Id.of(core.ForeignAddressId, 64);

pub const Artifact = packed struct {
    id: ArtifactId,
    value: *const anyopaque,
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
            kv.value.deinit();
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
