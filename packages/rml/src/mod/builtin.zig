const TypeUtils = @import("Utils").Type;

const Rml = @import("root.zig");

pub const global = @import("builtin/global.zig");

pub const namespaces = .{
    .text = @import("builtin/namespaces/text.zig"),
    .type = @import("builtin/namespaces/type.zig"),
};


pub const types = TypeUtils.structConcat(.{value_types, object_types});

pub const value_types = TypeUtils.structConcat(.{atom_types, data_types});

pub const atom_types = .{
    .Nil = Rml.Nil,
    .Bool = Rml.Bool,
    .Int = Rml.Int,
    .Float = Rml.Float,
    .Char = Rml.Char,
    .String = Rml.String,
    .Symbol = Rml.Symbol,
};

pub const data_types = .{
    .Procedure = Rml.Procedure,
    .Interpreter = Rml.Interpreter,
    .Parser = Rml.Parser,
    .Pattern = Rml.Pattern,
    .Writer = Rml.Writer,
    .Cell = Rml.Cell,
};

pub const object_types = TypeUtils.structConcat(.{source_types, collection_types});

pub const source_types = .{
    .Block = Rml.Block,
    .Quote = Rml.Quote,
};

pub const collection_types = .{
    .Env = Rml.Env,
    .Map = Rml.Map,
    .Set = Rml.Set,
    .Array = Rml.Array,
};
