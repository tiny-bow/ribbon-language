//! The "universe" for an ir compilation session.
const Context = @This();

const std = @import("std");
const core = @import("core");
const common = @import("common");

const ir = @import("../ir.zig");

/// Standard allocator for managed data in the context.
allocator: std.mem.Allocator,
/// Arena allocator for terms and other static data.
arena: std.heap.ArenaAllocator,

/// Map from ir.Module.GUID to an index in the `modules` array
modules: common.UniqueReprMap(ir.Module.GUID, *ir.Module) = .empty,
/// Map from module name string to ir.Module.GUID
name_to_module_guid: common.StringMap(ir.Module.GUID) = .empty,

/// A set of all names in the context, de-duplicated and owned by the context itself
interned_name_set: common.StringSet = .empty,
/// A set of all constant data blobs in the context, de-duplicated and owned by the context itself
interned_data_set: common.HashSet(*const ir.Blob, ir.Blob.HashContext) = .empty,

/// Contains terms that are not subject to interface association, such as ints and arrays
shared_terms: common.HashSet(ir.Term, ir.Term.IdentityContext) = .empty,

/// Map from @typeName to ir.Term.Tag
tags: common.StringMap(ir.Term.Tag) = .empty,
/// Map from ir.Term.Tag to ir.Term.VTable for the associated type
vtables: common.UniqueReprMap(ir.Term.Tag, ir.Term.VTable) = .empty,

/// Initialize a new ir context on the given allocator.
pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*Context {
    const self = try allocator.create(Context);

    self.* = Context{
        .allocator = allocator,
        .arena = .init(allocator),
    };
    errdefer self.deinit();

    inline for (comptime std.meta.declarations(ir.terms)) |decl| {
        self.registerTermType(@field(ir.terms, decl.name)) catch |err| {
            switch (err) {
                error.DuplicateTermType => {
                    std.debug.panic("Duplicate term type registration for {s}\n", .{decl.name});
                },
                error.TooManyTermTypes => {
                    std.debug.panic("Too many term types registered in ir context\n", .{});
                },
                error.OutOfMemory => return error.OutOfMemory,
            }
        };
    }

    return self;
}

/// Deinitialize this context and all its contents.
pub fn deinit(self: *Context) void {
    var module_it = self.modules.valueIterator();
    while (module_it.next()) |module_p2p| module_p2p.*.deinit();
    self.modules.deinit(self.allocator);

    self.name_to_module_guid.deinit(self.allocator);
    self.interned_name_set.deinit(self.allocator);
    self.interned_data_set.deinit(self.allocator);
    self.shared_terms.deinit(self.allocator);

    self.arena.deinit();

    self.allocator.destroy(self);
}

/// Get the ir.Term.Tag for a term type in the context. See also `registerTermType`, `tagFromName`.
pub fn tagFromType(self: *Context, comptime T: type) ?ir.Term.Tag {
    return self.tags.get(@typeName(T));
}

/// Get the ir.Term.Tag for a type name. See also `registerTermType`, `tagFromType`.
pub fn tagFromName(self: *Context, name: []const u8) ?ir.Term.Tag {
    return self.tags.get(name);
}

/// Get the typename associated with a given ir.Term.Tag in the context.
pub fn getTagName(self: *Context, tag: ir.Term.Tag) ?[]const u8 {
    const vtable = self.vtables.get(tag) orelse return null;
    return vtable.name;
}

/// Register a term type in the context.
/// Generally, it is not necessary to call this function manually, as all term types in the `terms` namespace are registered automatically on context initialization.
/// This is provided for extensibility. See also `tagFromType`.
pub fn registerTermType(self: *Context, comptime T: type) error{ DuplicateTermType, TooManyTermTypes, OutOfMemory }!void {
    if (self.tags.contains(@typeName(T))) {
        return error.DuplicateTermType;
    }

    const tag_number = self.tags.count();
    if (tag_number > std.math.maxInt(std.meta.Tag(ir.Term.Tag))) {
        return error.TooManyTermTypes;
    }

    const tag: ir.Term.Tag = @enumFromInt(tag_number);

    try self.tags.put(self.allocator, @typeName(T), tag);
    errdefer _ = self.tags.remove(@typeName(T));

    try self.vtables.put(self.allocator, tag, ir.Term.VTable{
        .name = @typeName(T),
        .layout = core.Layout.of(T),
        .offset = @offsetOf(ir.Term.Data(T), "value"),
        .create = @ptrCast(&ir.Term.Data(T).allocate),
        .destroy = &struct {
            pub fn @"term_vtable:destroy"(value: *const anyopaque, ctx: *ir.Context) void {
                const typed_ptr = @as(*const T, @ptrCast(@alignCast(value)));
                const data_ptr: *const ir.Term.Data(T) = @alignCast(@fieldParentPtr("value", typed_ptr));
                ctx.arena.allocator().destroy(data_ptr);
            }
        }.@"term_vtable:destroy",
        .getShared = &struct {
            pub fn @"term_vtable:getShared"(value: *const anyopaque, ctx: *ir.Context) ?ir.Term {
                return ctx.shared_terms.getKeyAdapted(@as(*const T, @ptrCast(@alignCast(value))), ir.Term.AdaptedIdentityContext(T){ .ctx = ctx });
            }
        }.@"term_vtable:getShared",
        .eql = @ptrCast(&T.eql),
        .hash = @ptrCast(&T.hash),
        .dehydrate = @ptrCast(&T.dehydrate),
        .rehydrate = @ptrCast(&T.rehydrate),
    });
    errdefer _ = self.vtables.remove(tag);
}

/// Create a new module in the context.
pub fn createModule(self: *Context, name: []const u8, guid: ir.Module.GUID) error{ DuplicateModuleGUID, DuplicateModuleName, OutOfMemory }!*ir.Module {
    if (self.modules.contains(guid)) {
        return error.DuplicateModuleGUID;
    }

    if (self.name_to_module_guid.contains(name)) {
        return error.DuplicateModuleName;
    }

    const interned_name = try self.internName(name);
    const new_module = try ir.Module.init(self, interned_name, guid);

    try self.name_to_module_guid.put(self.allocator, interned_name.value, guid);
    errdefer _ = self.name_to_module_guid.remove(interned_name.value);

    try self.modules.put(self.allocator, guid, new_module);
    errdefer _ = self.modules.remove(guid);

    return new_module;
}

/// Intern a symbolic name in the context. If an identical name already exists, returns a reference to the existing name.
pub fn internName(self: *Context, name: []const u8) error{OutOfMemory}!ir.Name {
    const gop = try self.interned_name_set.getOrPut(self.allocator, name);

    if (!gop.found_existing) {
        const owned_buf = try self.arena.allocator().dupe(u8, name);
        gop.key_ptr.* = owned_buf;
    }

    return ir.Name{ .value = gop.key_ptr.* };
}

/// Intern a constant data blob in the context. If an identical blob already exists, returns a pointer to the existing ir.BlobHeader.
pub fn internData(self: *Context, alignment: core.Alignment, bytes: []const u8) error{OutOfMemory}!*const ir.Blob {
    if (self.interned_data_set.getKeyAdapted(.{ alignment, bytes }, ir.Blob.AdaptedHashContext{})) |existing_blob| {
        return existing_blob;
    }

    const new_buf = try self.arena.allocator().alignedAlloc(u8, .fromByteUnits(@alignOf(ir.Blob)), @sizeOf(ir.Blob) + bytes.len);
    const blob: *ir.Blob = @ptrCast(new_buf.ptr);
    blob.* = .{
        .layout = core.Layout{ .alignment = alignment, .size = @intCast(bytes.len) },
    };
    @memcpy(new_buf.ptr + @sizeOf(ir.Blob), bytes);
    try self.interned_data_set.put(self.allocator, blob, {});

    return blob;
}

/// Create a new term in the context. This allocates memory for the term value and returns both a typed pointer to the value and the type-erased ir.Term.
pub fn createTerm(self: *Context, comptime T: type) error{ ZigTypeNotRegistered, OutOfMemory }!struct { *T, ir.Term } {
    const ptr = try ir.Term.Data(T).allocate(self);
    const term = ir.Term.fromPtr(self, ptr);
    return .{ ptr, term };
}

/// Add a new term to the context. This provides type erasure and memory management for the term value.
pub fn addTerm(self: *Context, value: anytype) error{OutOfMemory}!ir.Term {
    const T = @TypeOf(value);
    const ptr, const term = try self.createTerm(T);
    ptr.* = value;
    return term;
}

/// Get or create a shared term in the context. If a name is provided, the term is also interned under that name for access with `getNamedSharedTerm`.
pub fn getOrCreateSharedTerm(self: *Context, value: anytype) error{OutOfMemory}!ir.Term {
    const T = @TypeOf(value);
    if (self.shared_terms.getKeyAdapted(&value, ir.Term.AdaptedIdentityContext(T){ .ctx = self })) |existing_term| {
        return existing_term;
    } else {
        const new_term = try self.addTerm(null, value);
        new_term.toHeader().is_shared = true;
        try self.shared_terms.put(self.allocator, new_term, {});

        return new_term;
    }
}

pub fn dehydrate(self: *Context, allocator: std.mem.Allocator) error{ BadEncoding, OutOfMemory }!*ir.Sma {
    var dehydrator = try ir.Sma.Dehydrator.init(self, allocator);
    defer dehydrator.deinit();

    // we must dehydrate modules in order for cbr purposes
    const sorted_guids = try self.allocator.alloc(ir.Module.GUID, self.modules.count());
    defer self.allocator.free(sorted_guids);

    var module_it = self.modules.keyIterator();
    var module_index: usize = 0;
    while (module_it.next()) |guid| : (module_index += 1) {
        sorted_guids[module_index] = guid.*;
    }

    std.mem.sort(ir.Module.GUID, sorted_guids, {}, struct {
        pub fn guid_sorter(_: void, a: ir.Module.GUID, b: ir.Module.GUID) bool {
            return @intFromEnum(a) < @intFromEnum(b);
        }
    }.guid_sorter);

    for (sorted_guids) |guid| {
        const module = self.modules.get(guid).?;
        _ = try dehydrator.dehydrateModule(module);
    }

    return dehydrator.finalize();
}

pub fn rehydrate(sma: *const ir.Sma, allocator: std.mem.Allocator) error{ BadEncoding, OutOfMemory }!*Context {
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var rehydrator = try ir.Sma.Rehydrator.init(ctx, sma);
    defer rehydrator.deinit();

    for (0..sma.modules.items.len) |i| {
        _ = try rehydrator.rehydrateModule(@intCast(i));
    }

    return ctx;
}
