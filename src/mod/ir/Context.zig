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
interned_name_set: common.StringMap(ir.Name.Id) = .empty,
/// Reverse mapping for interned names.
name_id_to_string: common.UniqueReprMap(ir.Name.Id, []const u8) = .empty,
/// A set of all constant data blobs in the context, de-duplicated and owned by the context itself
interned_data_set: common.HashSet(*const ir.Blob, ir.Blob.HashContext) = .empty,

/// Contains all terms created in this context
all_terms: common.ArrayList(ir.Term) = .empty,

/// Contains terms that are not subject to interface association, such as ints and arrays
shared_terms: common.HashSet(ir.Term, ir.Term.IdentityContext) = .empty,
/// Contains terms that are commonly used, such as "i32"
named_shared_terms: common.StringMap(ir.Term) = .empty,

/// Map from @typeName to ir.Term.Tag
tags: common.StringMap(ir.Term.Tag) = .empty,
/// Map from ir.Term.Tag to ir.Term.VTable for the associated type
vtables: common.UniqueReprMap(ir.Term.Tag, ir.Term.VTable) = .empty,

/// Source of fresh ir.Term.Id values
fresh_term_id: std.meta.Tag(ir.Term.Id) = 0,

/// Initialize a new ir context on the given allocator.
pub fn init(allocator: std.mem.Allocator) !*Context {
    const self = try allocator.create(Context);

    self.* = Context{
        .allocator = allocator,
        .arena = .init(allocator),
    };

    inline for (comptime std.meta.declarations(ir.terms)) |decl| {
        try self.registerTermType(@field(ir.terms, decl.name));
    }

    return self;
}

/// Deinitialize this context and all its contents.
pub fn deinit(self: *Context) void {
    var module_it = self.modules.valueIterator();
    while (module_it.next()) |module_p2p| module_p2p.*.deinit();
    self.modules.deinit(self.allocator);

    self.all_terms.deinit(self.allocator);
    self.name_to_module_guid.deinit(self.allocator);
    self.interned_name_set.deinit(self.allocator);
    self.name_id_to_string.deinit(self.allocator);
    self.interned_data_set.deinit(self.allocator);
    self.shared_terms.deinit(self.allocator);
    self.named_shared_terms.deinit(self.allocator);

    self.arena.deinit();

    self.allocator.destroy(self);
}

/// Get the ir.Term.Tag for a term type in the context. See also `registerTermType`.
pub fn tagFromType(self: *Context, comptime T: type) ?ir.Term.Tag {
    return self.tags.get(@typeName(T));
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
        .eql = @ptrCast(&T.eql),
        .hash = @ptrCast(&T.hash),
        .cbr = @ptrCast(&T.cbr),
        .writeSma = @ptrCast(&T.writeSma),
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
        const fresh_id: ir.Name.Id = @enumFromInt(self.name_id_to_string.count());
        gop.key_ptr.* = owned_buf;
        gop.value_ptr.* = fresh_id;
        try self.name_id_to_string.put(self.allocator, fresh_id, owned_buf);
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
        .id = @enumFromInt(self.interned_data_set.count()),
        .layout = core.Layout{ .alignment = alignment, .size = @intCast(bytes.len) },
    };
    @memcpy(new_buf.ptr + @sizeOf(ir.Blob), bytes);
    try self.interned_data_set.put(self.allocator, blob, {});

    return blob;
}

/// Create a new term in the context. This allocates memory for the term value and returns both a typed pointer to the value and the type-erased ir.Term.
pub fn createTerm(self: *Context, comptime T: type, module: ?*ir.Module) error{ ZigTypeNotRegistered, OutOfMemory }!struct { *T, ir.Term } {
    const ptr = try ir.TermData(T).allocate(self, module);
    const term = ir.Term.fromPtr(self, ptr);
    try self.all_terms.append(self.allocator, term);
    return .{ ptr, term };
}

/// Add a new term to the context. This provides type erasure and memory management for the term value.
pub fn addTerm(self: *Context, module: ?*ir.Module, value: anytype) error{OutOfMemory}!ir.Term {
    const T = @TypeOf(value);
    const ptr, const term = try self.createTerm(T, module);
    ptr.* = value;
    return term;
}

/// Get or create a shared term in the context. If a name is provided, the term is also interned under that name for access with `getNamedSharedTerm`.
pub fn getOrCreateSharedTerm(self: *Context, name: ?ir.Name, value: anytype) error{ MismatchedNamedTermDefinitions, OutOfMemory }!ir.Term {
    const T = @TypeOf(value);
    if (self.shared_terms.getKeyAdapted(&value, ir.Term.AdaptedIdentityContext(T){ .ctx = self })) |existing_term| {
        if (name) |new_name| {
            if (self.named_shared_terms.get(new_name)) |named_term| {
                if (named_term != existing_term) return error.MismatchedNamedTermDefinitions;
            } else {
                try self.named_shared_terms.put(self.allocator, new_name, existing_term);
            }
        }

        return existing_term;
    } else {
        const new_term = try self.addTerm(null, value);
        if (name) |new_name| {
            if (self.named_shared_terms.contains(new_name)) return error.MismatchedNamedTermDefinitions;
            try self.named_shared_terms.put(self.allocator, new_name, new_term);
        }
        try self.shared_terms.put(self.allocator, new_term, {});

        return new_term;
    }
}

/// Get a shared term from the context using the name passed when it was interned. See also `getOrCreateSharedTerm`.
pub fn getNamedSharedTerm(self: *Context, name: ir.Name) ?ir.Term {
    return self.named_shared_terms.get(name.value);
}

/// Get a fresh unique ir.Term.Id for this context.
pub fn generateTermId(self: *Context) ir.Term.Id {
    const id = self.fresh_term_id;
    self.fresh_term_id += 1;
    return @enumFromInt(id);
}
