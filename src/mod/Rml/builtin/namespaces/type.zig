const Rml = @import("../../../Rml.zig");

const std = @import("std");
const utils = @import("utils");



/// Get the type of an object
pub fn @"of"(obj: Rml.Object) Rml.OOM! Rml.Obj(Rml.Symbol) {
    const id = obj.getTypeId();

    return .wrap(obj.getRml(), obj.getOrigin(), try .create(obj.getRml(), id.name()));
}

/// Determine if an object is of type `nil`
pub fn @"nil?"(obj: Rml.Object) Rml.Bool {
    Rml.log.warn("Nil? {}", .{obj});
    return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Nil));
}

/// Determine if an object is of type `bool`
pub fn @"bool?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Bool)); }

/// Determine if an object is of type `int`
pub fn @"int?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Int)); }

/// Determine if an object is of type `float`
pub fn @"float?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Float)); }

/// Determine if an object is of type `char`
pub fn @"char?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Char)); }

/// Determine if an object is of type `string`
pub fn @"string?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.String)); }

/// Determine if an object is of type `symbol`
pub fn @"symbol?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Symbol)); }

/// Determine if an object is a procedure
pub fn @"procedure?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Procedure)); }

/// Determine if an object is an interpreter
pub fn @"interpreter?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Interpreter)); }

/// Determine if an object is a parser
pub fn @"parser?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Parser)); }

/// Determine if an object is a pattern
pub fn @"pattern?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Pattern)); }

/// Determine if an object is a writer
pub fn @"writer?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Writer)); }

/// Determine if an object is a cell
pub fn @"cell?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Cell)); }

/// Determine if an object is a block
pub fn @"block?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Block)); }

/// Determine if an object is a quote
pub fn @"quote?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Quote)); }

/// Determine if an object is an environment
pub fn @"env?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Env)); }

/// Determine if an object is a map
pub fn @"map?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Map)); }

/// Determine if an object is a set
pub fn @"set?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Set)); }

/// Determine if an object is an array
pub fn @"array?"(obj: Rml.Object) Rml.Bool { return utils.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Array)); }
