const Rbc = @import("../Rbc.zig");

pub const Set = []const Binding;

pub const Binding = struct {
    id: Rbc.EvidenceIndex,
    handler: Rbc.FunctionIndex,
};
