//! Backend compiling Ribbon IR.

const backend = @This();

const std = @import("std");
const ir = @import("ir");
const core = @import("core");
const bytecode = @import("bytecode");
const common = @import("common");
const Id = common.Id;

pub const PeepholePass = @import("backend/PeepholePass.zig");
pub const BytecodeTarget = @import("backend/BytecodeTarget.zig");
pub const Job = @import("backend/Job.zig");
pub const Service = @import("backend/Service.zig");

test {
    // std.debug.print("semantic analysis for backend\n", .{});
    std.testing.refAllDecls(@This());
}

pub const ArtifactId = Id.of(core.ForeignAddressId, 64);

pub const Artifact = packed struct {
    id: ArtifactId,
    value: *const anyopaque,
};

/// A ir transformer pass, which can be registered with a Target to transform Jobs before they are lowered.
pub const Pass = struct {
    data: ?*const anyopaque = null,
    vtable: *const VTable,

    pub const Error = anyerror;

    /// Run the pass on the given job.
    pub fn run(self: Pass, job: *Job) Error!void {
        if (self.data) |data| {
            return self.vtable.run(data, job);
        } else {
            return error.InvalidPass;
        }
    }

    /// Deinitialize the pass, freeing all memory it owns.
    pub fn deinit(self: Pass, allocator: std.mem.Allocator) void {
        if (self.data) |data| {
            self.vtable.deinit(data, allocator);
        }
    }

    /// The vtable supplied by a Pass's actual implementation.
    pub const VTable = struct {
        run: *const fn (self: *const anyopaque, job: *Job) Pass.Error!void,
        deinit: *const fn (self: *const anyopaque, allocator: std.mem.Allocator) void,

        pub fn of(comptime T: type) VTable {
            comptime return .{
                .run = @ptrCast(&T.run),
                .deinit = @ptrCast(&T.deinit),
            };
        }
    };

    /// Run all passes in a set once.
    /// * Return value indicates if any changes were made.
    pub fn runAll(passes: []const Pass, job: *Job) Error!bool {
        var changed = false;

        for (passes) |pass| {
            try pass.run(job);
            changed = common.todo(bool, .{}) or changed; // TODO: ir facilities to detect changes
        }

        return changed;
    }

    /// Run all passes in a set until a fixpoint is reached.
    /// * Return value indicates if any changes were made.
    pub fn runAllFixpoint(passes: []const Pass, job: *Job) Error!bool {
        var changed = true;

        while (changed) {
            changed = try runAll(passes, job);
        }

        return changed;
    }
};

/// Target abstraction for Service backends.
pub const Target = packed struct {
    data: *anyopaque,
    vtable: *const VTable,

    pub const Error = Pass.Error;

    /// Add a Pass to this Target.
    /// * Takes ownership of the Pass.
    pub fn addPass(self: *Target, pass: Pass) Target.Error!void {
        return self.vtable.addPass(self.data, pass);
    }

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
    pub fn deinit(self: Target, service: *Service) void {
        self.vtable.deinit(self.data, service);
    }

    /// Cast the target to a specific type.
    /// * Does not check the type outside of safe modes
    pub fn forceType(self: Target, comptime T: type) *T {
        std.debug.assert(self.vtable.type_name == @typeName(T));
        return @ptrCast(self.data);
    }

    /// Cast the target to a specific type, checking the type at runtime.
    pub fn castType(self: Target, comptime T: type) ?*T {
        if (self.vtable.type_name == @typeName(T)) {
            return @ptrCast(self.data);
        } else {
            return null;
        }
    }

    /// The vtable supplied by a Target's actual implementation.
    pub const VTable = struct {
        type_name: []const u8,
        runJob: *const fn (self: *anyopaque, job: *Job) Target.Error!Artifact,
        addPass: *const fn (self: *anyopaque, pass: Pass) Target.Error!void,
        addArtifact: *const fn (self: *anyopaque, artifact: *const anyopaque) Target.Error!ArtifactId,
        getArtifact: *const fn (self: *anyopaque, id: ArtifactId) ?Artifact,
        freeArtifact: *const fn (self: *anyopaque, id: ArtifactId) void,
        deinit: *const fn (self: *anyopaque, service: *Service) void,

        /// Create a vtable for a specific target type.
        pub fn of(comptime T: type) VTable {
            comptime return .{
                .type_name = @typeName(T),
                .runJob = @ptrCast(&T.runJob),
                .addPass = @ptrCast(&T.addPass),
                .addArtifact = @ptrCast(&T.addArtifact),
                .getArtifact = @ptrCast(&T.getArtifact),
                .freeArtifact = @ptrCast(&T.freeArtifact),
                .deinit = @ptrCast(&T.deinit),
            };
        }
    };
};
