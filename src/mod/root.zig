//! The Ribbon Programming Language API.
const ribbon = @This();

pub const core = @import("core");
pub const abi = @import("abi");
pub const bytecode = @import("bytecode");
pub const analysis = @import("analysis");
pub const interpreter = @import("interpreter");
pub const ir = @import("ir");
pub const machine = @import("machine");
pub const meta_language = @import("meta_language");
