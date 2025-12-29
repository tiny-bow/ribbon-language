//! This module provides a Just-In-Time (JIT) compiler and other utilities for the host architecture, (aarch64 in this case),
//! enabling dynamic generation and execution of machine code. Parts of this module are specialized
//! for use with `core`, while others are more general-purpose architecture-related items.
//!
//! This module serves as both the primary data structure and interface for the Builder,
//! as well as the namespace for supporting functions, types, etc.
//! A simple machine code disassembler is also provided here.
//!
//! ## Usage
//! Todo
const machine = @This();

const std = @import("std");
const log = std.log.scoped(.AArch64Builder);

const common = @import("common");
const core = @import("core");
const VirtualWriter = @import("common").VirtualWriter;

test {
    // std.debug.print("semantic analysis for aarch64/machine\n", .{});
    std.testing.refAllDeclsRecursive(@This());
}

const abi = @import("abi");
