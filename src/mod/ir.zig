//! # ir
//! This namespace provides a mid-level hybrid SSA Intermediate Representation (ir) for Ribbon.
//!
//! It is used to represent the program in a way that is easy to optimize and transform.
//!
//! This ir targets:
//! * rvm's core bytecode (via the `bytecode` module)
//! * native machine code, in two ways:
//!    + in house x64 jit (the `machine` module)
//!    + freestanding (eventually)
const ir = @This();

const std = @import("std");
const log = std.log.scoped(.Rir);

const core = @import("core");
const common = @import("common");
const analysis = @import("analysis");
const bytecode = @import("bytecode");

test {
    // std.debug.print("semantic analysis for ir\n", .{});
    std.testing.refAllDeclsRecursive(@This());
}

pub const terms = @import("ir/terms.zig");
pub const Sma = @import("ir/Sma.zig");
pub const Context = @import("ir/Context.zig");
pub const Term = @import("ir/Term.zig").Term;
pub const Blob = @import("ir/Blob.zig");
pub const Module = @import("ir/Module.zig");
pub const HandlerSet = @import("ir/HandlerSet.zig");
pub const Expression = @import("ir/Expression.zig");
pub const Function = @import("ir/Function.zig");
pub const Block = @import("ir/Block.zig");
pub const Global = @import("ir/Global.zig");
pub const Instruction = @import("ir/Instruction.zig");

/// A reference to an interned symbolic name within the ir context.
pub const Name = struct {
    /// Identifier for a symbolic name within the ir context.
    pub const Id = enum(u32) { _ };

    value: []const u8,
};

/// Canonical Binary Representation (CBR) 16-byte hash type.
pub const Cbr = enum(u128) {
    _,

    /// A hasher for computing canonical binary representation (CBR) hashes.
    pub const Hasher = struct {
        blake: std.crypto.hash.Blake3,

        /// Initialize a new Cbr.Hasher.
        pub fn init() Cbr.Hasher {
            return Cbr.Hasher{
                .blake = std.crypto.hash.Blake3.init(.{}),
            };
        }

        /// Update the hasher with the given value converted to bytes.
        pub inline fn update(self: *Cbr.Hasher, value: anytype) void {
            const T_info = @typeInfo(@TypeOf(value));
            if (comptime T_info == .pointer) {
                if (comptime T_info.pointer.child == u8) {
                    if (comptime T_info.pointer.size == .slice) {
                        self.blake.update(value);
                    } else if (comptime T_info.pointer.size != .one) {
                        self.blake.update(std.mem.span(value));
                    } else {
                        self.blake.update(std.mem.asBytes(value));
                    }
                } else {
                    self.blake.update(std.mem.asBytes(value));
                }
            } else {
                self.blake.update(std.mem.asBytes(&value));
            }
        }

        /// Finalize the hasher and return the resulting value.
        pub fn final(self: *Cbr.Hasher) Cbr {
            var out: Cbr = @enumFromInt(0);
            self.blake.final(std.mem.asBytes(&out));
            return out;
        }
    };
};

/// Wrapper for Fnv1a_64 hasher for quick hashing needs.
pub const QuickHasher = struct {
    fnv: std.hash.Fnv1a_64,

    /// Initialize a new QuickHasher.
    pub fn init() QuickHasher {
        return QuickHasher{
            .fnv = std.hash.Fnv1a_64.init(),
        };
    }

    /// Update the hasher with the given value converted to bytes.
    pub inline fn update(self: *QuickHasher, value: anytype) void {
        const T_info = @typeInfo(@TypeOf(value));
        if (comptime T_info == .pointer) {
            if (comptime T_info.pointer.child == u8) {
                if (comptime T_info.pointer.size == .slice) {
                    self.fnv.update(value);
                } else if (comptime T_info.pointer.size != .one) {
                    self.fnv.update(std.mem.span(value));
                } else {
                    self.fnv.update(std.mem.asBytes(value));
                }
            } else {
                self.fnv.update(std.mem.asBytes(value));
            }
        } else {
            self.fnv.update(std.mem.asBytes(&value));
        }
    }

    /// Finalize the hasher and return the resulting hash value.
    pub fn final(self: *QuickHasher) u64 {
        return self.fnv.final();
    }
};
