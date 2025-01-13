const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Rml = @import("../root.zig");


pub const Domain = std.ArrayHashMapUnmanaged(Rml.Obj(Rml.Symbol), void, MiscUtils.SimpleHashContext, true);

pub const CellTable = std.ArrayHashMapUnmanaged(Rml.Obj(Rml.Symbol), Rml.Obj(Rml.Cell), MiscUtils.SimpleHashContext, true);
pub const Table = std.ArrayHashMapUnmanaged(Rml.Obj(Rml.Symbol), Rml.Obj(Rml.ObjData), MiscUtils.SimpleHashContext, true);

pub const Env = struct {
    allocator: std.mem.Allocator,
    table: CellTable = .{},

    pub fn onCompare(a: *Env, other: Rml.Object) Rml.Ordering {
        var ord = Rml.compare(Rml.getTypeId(a), other.getTypeId());

        if (ord == .Equal) {
            const b = Rml.forceObj(Env, other);
            ord = a.compare(b.data.*);
        }

        return ord;
    }

    pub fn compare(self: Env, other: Env) Rml.Ordering {
        var ord = Rml.compare(self.table.count(), other.table.count());

        if (ord == .Equal) {
            var it = self.table.iterator();
            while (it.next()) |entry| {
                if (other.table.getEntry(entry.key_ptr.*)) |other_entry| {
                    ord = entry.value_ptr.compare(other_entry.value_ptr.*);
                } else {
                    return .Greater;
                }
            }
        }

        return ord;
    }

    pub fn onFormat(self: *Env, fmt: Rml.Format, writer: std.io.AnyWriter) anyerror! void {
        try writer.writeAll("env{ ");

        var it = self.table.iterator();
        while (it.next()) |entry| {
            try writer.writeAll("(");
            try entry.key_ptr.onFormat(fmt, writer);
            try writer.writeAll(" = ");
            try entry.value_ptr.onFormat(fmt, writer);
            try writer.writeAll(") ");
        }

        try writer.writeAll("}");
    }

    pub fn format(self: *Env, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror! void {
        self.onFormat(comptime Rml.Format.fromStr(fmt) orelse Rml.Format.debug, if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any());
    }

    pub fn clone(self: *Env, origin: ?Rml.Origin) Rml.OOM! Rml.Obj(Env) {
        const table = try self.table.clone(self.allocator);

        return try .wrap(Rml.getRml(self), origin orelse Rml.getOrigin(self), .{.allocator = self.allocator, .table = table});
    }

    /// Set a value associated with a key
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
    pub fn get(self: *Env, key: Rml.Obj(Rml.Symbol)) ?Rml.Object {
        if (self.table.getEntry(key)) |entry| {
            return entry.value_ptr.data.get();
        }

        return null;
    }

    /// Returns the number of bindings in the env
    pub fn length(self: *Env) Rml.Int {
        return @intCast(self.table.count());
    }

    /// Check whether a key is bound in the env
    pub fn contains(self: *Env, key: Rml.Obj(Rml.Symbol)) bool {
        return self.table.contains(key);
    }

    /// Get a slice of the local keys of this Env
    pub fn keys(self: *Env) []Rml.Obj(Rml.Symbol) {
        return self.table.keys();
    }


    pub fn copyFromEnv(self: *Env, other: *Env) (Rml.OOM || Rml.SymbolAlreadyBound)! void {
        var it = other.table.iterator();
        while (it.next()) |entry| {
            try self.rebindCell(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

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
