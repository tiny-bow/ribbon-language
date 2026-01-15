const orchestration = @This();

const std = @import("std");
const log = std.log.scoped(.orchestration);

const common = @import("common");
const core = @import("core");
const ir = @import("ir");
const frontend = @import("frontend");

test {
    //std.debug.print("semantic analysis for orchestration\n", .{});
    std.testing.refAllDecls(@This());
}
