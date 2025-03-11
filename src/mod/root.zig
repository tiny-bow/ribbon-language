//! The Ribbon Programming Language API.
const ribbon = @This();

pub const bytecode = @import("bytecode");
pub const common = @import("common");
pub const core = @import("core");
pub const interpreter = @import("interpreter");
pub const ir = @import("ir");
pub const machine = @import("jit/X64");
pub const meta_language = @import("meta_language");
pub const platform = @import("platform");
