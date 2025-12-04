//! The Ribbon Programming Language API.
const ribbon = @This();

const std = @import("std");

test {
    // std.debug.print("semantic analysis for ribbon", .{});
    std.testing.refAllDecls(@This());
}

pub const abi = @import("abi");
pub const analysis = @import("analysis");
pub const backend = @import("backend");
pub const binary = @import("binary");
pub const bytecode = @import("bytecode");
pub const common = @import("common");
pub const core = @import("core");
pub const interpreter = @import("interpreter");
pub const ir = @import("ir");
pub const machine = @import("machine");
pub const meta_language = @import("meta_language");
pub const orchestration = @import("orchestration");
pub const frontend = @import("frontend");
