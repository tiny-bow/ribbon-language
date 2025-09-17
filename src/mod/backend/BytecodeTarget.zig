//! The default target for compiling Ribbon IR into bytecode.

const BytecodeTarget = @This();

const std = @import("std");
const log = std.log.scoped(.backed_bytecode_target);

const core = @import("core");
const common = @import("common");
const ir = @import("ir");

const backend = @import("../backend.zig");

test {
    // std.debug.print("semantic analysis for bytecode target\n", .{});
    std.testing.refAllDecls(@This());
}

/// The service that owns this target.
service: *backend.Service,
/// The list of optimization passes to run on each Job.
passes: common.ArrayList(backend.Pass) = .empty,
/// The compiled artifacts, mapped by their ID.
artifacts: common.UniqueReprMap(backend.ArtifactId, *core.Bytecode) = .empty,

/// Create a new bytecode target for the given service.
pub fn init(service: *backend.Service) !backend.Target {
    const self = try service.allocator.create(BytecodeTarget);
    errdefer service.allocator.destroy(self);

    self.* = BytecodeTarget{
        .service = service,
    };

    return backend.Target{
        .data = @ptrCast(self),
        .vtable = comptime &backend.Target.VTable.of(@This()),
    };
}

/// Deinitialize the bytecode target, freeing all memory it owns.
pub fn deinit(self: *BytecodeTarget, service: *backend.Service) void {
    var it = self.artifacts.valueIterator();
    while (it.next()) |p2p| {
        p2p.*.deinit(service.allocator);
    }
    self.artifacts.deinit(service.allocator);

    for (self.passes.items) |pass| {
        pass.deinit(service.allocator);
    }
    self.passes.deinit(service.allocator);

    service.allocator.destroy(self);
}

/// Add a transformer Pass to be run on each Job before lowering.
/// * Takes ownership of the Pass.
pub fn addPass(self: *BytecodeTarget, pass: backend.Pass) backend.Target.Error!void {
    try self.passes.append(self.service.allocator, pass);
}

/// Given a compilation job, compile the IR in its context into a bytecode artifact.
pub fn runJob(self: *BytecodeTarget, job: *backend.Job) backend.Target.Error!backend.Artifact {
    // Run all transformation passes on the job, until a fixpoint is reached.
    _ = try backend.Pass.runAllFixpoint(self.passes.items, job);

    const compiled = try lowerToBytecode(job);

    try self.artifacts.put(self.service.allocator, job.id, compiled);

    return backend.Artifact{
        .id = job.id,
        .value = @ptrCast(compiled),
    };
}

/// Add a compiled bytecode artifact and get its ID.
pub fn addArtifact(self: *BytecodeTarget, artifact: *anyopaque) backend.Target.Error!backend.ArtifactId {
    const compiled: *core.Bytecode = @ptrCast(@alignCast(artifact));
    const id = self.service.fresh_id.next();

    try self.artifacts.put(self.service.allocator, id, compiled);

    return id;
}

/// Get an artifact by its ID.
pub fn getArtifact(self: *BytecodeTarget, id: backend.ArtifactId) ?backend.Artifact {
    const compiled = self.artifacts.get(id) orelse return null;

    return backend.Artifact{
        .id = id,
        .value = @ptrCast(compiled),
    };
}

/// Free compiled bytecode artifacts.
pub fn freeArtifact(self: *BytecodeTarget, id: backend.ArtifactId) void {
    if (self.artifacts.fetchRemove(id)) |kv| {
        kv.value.deinit(self.service.allocator);
    }
}

/// TODO: final translation from IR to bytecode
pub fn lowerToBytecode(job: *backend.Job) backend.Target.Error!*core.Bytecode {
    return common.todo(*core.Bytecode, .{job});
}
