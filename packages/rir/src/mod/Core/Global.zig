const Core = @import("../Core.zig");

const Global = @This();


module: *Core.Module,
id: Core.GlobalId,
name: Core.Name,
type: Core.TypeId,
value: []u8,


pub fn init(mod: *Core.Module, id: Core.GlobalId, name: Core.Name, ty: Core.TypeId, value: []u8) !*Global {
    errdefer mod.root.allocator.free(value);

    const ptr = try mod.root.allocator.create(Global);
    errdefer mod.root.allocator.destroy(ptr);

    ptr.* = Global {
        .module = mod,
        .id = id,
        .name = name,
        .type = ty,
        .value = value,
    };

    return ptr;
}

pub fn deinit(self: *Global) void {
    self.module.root.allocator.free(self.value);
    self.module.root.allocator.destroy(self);
}

pub fn onFormat(self: *const Global, formatter: Core.Formatter) !void {
    const oldActiveModule = formatter.setModule(self.module);
    defer _ = formatter.setModule(oldActiveModule);

    const T = try self.module.getType(self.type);

    try formatter.fmt(self.name);
    try formatter.writeAll(": ");
    try formatter.fmt(self.type);
    try formatter.writeAll(" = ");
    try T.formatMemory(formatter, self.value);
}
