const std = @import("std");
const common = @import("common");

const ir = @import("../ir.zig");

/// A type erased, tagged pointer to a term value in an ir context.
/// Terms represent types and other compile time expressions in the ir.
pub const Term = packed struct(u64) {
    /// The tag identifying the term's type.
    tag: Term.Tag,
    /// The offset (backwards) from the term's value pointer to its header.
    header_offset: u8,
    /// Address of the term's value.
    ptr: u48,

    /// Unique identifier for a Term within its context.
    pub const Id = enum(u32) { _ };

    /// Identifier for a type of term within the IR term type registry
    pub const Tag = enum(u8) { _ };

    /// Description of a type erased term in the ir context.
    pub const Header = struct {
        /// The root context for this term.
        root: *ir.Context,
        /// The module this term belongs to, if any.
        module: ?*ir.Module,
        /// The tag identifying the term's type.
        tag: Term.Tag,
        /// The offset (forwards) from the header to the term value.
        value_offset: u8,
        /// Unique identifier for this term within its context.
        id: Term.Id,
        /// The cached CBR for the attached term.
        cached_cbr: ?ir.Cbr = null,

        /// Get the parent Data pair containing this header.
        fn toData(self: *Term.Header, comptime T: type) error{ZigTypeMismatch}!*Term.Data(T) {
            if (self.tag != self.root.tagFromType(T)) return error.ZigTypeMismatch;
            return @fieldParentPtr("header", self);
        }

        /// Get the Term for this header.
        fn toTerm(self: *Term.Header) Term {
            return .{
                .tag = self.tag,
                .header_offset = self.value_offset,
                .ptr = @intFromPtr(self) + self.value_offset,
            };
        }

        /// Get a typed pointer to the term value.
        fn toTermPtr(self: *Term.Header, comptime T: type) error{ZigTypeMismatch}!*T {
            return &(try self.toData(T)).value;
        }

        /// Get an opaque pointer to the term value.
        fn toOpaqueTermAddress(self: *Term.Header) *anyopaque {
            return @ptrFromInt(@intFromPtr(self) + self.value_offset);
        }

        /// Get a Term.Header from a term value.
        fn fromTerm(term: Term) *Term.Header {
            return term.toHeader();
        }

        /// Get a Term.Header from a typed pointer to a term value.
        fn fromTermPtr(ptr: anytype) *Term.Header {
            const data: *Term.Data(@typeInfo(@TypeOf(ptr)).pointer.child) = @fieldParentPtr("value", ptr);
            return &data.header;
        }

        /// Get the CBR for the attached term.
        fn getCbr(self: *Term.Header) ir.Cbr {
            if (self.cached_cbr) |cached| {
                return cached;
            }

            const new_hash = self.root.vtables.get(self.tag).?.cbr(self.toOpaqueTermAddress());
            self.cached_cbr = new_hash;
            return new_hash;
        }

        /// Write the term in SMA format to the given writer.
        fn writeSma(self: *Term.Header, writer: *std.io.Writer) error{WriteFailed}!void {
            try writer.writeInt(u8, @intFromEnum(self.tag), .little);
            try self.root.vtables.get(self.tag).?.writeSma(self.toOpaqueTermAddress(), self.root, writer);
        }
    };

    /// A vtable of functions for type erased term operations.
    pub const VTable = struct {
        name: []const u8,
        eql: *const fn (*const anyopaque, *const anyopaque) bool,
        hash: *const fn (*const anyopaque, *ir.QuickHasher) void,
        cbr: *const fn (*const anyopaque) ir.Cbr,
        dehydrate: *const fn (*const anyopaque, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{OutOfMemory}!void,
        rehydrate: *const fn (*const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *anyopaque) error{ BadEncoding, OutOfMemory }!void,
    };

    /// A pair of a Term.Header and a value of type T. Defines the storage layout for Term objects.
    pub fn Data(comptime T: type) type {
        return struct {
            const Self = @This();

            header: Term.Header,
            value: T,

            fn allocate(context: *ir.Context, module: ?*ir.Module) error{ ZigTypeNotRegistered, OutOfMemory }!*T {
                const self = try context.arena.allocator().create(Self);
                self.header = .{
                    .root = context,
                    .module = module,
                    .tag = context.tagFromType(T) orelse return error.ZigTypeNotRegistered,
                    .value_offset = @offsetOf(Self, "value"),
                    .id = context.generateTermId(),
                };
                return &self.value;
            }
        };
    }

    /// Create a term from a typed pointer to its value.
    fn fromPtr(context: *ir.Context, ptr: anytype) error{ZigTypeMismatch}!Term {
        const T = @typeInfo(@TypeOf(ptr)).pointer.child;
        return .{
            .tag = context.tagFromType(T) orelse return error.ZigTypeMismatch,
            // we need the offset of value so that we can subtract it to get header
            .header_offset = @offsetOf(Data(T), "value"),
            .ptr = @intCast(@intFromPtr(ptr)),
        };
    }

    /// Get a typed pointer to the term's value.
    pub fn toMutPtr(self: Term, context: *const ir.Context, comptime T: type) error{ZigTypeMismatch}!*T {
        if (self.tag != context.tagFromType(T)) return error.ZigTypeMismatch;
        return @ptrFromInt(self.ptr);
    }

    /// Get an immutable, type checked pointer to the term's value.
    pub fn toPtr(self: Term, context: *const ir.Context, comptime T: type) error{ZigTypeMismatch}!*const T {
        if (self.tag != context.tagFromType(T)) return error.ZigTypeMismatch;
        return @ptrFromInt(self.ptr);
    }

    /// Get an opaque pointer to the term's value.
    pub fn toOpaquePtr(self: Term) *anyopaque {
        return @ptrFromInt(self.ptr);
    }

    /// Get the Term.Header for this term.
    fn toHeader(self: Term) *Term.Header {
        return @ptrFromInt(self.ptr - self.header_offset);
    }

    /// Get the root context for this term.
    pub fn toRoot(self: Term) *ir.Context {
        return self.toHeader().root;
    }

    /// Get the module this term belongs to, if any.
    pub fn toModule(self: Term) ?*ir.Module {
        return self.toHeader().module;
    }

    /// Get the Data for this term.
    fn toData(self: Term, comptime T: type) error{ZigTypeMismatch}!*Term.Data(T) {
        return self.toHeader().toData();
    }

    /// Get the CBR for this term.
    pub fn getCbr(self: Term) ir.Cbr {
        return self.toHeader().getCbr();
    }

    /// Get the unique id for this term within its context.
    pub fn getId(self: Term) Term.Id {
        return self.toHeader().id;
    }

    /// Write the term in SMA format to the given writer.
    fn writeSma(self: Term, writer: *std.io.Writer) error{WriteFailed}!void {
        try self.toHeader().writeSma(writer);
    }

    /// An adapted identity context for terms of type T before marshalling and type erasure; used when interning terms.
    pub fn AdaptedIdentityContext(comptime T: type) type {
        return struct {
            ctx: *ir.Context,

            pub fn hash(self: @This(), t: *const T) u64 {
                const tag = self.ctx.tagFromType(T);
                var hasher = ir.QuickHasher.init();
                hasher.hash(tag);
                self.ctx.vtables[@intFromEnum(tag)].cbr(t, &hasher);
                return hasher.final();
            }

            pub fn eql(self: @This(), a: Term, b: *const T) bool {
                const tag = self.ctx.tagFromType(T);
                if (a.tag != tag) return false;
                return self.ctx.vtables[@intFromEnum(tag)].eql(a.toOpaquePtr(), b);
            }
        };
    }

    /// The standard identity context for terms, used in the interned term set.
    pub const IdentityContext = struct {
        pub fn hash(_: @This(), t: Term) u64 {
            var hasher = ir.QuickHasher.init();
            hasher.update(t.tag);
            t.toHeader().root.vtables.get(t.tag).?.hash(t.toOpaquePtr(), &hasher);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: Term, b: Term) bool {
            if (a.tag != b.tag) return false;
            return a.toHeader().root.vtables.get(a.tag).?.eql(a.toOpaquePtr(), b.toOpaquePtr());
        }
    };

    /// A constructor for term types that have no internal data,
    /// and are uniquely identified by a compile-time name.
    pub fn IdentityType(comptime name: []const u8) type {
        return struct {
            const Self = @This();

            pub fn eql(_: *const Self, _: *const Self) bool {
                return true;
            }

            pub fn hash(_: *const Self, hasher: *ir.QuickHasher) void {
                hasher.update(name);
            }

            pub fn cbr(_: *const Self) ir.Cbr {
                var hasher = ir.Cbr.Hasher.init();
                hasher.update(name);
                return hasher.final();
            }

            pub fn dehydrate(_: *const Self, _: *ir.Sma.Dehydrator, _: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
                // Identity types have no data to dehydrate
            }

            pub fn rehydrate(_: *const ir.Sma.Term, _: *ir.Sma.Rehydrator, _: *Self) error{ BadEncoding, OutOfMemory }!void {
                // Identity types have no data to rehydrate
            }
        };
    }
};
