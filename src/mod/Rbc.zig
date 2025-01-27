const std = @import("std");
const Isa = @import("Isa");

pub const Bytecode = @import("Rbc/Bytecode.zig");
pub const Function = @import("Rbc/Function.zig");
pub const Handler = @import("Rbc/Handler.zig");
pub const Info = @import("Rbc/Info.zig");
pub const Op = @import("Rbc/Op.zig");
pub const Print = @import("Rbc/Print.zig");
pub const Program = @import("Rbc/Program.zig");

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
pub const BlockIndex = u16;
pub const LayoutTableSize = RegisterBaseOffset;
pub const FunctionIndex = u16;
pub const HandlerSetIndex = u16;
pub const EvidenceIndex = u16;
pub const MemorySize = u48;
pub const ForeignId = u48;

pub const MAX_BLOCKS: comptime_int = 1024;
pub const MAX_REGISTERS: comptime_int = 255;

pub const EVIDENCE_SENTINEL = std.math.maxInt(EvidenceIndex);
pub const HANDLER_SET_SENTINEL = std.math.maxInt(HandlerSetIndex);
pub const FUNCTION_SENTINEL = std.math.maxInt(FunctionIndex);

pub const Instruction = packed struct {
    code: Op.Code,
    data: Op.Data,
};
