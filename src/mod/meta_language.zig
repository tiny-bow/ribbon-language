//! # meta-language
//! The Ribbon Meta Language (Rml) is a compile-time meta-programming language targeting the ribbon virtual machine.
//!
//! While Ribbon does not have a `core.Value` sum type, Rml does have such a type,
//! and it is used to represent both source code and user data structures.
//!
//! The main focal point of Rml is the `Compiler` struct, which is used to
//! compile raw text or syntax into Rir.
const meta_language = @This();

const std = @import("std");
const log = std.log.scoped(.Rml);

const pl = @import("platform");

test {
    std.testing.refAllDeclsRecursive(@This());
}
