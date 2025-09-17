//! The Ribbon Programming Language API.
const ribbon = @This();

const std = @import("std");

test {
    // std.debug.print("semantic analysis for ribbon", .{});
    std.testing.refAllDecls(@This());
}

pub const common = @import("common");
pub const core = @import("core");
pub const abi = @import("abi");
pub const binary = @import("binary");
pub const bytecode = @import("bytecode");
pub const interpreter = @import("interpreter");
pub const ir = @import("ir");
pub const backend = @import("backend");
pub const machine = @import("machine");
pub const meta_language = @import("meta_language");
pub const source = @import("source");
pub const sma = @import("sma");
pub const cbr = @import("cbr");
