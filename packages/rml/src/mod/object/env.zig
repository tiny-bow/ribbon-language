const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Rml = @import("../root.zig");


pub const Domain = std.ArrayHashMapUnmanaged(Rml.Obj(Rml.Symbol), void, MiscUtils.SimpleHashContext, true);

pub const CellTable = std.ArrayHashMapUnmanaged(Rml.Obj(Rml.Symbol), Rml.Obj(Rml.Cell), MiscUtils.SimpleHashContext, true);
pub const Table = std.ArrayHashMapUnmanaged(Rml.Obj(Rml.Symbol), Rml.Obj(Rml.ObjData), MiscUtils.SimpleHashContext, true);

pub const Env = struct {
    allocator: std.mem.Allocator,
    table: CellTable = .{},

    pub fn compare(self: Env, other: Env) Rml.Ordering {
        var ord = Rml.compare(self.keys(), other.keys());

        if (ord == .Equal) {
            ord = Rml.compare(self.cells(), other.cells());
        }

        return ord;
    }

    pub fn format(self: *const Env, comptime fmtStr: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror! void {
        const fmt = Rml.Format.fromStr(fmtStr) orelse .debug;
        const w = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();
        try w.writeAll("env{ ");
        var it = self.table.iterator();
        while (it.next()) |entry| {
            try w.writeAll("(");
            try entry.key_ptr.onFormat(fmt, w);
            try w.writeAll(" = ");
            try entry.value_ptr.onFormat(fmt, w);
            try w.writeAll(") ");
        }
        try w.writeAll("}");
    }

    /// Shallow copy an Env.
    pub fn clone(self: *const Env, origin: ?Rml.Origin) Rml.OOM! Rml.Obj(Env) {
        const table = try self.table.clone(self.allocator);

        return try .wrap(Rml.getRml(self), origin orelse Rml.getOrigin(self), .{.allocator = self.allocator, .table = table});
    }

    /// Set a value associated with a key in this Env.
    ///
    /// If the key is already bound, a new cell is created, overwriting the old one
    ///
    /// Returns an error if:
    /// * Rml is out of memory
    pub fn rebind(self: *Env, key: Rml.Obj(Rml.Symbol), val: Rml.Object) Rml.OOM! void {
        const cell = try Rml.Obj(Rml.Cell).wrap(Rml.getRml(self), key.getOrigin(), .{.value = val});

        try self.table.put(self.allocator, key, cell);
    }

    /// Bind a value to a new key
    ///
    /// Returns an error if:
    /// * a value with the same name was already declared in this scope
    /// * Rml is out of memory
    pub fn bind(self: *Env, key: Rml.Obj(Rml.Symbol), val: Rml.Object) (Rml.OOM || Rml.SymbolAlreadyBound)! void {
        if (self.contains(key)) return error.SymbolAlreadyBound;

        return self.rebind(key, val);
    }

    /// Bind a value to an existing key
    ///
    /// Returns an error if:
    /// * binding does not exist in this env
    pub fn set(self: *Env, key: Rml.Obj(Rml.Symbol), val: Rml.Object) Rml.UnboundSymbol! void {
        return if (self.table.getEntry(key)) |entry| {
            entry.value_ptr.data.set(val);
        } else error.UnboundSymbol;
    }

    /// Find the value bound to a symbol in the env
    pub fn get(self: *const Env, key: Rml.Obj(Rml.Symbol)) ?Rml.Object {
        if (self.table.getEntry(key)) |entry| {
            return entry.value_ptr.data.get();
        }

        return null;
    }

    /// Returns the number of bindings in the env
    pub fn length(self: *const Env) Rml.Int {
        return @intCast(self.table.count());
    }

    /// Check whether a key is bound in the env
    pub fn contains(self: *const Env, key: Rml.Obj(Rml.Symbol)) bool {
        return self.table.contains(key);
    }

    /// Get a slice of the keys of this Env
    pub fn keys(self: *const Env) []Rml.Obj(Rml.Symbol) {
        return self.table.keys();
    }

    /// Get a slice of the cells of this Env
    pub fn cells(self: *const Env) []Rml.Obj(Rml.Cell) {
        return self.table.values();
    }

    /// Copy all bindings from another env
    pub fn copyFromEnv(self: *Env, other: *Env) (Rml.OOM || Rml.SymbolAlreadyBound)! void {
        var it = other.table.iterator();
        while (it.next()) |entry| {
            try self.rebindCell(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    /// Copy all bindings from a table
    pub fn copyFromTable(self: *Env, table: *const Table) (Rml.OOM || Rml.SymbolAlreadyBound)! void {
        var it = table.iterator();
        while (it.next()) |entry| {
            try self.rebind(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    /// Set a cell associated with a key
    ///
    /// If the key is already bound, overwrites the old one
    ///
    /// Returns an error if:
    /// * Rml is out of memory
    pub fn rebindCell(self: *Env, key: Rml.Obj(Rml.Symbol), cell: Rml.Obj(Rml.Cell)) Rml.OOM! void {
        try self.table.put(self.allocator, key, cell);
    }

    /// Bind a cell to a new key
    ///
    /// Returns an error if:
    /// * a value with the same name was already declared in this scope
    /// * Rml is out of memory
    pub fn bindCell(self: *Env, key: Rml.Obj(Rml.Symbol), cell: Rml.Obj(Rml.Cell)) (Rml.OOM || Rml.SymbolAlreadyBound)! void {
        if (self.contains(key)) return error.SymbolAlreadyBound;

        try self.table.put(self.allocator, key, cell);
    }

    /// Copy all bindings from a Zig namespace
    pub fn bindNamespace(self: *Env, namespace: anytype) Rml.OOM! void {
        const T = @TypeOf(namespace);
        const rml = Rml.getRml(self);
        const origin = Rml.Origin.fromComptimeStr("builtin-" ++ @typeName(T));
        inline for (comptime std.meta.fields(T)) |field| {
            const sym: Rml.Obj(Rml.Symbol) = try .wrap(rml, origin, try .create(rml, field.name));

            if (comptime std.mem.startsWith(u8, @typeName(field.type), "object.Obj")) { // TODO: this check really needs to be more robust
                self.bind(sym, @field(namespace, field.name).typeErase()) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory
                    else @panic(@errorName(err));
                };
            } else {
                const val: Rml.Obj(field.type) = try .wrap(rml, origin, @field(namespace, field.name));

                self.bind(sym, val.typeErase()) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory
                    else @panic(@errorName(err));
                };
            }
        }
    }
};
