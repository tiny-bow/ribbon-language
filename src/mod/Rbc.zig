const Rbc = @This();

const std = @import("std");
const Isa = @import("Isa");

pub const log = std.log.scoped(.rbc);

test {
    std.testing.refAllDeclsRecursive(@This());
}

globals: []const [*]u8,
global_memory: []u8,
functions: []const Function,
foreign: []const *const anyopaque,
handler_sets: []const HandlerSet,
main: FunctionIndex,

pub fn deinit(self: Rbc, allocator: std.mem.Allocator) void {
    allocator.free(self.globals);

    allocator.free(self.global_memory);

    for (self.functions) |fun| {
        fun.deinit(allocator);
    }

    allocator.free(self.functions);

    allocator.free(self.foreign);

    for (self.handler_sets) |handlerSet| {
        allocator.free(handlerSet);
    }

    allocator.free(self.handler_sets);
}

pub const Register = u64;
pub const RegisterIndex = u8;
pub const RegisterLocalOffset = u16;
pub const RegisterBaseOffset = u32;
pub const UpvalueIndex = u8;
pub const UpvalueLocalOffset = u16;
pub const UpvalueBaseOffset = u32;
pub const GlobalIndex = u16;
pub const GlobalLocalOffset = u16;
pub const GlobalBaseOffset = u32;
pub const JumpOffset = i16;
pub const FunctionIndex = u16;
pub const ForeignIndex = u16;
pub const HandlerSetIndex = u16;
pub const EvidenceIndex = u16;
pub const MemorySize = u48;
pub const LayoutTableSize = RegisterBaseOffset;
pub const Alignment = u12;

pub const ReturnStyle = Isa.ReturnStyle;
pub const ZeroCheck = Isa.ZeroCheck;

pub const MAX_REGISTERS = 255;
pub const MAX_JUMP_OFFSET = @min(@abs(std.math.minInt(JumpOffset)), std.math.maxInt(JumpOffset));

pub const EVIDENCE_SENTINEL = std.math.maxInt(EvidenceIndex);
pub const HANDLER_SET_SENTINEL = std.math.maxInt(HandlerSetIndex);
pub const FUNCTION_SENTINEL = std.math.maxInt(FunctionIndex);

pub const Instruction = packed struct {
    code: Code,
    data: Data,
};

pub const Bytecode = struct {
    instructions: []const Instruction,

    pub fn deinit(self: Bytecode, allocator: std.mem.Allocator) void {
        allocator.free(self.instructions);
    }
};

pub const Function = struct {
    num_registers: RegisterIndex,
    bytecode: Bytecode,

    pub fn deinit(self: Function, allocator: std.mem.Allocator) void {
        self.bytecode.deinit(allocator);
    }
};

pub const HandlerSet = []const HandlerBinding;

pub const HandlerBinding = struct {
    id: EvidenceIndex,
    handler: FunctionIndex,
};

pub const Data = op_data: {
    var fields: []const std.builtin.Type.UnionField = &[0]std.builtin.Type.UnionField{};

    var i = 0;

    for (Isa.Instructions) |category| {
        for (category.kinds) |kind| {
            for (kind.instructions) |instruction| {
                const name = Isa.computeInstructionName(kind, instruction);

                var operands: []const std.builtin.Type.StructField = &[0]std.builtin.Type.StructField{};

                if (instruction.operands.len > 0) {
                    var size = 0;
                    var operandCounts = [1]u8{0} ** std.meta.fieldNames(Isa.OperandDescriptor).len;
                    for (instruction.operands) |operand| {
                        const opType = switch (operand) {
                            .register => RegisterIndex,
                            .byte => u8,
                            .short => u16,
                            .immediate => u32,
                            .handler_set_index => HandlerSetIndex,
                            .evidence_index => EvidenceIndex,
                            .global_index => GlobalIndex,
                            .upvalue_index => UpvalueIndex,
                            .function_index => FunctionIndex,
                            .foreign_index => ForeignIndex,
                            .jump_offset => JumpOffset,
                        };

                        size += @bitSizeOf(opType);

                        operands = operands ++ [1]std.builtin.Type.StructField{.{
                            .name = std.fmt.comptimePrint("{u}{}", .{ Isa.getAbbreviation(operand), operandCounts[@intFromEnum(operand)] }),
                            .type = opType,
                            .is_comptime = false,
                            .default_value = null,
                            .alignment = 0,
                        }};

                        operandCounts[@intFromEnum(operand)] += 1;
                    }

                    if (size > 48) {
                        @compileError("Operand set size too large in instruction `" ++ name ++ "`");
                    }

                    const backingType = std.meta.Int(.unsigned, size);
                    const ty = @Type(.{ .@"struct" = .{
                        .layout = .@"packed",
                        .backing_integer = backingType,
                        .fields = operands,
                        .decls = &[0]std.builtin.Type.Declaration{},
                        .is_tuple = false,
                    } });

                    // @compileLog(std.fmt.comptimePrint("{s} {s}", .{name, std.meta.fieldNames(ty)}));

                    fields = fields ++ [1]std.builtin.Type.UnionField{.{
                        .name = name,
                        .type = ty,
                        .alignment = @alignOf(backingType),
                    }};
                } else {
                    fields = fields ++ [1]std.builtin.Type.UnionField{.{
                        .name = name,
                        .type = void,
                        .alignment = 0,
                    }};
                }

                i += 1;
            }
        }
    }

    break :op_data @Type(.{ .@"union" = .{
        .layout = .@"packed",
        .tag_type = null,
        .fields = fields,
        .decls = &[0]std.builtin.Type.Declaration{},
    } });
};

pub const Code = op_code: {
    var fields: []const std.builtin.Type.EnumField = &[0]std.builtin.Type.EnumField{};

    var i: u16 = 0;
    for (Isa.Instructions) |category| {
        for (category.kinds) |kind| {
            for (kind.instructions) |instruction| {
                const name = Isa.computeInstructionName(kind, instruction);
                fields = fields ++ [1]std.builtin.Type.EnumField{.{
                    .name = name,
                    .value = i,
                }};

                i += 1;
            }
        }
    }

    break :op_code @Type(.{ .@"enum" = .{
        .tag_type = u16,
        .fields = fields,
        .decls = &[0]std.builtin.Type.Declaration{},
        .is_exhaustive = true,
    } });
};

pub fn DataOf(comptime code: Code) type {
    @setEvalBranchQuota(2000);
    inline for (std.meta.fieldNames(Code)) |name| {
        if (@field(Code, name) == code) {
            for (std.meta.fields(Data)) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    return field.type;
                }
            }
            unreachable;
        }
    }
    unreachable;
}

pub fn instr(code: Code, data: *const anyopaque) Instruction {
    return Instruction{
        .code = code,
        .data = inline for (comptime std.meta.fieldNames(Code)) |name| {
            if (@field(Code, name) == code) {
                const T = @TypeOf(@field(@as(Data, undefined), name));
                break @unionInit(Data, name, if (T == void) {} else @as(*align(1) const T, @ptrCast(@alignCast(data))).*);
            }
        } else unreachable,
    };
}
