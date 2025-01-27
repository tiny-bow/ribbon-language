const utils = @import("../utils.zig");

const types = @This();

const std = @import("std");



pub fn CopyConst(comptime Dest: type, comptime Src: type) type {
    comptime {
        var DestInfo = @typeInfo(Dest).pointer;
        const SrcInfo = @typeInfo(Src).pointer;

        DestInfo.is_const = SrcInfo.is_const;

        return @Type(.{.pointer = DestInfo});
    }
}

pub fn TupleArray(comptime N: comptime_int, comptime T: type) type {
    comptime var fields = [1]std.builtin.Type.StructField {undefined} ** N;
    inline for (0..N) |i| {
        fields[i] = std.builtin.Type.StructField {
            .name = std.fmt.comptimePrint("{}", .{i}),
            .type = T,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }
    return @Type(.{.@"struct" = std.builtin.Type.Struct {
        .decls = &.{},
        .fields = &fields,
        .is_tuple = true,
        .layout = .auto,
    }});
}

pub fn zero(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .@"struct" => .{},
        .@"union" => .{},
        .pointer => &.{},
        .array => |info| [1]info.child {zero(info.child)} ** info.len,
        .@"enum" => @enumFromInt(0),
        .bool => false,
        else => 0,
    };
}


pub const TypeId = struct {
    typename: [*:0]const u8,

    pub fn of(comptime T: type) TypeId {
        return TypeId { .typename = @typeName(T).ptr };
    }

    pub fn name(self: TypeId) []const u8 {
        return std.mem.span(self.typename);
    }

    pub fn format(self: TypeId, comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) anyerror!void {
        try w.print("{s}", .{self.name()});
    }
};

pub fn isString(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .One) return isString(ptr.child);

            if (ptr.size == .Many or ptr.size == .C) {
                if (ptr.sentinel == null) return false;
            }

            return ptr.child == u8;
        },
        .array => |arr| {
            return arr.child == u8;
        },
        else => return false,
    }
}

pub fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.is_tuple,
        else => false,
    };
}

pub fn ToBytes(comptime T: type) type {
    return [@sizeOf(T)] u8;
}

pub fn DropSelf(comptime T: type, comptime ArgsTuple: type) type {
    const info = @typeInfo(ArgsTuple).@"struct";
    if (hasSelf(T, ArgsTuple)) {
        return @Type(.{.@"struct" = std.builtin.Type.Struct {
            .decls = &.{},
            .fields = if (info.is_tuple) adjustFields: {
                var newFields = [1]std.builtin.Type.StructField {undefined} ** (info.fields.len - 1);
                for (info.fields[1..], 0..) |field, i| {
                    newFields[i] = std.builtin.Type.StructField {
                        .alignment = field.alignment,
                        .default_value = field.default_value,
                        .is_comptime = field.is_comptime,
                        .name = std.fmt.comptimePrint("{}", .{i}),
                        .type = field.type,
                    };
                }
                break :adjustFields &newFields;
            } else info.fields[1..],
            .is_tuple = info.is_tuple,
            .layout = info.layout,
        }});
    }
    return ArgsTuple;
}

pub fn hasSelf(comptime T: type, comptime ArgsTuple: type) bool {
    const info = @typeInfo(ArgsTuple).@"struct";
    const field0 = info.fields[0];
    const fInfo = @typeInfo(field0.type);
    return std.mem.eql(u8, field0.name, "self")
        or if (fInfo == .pointer) ptr: {
            break :ptr fInfo.pointer.child == T;
        } else false;
}

pub fn supportsDecls(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

pub fn causesErrors(comptime T: type) bool {
    comptime var info = @typeInfo(T);
    if (comptime info == .pointer) info = @typeInfo(info.pointer.child);
    if (comptime info != .@"fn") return false;
    return @typeInfo(info.@"fn".return_type.?) == .error_union;
}

pub fn isInErrorSet(comptime E: type, err: anyerror) bool {
    if (err == error.Unknown) return false;

    const es = @typeInfo(E).error_set
        orelse [0]std.builtin.Type.Error {};

    inline for (es) |e| {
        const err2 = @field(E, e.name);
        if (err == err2) return true;
    }

    return false;
}

pub fn narrowErrorSet(comptime E: type, err: anyerror) ?E {
    if (err == error.Unknown) return null;

    const es = @typeInfo(E).error_set
        orelse [0]std.builtin.Type.Error {};

    inline for (es) |e| {
        const err2 = @field(E, e.name);
        if (err == err2) return err2;
    }

    return null;
}

pub fn forceErrorSet(comptime E: type, err: anyerror) E {
    const buf = &struct{ threadlocal var x = [1]u8{0} ** 128; }.x;
    return narrowErrorSet(E, err)
        orelse @panic(std.fmt.bufPrint(buf, "unexpected error {s}", .{@errorName(err)}) catch buf);
}

const MAX_DECLS = 10_000;

pub fn structConcat(subs: anytype) TypeOfStructConcat(@TypeOf(subs)) {
    const Out = TypeOfStructConcat(@TypeOf(subs));

    var full: Out = undefined;
    comptime var fullIndex: comptime_int = 0;

    const fullFields = comptime std.meta.fieldNames(Out);

    inline for (0..subs.len) |i| {
        const structData = subs[i];

        const structFields = comptime std.meta.fieldNames(@TypeOf(structData));

        inline for (structFields) |structFieldName| {
            @field(full, fullFields[fullIndex]) = @field(structData, structFieldName);
            fullIndex += 1;
        }
    }

    return full;
}

pub fn StructConcat(comptime subs: anytype) type {
    comptime var fullFields = ([1]std.builtin.Type.StructField {undefined}) ** MAX_DECLS;
    comptime var fullIndex: comptime_int = 0;

    var tuple = false;

    if (subs.len > 0) {
        const firstT = subs[0];
        const firstInfo = @typeInfo(firstT);
        if (firstInfo != .@"struct") {
            @compileLog(firstT);
            @compileError("Expected struct for struct concat");
        }
        tuple = firstInfo.@"struct".is_tuple;

        for (subs) |structT| {
            const structInfo = @typeInfo(structT);

            if (structInfo != .@"struct") {
                @compileLog(structT);
                @compileError("Expected struct for struct concat");
            }

            const structFields = structInfo.@"struct".fields;

            if (structInfo.@"struct".is_tuple != tuple) {
                if (structFields.len != 0) {
                    @compileLog(firstT, tuple);
                    @compileLog(structT, structInfo.@"struct".is_tuple);
                    @compileError("Expected all fields to have the same tuple-ness");
                }
            }

            for (structFields) |structField| {
                fullFields[fullIndex] = std.builtin.Type.StructField {
                    .name = if (tuple) std.fmt.comptimePrint("{}", .{fullIndex}) else structField.name,
                    .type = structField.type,
                    .default_value = structField.default_value,
                    .is_comptime = false,
                    .alignment = @alignOf(structField.type),
                };

                fullIndex += 1;
            }
        }
    }

    return @Type(std.builtin.Type { .@"struct" = .{
        .layout = .auto,
        .backing_integer = null,
        .fields = fullFields[0..fullIndex],
        .decls = &[0]std.builtin.Type.Declaration {},
        .is_tuple = tuple,
    } });
}

pub fn TypeOfStructConcat(comptime subs: type) type {
    comptime var fullFields = ([1]std.builtin.Type.StructField {undefined}) ** MAX_DECLS;
    comptime var fullIndex: comptime_int = 0;

    const subsInfo = @typeInfo(subs);
    if (subsInfo != .@"struct" or !subsInfo.@"struct".is_tuple) {
        @compileLog(subs);
        @compileError("Expected tuple struct for struct concat");
    }
    const subsFields = subsInfo.@"struct".fields;

    var tuple = false;

    if (subsFields.len > 0) {
        const firstT = subsFields[0].type;
        const firstInfo = @typeInfo(firstT);
        if (firstInfo != .@"struct") {
            @compileLog(firstT);
            @compileError("Expected struct for struct concat");
        }
        tuple = firstInfo.@"struct".is_tuple;

        for (subsFields) |sub| {
            const structT = sub.type;
            const structInfo = @typeInfo(structT);

            if (structInfo != .@"struct") {
                @compileLog(structT);
                @compileError("Expected struct for struct concat");
            }

            const structFields = structInfo.@"struct".fields;

            if (structInfo.@"struct".is_tuple != tuple) {
                if (structFields.len != 0) {
                    @compileLog(firstT, tuple);
                    @compileLog(structT, structInfo.@"struct".is_tuple);
                    @compileError("Expected all fields to have the same tuple-ness");
                }
            }

            for (structFields) |structField| {
                fullFields[fullIndex] = std.builtin.Type.StructField {
                    .name = if (tuple) std.fmt.comptimePrint("{}", .{fullIndex}) else structField.name,
                    .type = structField.type,
                    .default_value = structField.default_value,
                    .is_comptime = false,
                    .alignment = @alignOf(structField.type),
                };

                fullIndex += 1;
            }
        }
    }

    return @Type(std.builtin.Type { .@"struct" = .{
        .layout = .auto,
        .backing_integer = null,
        .fields = fullFields[0..fullIndex],
        .decls = &[0]std.builtin.Type.Declaration {},
        .is_tuple = tuple,
    } });
}
