const std = @import("std");
const MiscUtils = @import("Utils").Misc;
const RbcCore = @import("Rbc:Core");
const RbcBuilder = @import("Rbc:Builder");

const Rir = @import("Rir");

const RbcGenerator = @This();


allocator: std.mem.Allocator,
bytecode: RbcBuilder,
ir: *Rir,
global_lookup: std.ArrayHashMapUnmanaged(Rir.Ref(Rir.GlobalId), RbcCore.GlobalIndex, MiscUtils.SimpleHashContext, false) = .{},
function_lookup: std.ArrayHashMapUnmanaged(Rir.Ref(Rir.FunctionId), RbcCore.FunctionIndex, MiscUtils.SimpleHashContext, false) = .{},


/// Allocator provided should be an arena or a similar allocator,
/// that does not care about freeing individual allocations
pub fn init(allocator: std.mem.Allocator, ir: *Rir) !RbcGenerator {
    return RbcGenerator {
        .allocator = allocator,
        .bytecode = try RbcBuilder.init(allocator),
        .ir = ir,
    };
}


test {
    std.testing.refAllDeclsRecursive(RbcGenerator);
}
