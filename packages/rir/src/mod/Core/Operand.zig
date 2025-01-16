const Core = @import("../Core.zig");


pub const Operand = union(enum) {
    type: Core.TypeId,
    register: Core.RegisterId,
    immediate: Immediate,
    block: Core.BlockId,
    foreign: Core.ForeignId,
    function: Core.Ref(Core.FunctionId),
    global: Core.Ref(Core.GlobalId),
    upvalue: Core.UpvalueId,
    handler_set: Core.HandlerSetId,
    local: Core.LocalId,

    pub const Immediate = packed struct {
        type: Core.TypeId,
        value: u64,
    };

    pub fn isConstant(self: Operand) bool {
        return switch (self) {
            inline
                .intermediate,
                .global,
                .upvalue,
                .local,
            => false,

            inline
                .immediate,
                .block,
                .function,
                .handler_set,
             => true,
        };
    }
};
