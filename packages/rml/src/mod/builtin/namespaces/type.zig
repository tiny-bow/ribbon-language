const Rml = @import("../../root.zig");

pub fn @"of"(obj: Rml.Object) Rml.OOM! Rml.Obj(Rml.Symbol) {
    const id = obj.getTypeId();

    return .wrap(obj.getRml(), obj.getOrigin(), try .create(obj.getRml(), id.name()));
}

pub fn @"nil?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Nil)); }
pub fn @"bool?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Bool)); }
pub fn @"int?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Int)); }
pub fn @"float?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Float)); }
pub fn @"char?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Char)); }
pub fn @"string?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.String)); }
pub fn @"symbol?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Symbol)); }
pub fn @"procedure?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Procedure)); }
pub fn @"interpreter?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Interpreter)); }
pub fn @"parser?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Parser)); }
pub fn @"pattern?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Pattern)); }
pub fn @"writer?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Writer)); }
pub fn @"cell?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Cell)); }
pub fn @"block?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Block)); }
pub fn @"quote?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Quote)); }
pub fn @"env?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Env)); }
pub fn @"map?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Map)); }
pub fn @"set?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Set)); }
pub fn @"array?"(obj: Rml.Object) Rml.Bool { return Rml.equal(obj.getTypeId(), Rml.TypeId.of(Rml.Array)); }
