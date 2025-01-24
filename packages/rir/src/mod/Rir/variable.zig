const Rbc = @import("Rbc");
const Rir = @import("../Rir.zig");


pub const LocalStorage = enum {
    /// The Local is not yet stored anywhere.
    none,

    /// The Local can pretend to be stored anywhere, because it has no size.
    zero_size,

    /// The Local is stored in a register.
    register,

    /// The Local is stored on the stack.
    stack,

    /// Never returns `.none`
    ///
    /// Forces `computeLayout` on the type
    pub fn fromType(rir: *Rir, typeId: Rir.TypeId) !LocalStorage {
        const typeLayout = try rir.getTypeLayout(typeId);

        if (typeLayout.dimensions.size == 0) return .zero_size;

        if (typeLayout.dimensions.size <= 8) return .register;

        return .stack;
    }
};

pub const Local = struct {
    block: *Rir.Block,
    id: Rir.LocalId,
    name: Rir.NameId,
    type: Rir.TypeId,
    lifetime_start: ?Rir.Offset,
    storage: LocalStorage = .none,

    pub fn init(block: *Rir.Block, id: Rir.LocalId, name: Rir.NameId, tyId: Rir.TypeId) error{OutOfMemory}! *Local {
        const self = try block.function.module.root.allocator.create(Local);

        self.* = Local {
            .block = block,
            .id = id,
            .name = name,
            .type = tyId,
            .lifetime_start = block.length(),
        };

        return self;
    }

    pub fn deinit(self: *Local) void {
        self.block.function.module.root.allocator.destroy(self);
    }
};

pub const Global = struct {
    module: *Rir.Module,
    id: Rir.GlobalId,
    name: Rir.NameId,
    type: Rir.TypeId,
    value: []u8,


    pub fn getRef(self: *const Global) Rir.Ref(Rir.GlobalId) {
        return Rir.Ref(Rir.GlobalId) {
            .id = self.id,
            .module = self.module.id,
        };
    }


    pub fn init(mod: *Rir.Module, id: Rir.GlobalId, name: Rir.NameId, ty: Rir.TypeId, value: []u8) error{OutOfMemory}! *Global {
        errdefer mod.root.allocator.free(value);

        const self = try mod.root.allocator.create(Global);
        errdefer mod.root.allocator.destroy(self);

        self.* = Global {
            .module = mod,
            .id = id,
            .name = name,
            .type = ty,
            .value = value,
        };

        return self;
    }

    pub fn deinit(self: *Global) void {
        self.module.root.allocator.free(self.value);
        self.module.root.allocator.destroy(self);
    }

    pub fn onFormat(self: *const Global, formatter: Rir.Formatter) !void {
        const oldActiveModule = formatter.swapModule(self.module);
        defer formatter.setModule(oldActiveModule);

        const T = try self.module.root.getType(self.type);

        try formatter.fmt(self.name);
        if (formatter.getFlag(.show_ids)) try formatter.print("#{}", .{@intFromEnum(self.id)});
        try formatter.writeAll(": ");
        try formatter.fmt(self.type);
        try formatter.writeAll(" = ");
        try T.formatMemory(formatter, self.value);
    }
};
