//! Backend service for compiling Ribbon IR.

const Service = @This();

const std = @import("std");
const log = std.log.scoped(.backend_service);

const core = @import("core");
const common = @import("common");
const ir = @import("ir");

const backend = @import("../backend.zig");

test {
    // std.debug.print("semantic analysis for backend service\n", .{});
    std.testing.refAllDecls(@This());
}

/// the allocator to use for compiled data
allocator: std.mem.Allocator,
/// the ir for the whole program compiled thus far
context: *ir.Context,
/// the target for this service to translate ir into
target: backend.Target,
/// state for generating unique job/artifact ids
fresh_id: backend.ArtifactId = .fromInt(0),

/// Create an ir service instance.
/// * This will create a new IR context, and use the same allocator for the IR and compiled data.
/// * The service can also be created with `fromContext`, which will use an existing IR context.
/// * Note that the allocator used by Service must be thread-safe.
pub fn init(allocator: std.mem.Allocator, comptime TargetType: type) !*Service {
    const self = try allocator.create(Service);
    errdefer allocator.destroy(self);

    self.* = Service{
        .allocator = allocator,
        .context = try ir.Context.init(allocator),
        .target = (try TargetType.init(self)).target(),
    };

    return self;
}

// /// Create an ir service instance from an existing IR context.
// /// * This allows using a different allocator for the service instance;
// ///   if one is not provided, the IR context's allocator will be used.
// /// * To create both at once, use `init`.
// /// * Note that the allocator used by Service must be thread-safe.
// pub fn fromContext(context: *ir.Context, allocator: ?std.mem.Allocator, target: backend.Target) !*Service {
//     // const gpa = allocator orelse context.gpa;

//     // const self = try gpa.create(Service);
//     // errdefer gpa.destroy(self);

//     // self.* = Service{
//     //     .allocator = gpa,
//     //     .context = context,
//     //     .target = target,
//     // };

//     // return self;
// }

/// Deinitialize the service, freeing all memory it still owns.
pub fn deinit(self: *Service) void {
    self.context.deinit();
    self.target.deinit(self);
    self.allocator.destroy(self);
}

/// Create a new compilation job for the given IR context.
/// * Actual compilation is done when the job is returned to the service.
pub fn createJob(self: *Service) !*backend.Job {
    // const root = self.context.getRoot();

    // root.mutex.lock();
    // defer root.mutex.unlock();

    // const ctx = try root.createContext();

    const job = try self.allocator.create(backend.Job);
    errdefer self.allocator.destroy(job);

    // job.* = backend.Job{
    //     .id = self.fresh_id.next(),
    //     .root = self,
    //     .context = ctx,
    // };

    return job;
}

/// Compile the given job, returning the resulting artifact.
/// * Destroys the job and frees all memory it owns.
pub fn compileJob(self: *Service, job: *backend.Job) backend.Target.Error!backend.Artifact {
    std.debug.assert(job.root == self);
    defer job.deinit();

    // const root = self.context.getRoot();

    // root.mutex.lock();
    // defer root.mutex.unlock();

    const out = try self.target.runJob(job);

    // try root.merge(job.context);

    return out;
}

/// Get the target for this service, cast to a specific type.
/// * Does not check the type outside of safe modes.
pub fn getTarget(self: *Service, comptime T: type) *T {
    std.debug.assert(self.target.vtable.type_name == @typeName(T));
    return @ptrCast(self.target.data);
}

/// Get the target for this service, cast to a specific type, checking the type at runtime.
pub fn castTarget(self: *Service, comptime T: type) ?*T {
    if (self.target.vtable.type_name == @typeName(T)) {
        return @ptrCast(self.target.data);
    } else {
        return null;
    }
}

/// Get a compiled artifact by its ID.
pub fn getArtifact(self: *Service, id: backend.ArtifactId) ?backend.Artifact {
    return self.target.getArtifact(id);
}

/// Add a compiled artifact and get its ID.
pub fn addArtifact(self: *Service, artifact: *const anyopaque) backend.Target.Error!backend.ArtifactId {
    return self.target.addArtifact(artifact);
}

/// Free a compiled artifact, returning it to the target.
pub fn freeArtifact(self: *Service, id: backend.ArtifactId) void {
    self.target.freeArtifact(id);
}
