//! Backend compiling Ribbon IR to Ribbon bytecode.

const ir2bc = @This();

const std = @import("std");
const pl = @import("platform");
const ir = @import("ir");
const core = @import("core");
const bytecode = @import("bytecode");
const Id = @import("Id");

test {
    std.testing.refAllDeclsRecursive(@This());
}

/// Compilation state for the whole program, kept alive between compilation jobs.
pub const Compiler = struct {
    /// the allocator to use for compiled data
    /// * this can be different from the allocator used for `ir`
    allocator: std.mem.Allocator,
    /// the ir for the whole program compiled thus far
    context: *ir.Context,
    /// table for the whole program compiled thus far
    table: bytecode.Table,

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
    /// if one is not provided, the IR context's allocator will be used.
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
    /// * It is possible to pass an existing IR context, which will be used for the job,
    ///   but typical usage patterns should pass null here to create a new one.
    pub fn createJob(self: *Compiler, context: ?*ir.Context) !*Job {
        const ctx = if (context) |ctx| existing: {
            std.debug.assert(!ctx.isRoot() and ctx.getRootContext() == self.context);
            break :existing ctx;
        } else try self.context.getRoot().createContext();

        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);

        job.* = Job{
            .root = self,
            .context = ctx,
            .table = .{},
        };

        return job;
    }

    /// Compile the given job, returning the resulting bytecode blob.
    pub fn compileJob(self: *Compiler, job: *Job) !core.Bytecode {
        std.debug.assert(job.root == self);

        var virtual_writer = try bytecode.Writer.init();
        errdefer virtual_writer.deinit();

        pl.todo(noreturn, .{ self });
    }
};

/// Data local to the compilation of a specific set of values. Created by `Compiler`, reusable.
pub const Job = struct {
    /// The root compiler storing common state between jobs
    root: *Compiler,
    /// The ir segment being compiled
    context: *ir.Context,
    /// Local table for symbols being compiled
    table: bytecode.Table,

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
