const Rir = @import("../Rir.zig");

const variable = @This();

const Rbc = @import("Rbc");

/// Describes where a `Local` variable is stored
pub const LocalStorage = union(enum) {
    /// The Local is not stored anywhere
    ///
    /// This is used by types like `Block`, that are compile time only;
    /// and by types that cannot be addressed, like `Function`
    none: void,

    /// The Local can pretend to be stored anywhere, because it has no size
    ///
    /// This is used for `Nil` and similar types
    zero_size: void,

    /// The Local is equal to or smaller than a single register in size
    ///
    /// This is used for ints, floats, etc
    register: void,

    /// The Local is stored in a set of up to 4 registers, with the total provided by the given `u2`
    ///
    /// This is used by special types like `Slice`
    n_registers: u2,

    /// The Local is too large to fit in a register, or has its address taken
    ///
    /// This is used for structs, arrays, etc
    stack: void,

    /// The Local is a compile time variable
    @"comptime": void,

    /// Shortcut to create `LocalStorage.n_registers`
    pub fn fromRegisters(n: u2) LocalStorage {
        return .{ .n_registers = n };
    }

    /// Determine a generic `LocalStorage` for a given value size
    ///
    /// Note that not all types with a given size will use the same `LocalStorage`, this is simply the default
    ///
    /// | Size | Storage |
    /// |-|-|
    /// | 0 |`zero_size` |
    /// | 1 ..= sizeOf(Rbc.Register) | `register` |
    /// | > | `stack` |
    pub fn fromSize(size: usize) LocalStorage {
        return if (size == 0) .zero_size else if (size <= @sizeOf(Rbc.Register)) .register else .stack;
    }

    /// Determine whether a `Local` with this `Storage` can be coerced to a single `Register`
    ///
    /// |Storage|Can Coerce|Reasoning|
    /// |-|-|-|
    /// |`none` | `false` | Not stored anywhere |
    /// |`zero_size` | `true` | Any `Register` is suitable for zero-sized operations |
    /// |`register` | `true` | It *is* a single `Register` |
    /// |`n_registers`| `false` | Ambiguous choice of `Register` |
    /// |`stack` | `false` | Additional instructions needed to `load`/`store` value |
    /// |`comptime`| `false` | In memory at compile time only |
    pub fn canCoerceSingleRegister(self: LocalStorage) bool {
        return self == .register or self == .zero_size;
    }
};

pub const Local = struct {
    pub const Id = Rir.LocalId;

    ir: *Rir,
    block: *Rir.Block,

    id: Rir.LocalId,
    name: Rir.NameId,
    type: *Rir.Type,

    lifetime_start: ?Rir.Offset = null,
    lifetime_end: ?Rir.Offset = null,
    register: ?*Rir.Register = null,
    storage: LocalStorage = .none,

    pub fn init(block: *Rir.Block, id: Rir.LocalId, name: Rir.NameId, typeIr: *Rir.Type) error{OutOfMemory}!*Local {
        const ir = block.ir;

        const self = try ir.allocator.create(Local);

        self.* = Local{
            .ir = ir,
            .block = block,
            .id = id,
            .name = name,
            .type = typeIr,
        };

        return self;
    }

    pub fn deinit(self: *Local) void {
        self.ir.allocator.destroy(self);
    }

    pub fn isComptimeKnown(self: Local) bool {
        return self.storage == .@"comptime";
    }
};

pub const Upvalue = struct {
    pub const Id = Rir.UpvalueId;

    ir: *Rir,
    block: *Rir.Block,

    id: Rir.UpvalueId,
    name: Rir.NameId,
    type: *Rir.Type,

    pub fn init(block: *Rir.Block, id: Rir.UpvalueId, name: Rir.NameId, typeIr: *Rir.Type) error{OutOfMemory}!*Upvalue {
        const ir = block.ir;
        const self = try ir.allocator.create(Upvalue);

        self.* = Upvalue{
            .ir = ir,
            .block = block,
            .id = id,
            .name = name,
            .type = typeIr,
        };

        return self;
    }

    pub fn deinit(self: *Upvalue) void {
        self.ir.allocator.destroy(self);
    }
};

pub const Mutability = enum(u1) {
    immutable = 0,
    mutable = 1,
};

pub const Global = struct {
    pub const Id = Rir.GlobalId;

    ir: *Rir,
    module: *Rir.Module,

    id: Rir.GlobalId,
    name: Rir.NameId,
    type: *Rir.Type,

    initial_value: ?[]u8 = null,
    mutability: Mutability = .immutable,

    pub fn getRef(self: *const Global) Rir.value.OpRef(Rir.Global) {
        return Rir.value.OpRef(Rir.Global){
            .module_id = self.module.id,
            .id = self.id,
        };
    }

    pub fn init(moduleIr: *Rir.Module, id: Rir.GlobalId, name: Rir.NameId, typeIr: *Rir.Type) error{OutOfMemory}!*Global {
        const ir = moduleIr.ir;

        const self = try ir.allocator.create(Global);
        errdefer ir.allocator.destroy(self);

        self.* = Global{
            .ir = ir,
            .module = moduleIr,

            .id = id,
            .name = name,
            .type = typeIr,
        };

        return self;
    }

    pub fn deinit(self: *Global) void {
        if (self.initial_value) |ini| self.ir.allocator.free(ini);
        self.ir.allocator.destroy(self);
    }

    pub fn onFormat(self: *const Global, formatter: Rir.Formatter) !void {
        const oldActiveModule = formatter.swapModule(self.module);
        defer formatter.setModule(oldActiveModule);

        try formatter.fmt(self.name);
        if (formatter.getFlag(.show_ids)) try formatter.print("#{}", .{@intFromEnum(self.id)});
        try formatter.writeAll(": ");
        try formatter.fmt(self.type);
        try formatter.writeAll(" = ");

        if (self.initial_value) |iv| {
            try self.type.formatMemory(formatter, iv);
        } else {
            try formatter.writeAll("{uninitialized}");
        }
    }

    /// Determine whether the value of this `Global` is known at compile time
    ///
    /// This is `true` for `Globals` that meet the following criteria:
    /// - The global is `immutable`
    /// - The `initial_value` is not `null`
    pub fn isComptimeKnown(self: *const Global) bool {
        return self.mutability == .immutable and self.initial_value != null;
    }

    /// Initialize a `Global` with a native value
    pub fn initializerFromNative(self: *Global, value: anytype) error{ TypeMismatch, TooManyGlobals, TooManyTypes, TooManyNames, OutOfMemory }!void {
        const T = @TypeOf(value);
        const typeIr = try self.ir.createTypeFromNative(T, null, null);

        if (typeIr.id != self.type.id) {
            return error.TypeMismatch;
        }

        self.initial_value = try self.ir.allocator.dupe(u8, @as([*]const u8, @ptrCast(&value))[0..@sizeOf(T)]);
    }
};
