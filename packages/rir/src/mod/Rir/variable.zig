const Rir = @import("../Rir.zig");


pub const Local = struct {
    block: *Rir.Block,
    id: Rir.LocalId,
    name: Rir.Name,
    type: Rir.TypeId,

    pub fn init(block: *Rir.Block, id: Rir.LocalId, name: Rir.Name, tyId: Rir.TypeId) error{OutOfMemory}! *Local {
        const self = try block.function.module.root.allocator.create(Local);

        self.* = Local {
            .block = block,
            .id = id,
            .name = name,
            .type = tyId,
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
    name: Rir.Name,
    type: Rir.TypeId,
    value: []u8,


    pub fn getRef(self: *const Global) Rir.Ref(Rir.GlobalId) {
        return Rir.Ref(Rir.GlobalId) {
            .id = self.id,
            .module = self.module.id,
        };
    }


    pub fn init(mod: *Rir.Module, id: Rir.GlobalId, name: Rir.Name, ty: Rir.TypeId, value: []u8) error{OutOfMemory}! *Global {
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
