const Rml = @import("../Rml.zig");

const bindgen = @This();

const std = @import("std");
const utils = @import("utils");



pub fn bindGlobals(rml: *Rml, env: Rml.Obj(Rml.Env), comptime globals: type) (Rml.OOM || Rml.SymbolAlreadyBound)! void {
    inline for (comptime std.meta.declarations(globals)) |field| {
        const symbol: Rml.Obj(Rml.Symbol) = try .wrap(rml, rml.data.origin, try .create(rml, field.name));
        const object = try toObjectConst(rml, rml.data.origin, &@field(globals, field.name));

        try env.data.bind(symbol, object.typeErase());
    }
}


pub fn bindObjectNamespaces(rml: *Rml, env: Rml.Obj(Rml.Env), comptime namespaces: anytype) (Rml.OOM || Rml.SymbolAlreadyBound)! void {
    inline for (comptime std.meta.fields(@TypeOf(namespaces))) |field| {
        const builtinEnv: Rml.Obj(Rml.Env) = try .wrap(rml, rml.data.origin, .{.allocator = rml.blobAllocator()});
        const Ns = Namespace(@field(namespaces, field.name));

        const methods = try Ns.methods(rml, rml.data.origin);

        try builtinEnv.data.bindNamespace(methods);
        const sym: Rml.Obj(Rml.Symbol) = try .wrap(rml, rml.data.origin, try .create(rml, field.name));

        try env.data.bind(sym, builtinEnv.typeErase());
    }
}


pub fn Support (comptime T: type) type {
    return struct {
        pub const onCompare = switch (@typeInfo(T)) {
            else => struct {
                pub fn onCompare(a: *const T, obj: Rml.Object) utils.Ordering {
                    var ord = utils.compare(Rml.getTypeId(a), obj.getTypeId());

                    if (ord == .Equal) {
                        ord = utils.compare(a.*, Rml.forceObj(T, obj).data.*);
                    }

                    return ord;
                }
            }
        }.onCompare;

        pub const onFormat = switch (T) {
            Rml.Char => struct {
                pub fn onFormat(self: *const T, fmt: Rml.Format, writer: std.io.AnyWriter) anyerror! void {
                    switch (fmt) {
                        .message => try writer.print("{u}", .{self.*}),
                        inline else => {
                            var buf = [1]u8{0} ** 4;
                            const out = utils.text.escape(self.*, .Single, &buf) catch "[@INVALID BYTE@]";
                            try writer.print("'{s}'", .{out});
                        }
                    }
                }
            },
            else => switch(@typeInfo(T)) {
                .pointer => |info| if (@typeInfo(info.child) == .@"fn") struct {
                    pub fn onFormat(self: *const T, _: Rml.Format, writer: std.io.AnyWriter) anyerror! void {
                        try writer.print("[native-function {s} {x}]", .{fmtNativeType(T), @intFromPtr(self)});
                    }
                } else struct {
                    pub fn onFormat(self: *const T, _: Rml.Format, writer: std.io.AnyWriter) anyerror! void {
                        try writer.print("[native-{s} {x}]", .{@typeName(T), @intFromPtr(self)});
                    }
                },
                .array => |info| struct {
                    pub fn onFormat(self: *const T, fmt: Rml.Format, writer: std.io.AnyWriter) anyerror! void {
                        try writer.writeAll("{");
                        for (self, 0..) |elem, i| {
                            try elem.onFormat(fmt, writer);
                            if (i < info.len - 1) try writer.writeAll("  ");
                        }
                        try writer.writeAll("}");
                    }
                },
                else =>
                    if (std.meta.hasFn(T, "format")) struct {
                        pub fn onFormat(self: *const T, fmt: Rml.Format, writer: std.io.AnyWriter) anyerror! void {
                            inline for (comptime std.meta.fieldNames(Rml.Format)) |fmtName| {
                                const field = comptime @field(Rml.Format, fmtName);
                                if (field == fmt) {
                                    return @call(.always_inline, T.format, .{self, @tagName(field), .{}, writer});
                                }
                            }
                            unreachable;
                        }
                    } else struct {
                        pub fn onFormat(self: *const T, _: Rml.Format, writer: std.io.AnyWriter) anyerror! void {
                            return writer.print("{any}", .{self.*});
                        }
                    }
                ,
            },
        }.onFormat;
    };
}

pub const VTABLE_METHOD_NAMES
     = std.meta.fieldNames(Rml.object.VTable.ObjDataFunctions)
    ++ std.meta.fieldNames(Rml.object.VTable.ObjMemoryFunctions)
    ++ .{"onInit"};

pub fn isVTableMethodName(name: []const u8) bool {
    for (VTABLE_METHOD_NAMES) |vtableName| {
        if (std.mem.eql(u8, name, vtableName)) return true;
    }
    return false;
}


pub const NativeFunction = *const fn (*Rml.Interpreter, Rml.Origin, []const Rml.Object) Rml.Result! Rml.Object;

inline fn onAList(comptime T: type, comptime fieldName: []const u8) bool {
    comptime {
        const alist: []const []const u8 =
            if (@hasDecl(T, "BINDGEN_ALLOW")) T.BINDGEN_ALLOW
            else return true;

        for (alist) |name| {
            if (std.mem.eql(u8, name, fieldName)) return true;
        }

        return false;
    }
}

inline fn onDList(comptime T: type, comptime fieldName: []const u8) bool {
    comptime {
        const dlist: []const []const u8 =
            if (@hasDecl(T, "BINDGEN_DENY")) T.BINDGEN_DENY
            else return false;

        for (dlist) |name| {
            if (std.mem.eql(u8, name, fieldName)) return true;
        }

        return false;
    }
}

pub fn Namespace(comptime T: type) type {
    @setEvalBranchQuota(10_000);

    const BaseMethods = BaseMethods: {
        if (!utils.types.supportsDecls(T)) break :BaseMethods @Type(.{.@"struct" = std.builtin.Type.Struct {
            .layout = .auto,
            .fields = &.{},
            .decls = &.{},
            .is_tuple = false,
        }});

        const Api = Api: {
            const ApiEntry = struct { type: type, name: [:0]const u8 };
            const decls = std.meta.declarations(T);

            var entries = [1]ApiEntry {undefined} ** decls.len;
            var i = 0;


            for (decls) |decl| {
                if (std.meta.hasFn(T, decl.name)
                and !isVTableMethodName(decl.name)
                and onAList(T, decl.name)
                and !onDList(T, decl.name)) {
                    const F = @TypeOf(@field(T, decl.name));
                    if (@typeInfo(F) != .@"fn") continue;
                    const fInfo = @typeInfo(F).@"fn";
                    if (fInfo.is_generic or fInfo.is_var_args) continue;
                    entries[i] = ApiEntry {
                        .type = F,
                        .name = decl.name,
                    };
                    i += 1;
                }
            }

            break :Api entries[0..i];
        };

        var fields = [1] std.builtin.Type.StructField {undefined} ** Api.len;
        for (Api, 0..) |apiEntry, i| {
            const fInfo = @typeInfo(apiEntry.type).@"fn";

            const GenericType = generic: {
                break :generic @Type(.{.@"fn" = std.builtin.Type.Fn {
                    .calling_convention = .auto,
                    .is_generic = false,
                    .is_var_args = false,
                    .return_type = ret_type: {
                        const R = fInfo.return_type.?;
                        const rInfo = @typeInfo(R);
                        if (rInfo != .error_union) break :ret_type R;
                        break :ret_type @Type(.{.error_union = std.builtin.Type.ErrorUnion {
                            .error_set = Rml.Result,
                            .payload = rInfo.error_union.payload,
                        }});
                    },
                    .params = fInfo.params,
                }});
            };

            fields[i] = std.builtin.Type.StructField {
                .name = apiEntry.name,
                .type = *const GenericType,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(*const fn () void),
            };
        }

        break :BaseMethods @Type(.{.@"struct" = std.builtin.Type.Struct {
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        }});
    };

    const baseMethods = baseMethods: {
        var ms: BaseMethods = undefined;
        for (std.meta.fields(BaseMethods)) |field| {
            @field(ms, field.name) = @as(field.type, @ptrCast(&@field(T, field.name)));
        }
        break :baseMethods ms;
    };

    const Methods = Methods: {
        var fields = [1] std.builtin.Type.StructField {undefined} ** std.meta.fields(BaseMethods).len;

        for (std.meta.fields(BaseMethods), 0..) |field, fieldIndex| {
            fields[fieldIndex] = std.builtin.Type.StructField {
                .name = field.name,
                .type = Rml.Obj(Rml.Procedure),
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(*const fn () void),
            };
        }

        break :Methods @Type(.{.@"struct" = std.builtin.Type.Struct {
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        }});
    };

    return struct {
        pub fn methods(rml: *Rml, origin: Rml.Origin) Rml.OOM! Methods {
            var ms: Methods = undefined;

            inline for (comptime std.meta.fieldNames(Methods)) |fieldName| {
                @field(ms, fieldName) = try wrapNativeFunction(rml, origin, @field(baseMethods, fieldName));
            }

            return ms;
        }
    };
}

pub fn fromObject(comptime T: type, _: *Rml, value: Rml.Object) Rml.Error! T {
    const tInfo = @typeInfo(T);

    switch (tInfo) {
        .pointer => |info| {
            if (info.size == .One and comptime Rml.isBuiltinType(info.child)) {
                if (!utils.equal(Rml.TypeId.of(info.child), value.getTypeId())) {
                    Rml.log.warn("expected {s} got {s}", .{@typeName(info.child), Rml.TypeId.name(value.getTypeId())});
                    return error.TypeError;
                }

                const obj = Rml.forceObj(info.child, value);
                return obj.data;
            } else {
                const obj = Rml.castObj(T, value) orelse return error.TypeError;
                return obj.data.*;
            }
        },
        else => {
            if (T == Rml.Object) {
                return value;
            } else if (comptime std.mem.startsWith(u8, @typeName(T), "Rml.object.Obj")) {
                const O = @typeInfo(tInfo.@"struct".fields[0].type).pointer.child;

                if (!utils.equal(Rml.TypeId.of(O), value.getTypeId())) {
                    return error.TypeError;
                }

                const obj = Rml.forceObj(O, value);
                return obj;
            } else {
                const obj = Rml.forceObj(T, value);
                return obj.data.*;
            }
        },
    }
}

pub fn ObjectRepr(comptime T: type) type {
    const tInfo = @typeInfo(T);
    return switch (T) {
        Rml.Object => Rml.Object,
        Rml.Int => Rml.Obj(Rml.Int),
        Rml.Float => Rml.Obj(Rml.Float),
        Rml.Char => Rml.Obj(Rml.Char),
        NativeFunction => Rml.Obj(Rml.Procedure),
        else => switch (tInfo) {
            .bool => Rml.Obj(Rml.Bool),

            .void, .null, .undefined, .noreturn
                => Rml.Obj(Rml.Nil),

            .int, .float, .error_set, .error_union, .@"enum", .@"opaque", .enum_literal, .array, .vector,
                => Rml.Obj(T),

            .pointer => |info|
                if (@typeInfo(info.child) == .@"fn") Rml.Obj(Rml.Procedure)
                else if (info.size == .One and Rml.isBuiltinType(info.child)) Rml.Obj(info.child)
                    else Rml.Obj(T),

            .@"struct" =>
                if (std.mem.startsWith(u8, @typeName(T), "Rml.object.Obj")) T
                else Rml.Obj(T),

            .@"union" => Rml.Obj(T),

            .@"fn" => Rml.Obj(Rml.Procedure),

            .optional => Rml.Object,

            else => @compileError("unsupported return type: " ++ @typeName(T)),
        }
    };
}

pub fn toObject(rml: *Rml, origin: Rml.Origin, value: anytype) Rml.OOM! ObjectRepr(@TypeOf(value)) {
    const T = @TypeOf(value);
    const tInfo = @typeInfo(T);
    return switch (T) {
        Rml.Nil => Rml.Obj(Rml.Nil).wrap(rml, origin, value),
        Rml.Int => Rml.Obj(Rml.Int).wrap(rml, origin, value),
        Rml.Float => Rml.Obj(Rml.Float).wrap(rml, origin, value),
        Rml.Char => Rml.Obj(Rml.Char).wrap(rml, origin, value),
        Rml.str => Rml.Obj(Rml.str).wrap(rml, origin, value),
        Rml.Object => return value,
        NativeFunction => Rml.Obj(Rml.Procedure).wrap(rml, origin, .{ .native = value }),
        else => switch (tInfo) {
            .bool =>
                Rml.Obj(Rml.Bool).wrap(rml, origin, value),

            .void, .null, .undefined, .noreturn, =>
                Rml.Obj(Rml.Nil).wrap(rml, origin, Rml.Nil{}),

            .int, .float, .error_set, .error_union, .@"enum",
            .@"opaque", .enum_literal, .array, .vector, =>
                Rml.Obj(T).wrap(rml, origin, value),

            .pointer => |info|
                if (@typeInfo(info.child) == .@"fn") @compileError("wrap functions with wrapNativeFunction")
                else if (comptime info.size == .One and Rml.isBuiltinType(info.child)) Rml.Obj(T).wrap(rml, origin, value.*)
                    else Rml.Obj(T).wrap(rml, origin, value),

            .@"struct" =>
                if (comptime std.mem.startsWith(u8, @typeName(T), "Rml.object.Obj")) value
                else Rml.Obj(T).wrap(rml, origin, value),

            .@"union" =>
                Rml.Obj(T).wrap(rml, origin, value),

            .optional =>
                if (value) |v| v: {
                    const x = try toObject(rml, origin, v);
                    break :v x.typeErase();
                } else nil: {
                    const x = try Rml.Obj(Rml.Nil).wrap(rml, origin, Rml.Nil{});
                    break :nil x.typeErase();
                },

            else => @compileError("unsupported type: " ++ @typeName(T)),
        }
    };
}

pub fn toObjectConst(rml: *Rml, origin: Rml.Origin, comptime value: anytype) Rml.OOM! ObjectRepr(@TypeOf(value)) {
    const T = @TypeOf(value);
    const tInfo = @typeInfo(T);
    return switch (T) {
        Rml.Nil => Rml.Obj(Rml.Nil).wrap(rml, origin, value),
        Rml.Int => Rml.Obj(Rml.Int).wrap(rml, origin, value),
        Rml.Float => Rml.Obj(Rml.Float).wrap(rml, origin, value),
        Rml.Char => Rml.Obj(Rml.Char).wrap(rml, origin, value),
        Rml.str => Rml.Obj([]const u8).wrap(rml, origin, value),
        Rml.Object => value.clone(),
        NativeFunction => Rml.Obj(Rml.Procedure).wrap(rml, origin, .{ .native_function = value }),
        else => switch (tInfo) {
            .bool =>
                Rml.Obj(Rml.Bool).wrap(rml, origin, value),

            .void, .null, .undefined, .noreturn, =>
                Rml.Obj(Rml.Nil).wrap(rml, origin, Rml.Nil{}),

            .int, .float, .error_set, .error_union, .@"enum",
            .@"opaque", .enum_literal, .array, .vector, =>
                Rml.Obj(T).wrap(rml, origin, value),

            .pointer => |info|
                if (@typeInfo(info.child) == .@"fn") wrapNativeFunction(rml, origin, value)
                else if (comptime info.size == .One and Rml.isBuiltinType(info.child)) Rml.Obj(info.child).wrap(rml, origin, value.*)
                    else { // TODO: remove compileError when not frequently adding builtins
                        @compileError(std.fmt.comptimePrint("not builtin type {} {}", .{info, Rml.isBuiltinType(info.child)}));
                        // break :x Rml.Obj(T).wrap(rml, origin, value);
                    },

            .@"struct", .@"union", =>
                if (comptime std.mem.startsWith(u8, @typeName(T), "Rml.object.Obj")) value
                else Rml.Obj(T).wrap(rml, origin, value),

            .optional =>
                if (value) |v| v: {
                    const x = try toObject(rml, origin, v);
                    break :v x.typeErase();
                } else nil: {
                    const x = try Rml.Obj(Rml.Nil).wrap(rml, origin, Rml.Nil{});
                    break :nil x.typeErase();
                },

            else => @compileError("unsupported type: " ++ @typeName(T)),
        }
    };
}


pub fn wrapNativeFunction(rml: *Rml, origin: Rml.Origin, comptime nativeFunc: anytype) Rml.OOM! Rml.Obj(Rml.Procedure) {
    if (@TypeOf(nativeFunc) == NativeFunction) {
        return Rml.Obj(Rml.Procedure).wrap(rml, origin, .{.native_function = nativeFunc});
    }

    const T = @typeInfo(@TypeOf(nativeFunc)).pointer.child;
    const info = @typeInfo(T).@"fn";

    return Rml.Obj(Rml.Procedure).wrap(rml, origin, .{ .native_function = &struct {
        pub fn method (interpreter: *Rml.Interpreter, callOrigin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
            // Rml.log.debug("native wrapper", .{});

            if (args.len != info.params.len) {
                try interpreter.abort(callOrigin, error.InvalidArgumentCount, "expected {} arguments, got {}", .{info.params.len, args.len});
            }

            var nativeArgs: std.meta.ArgsTuple(T) = undefined;

            inline for (info.params, 0..) |param, i| {
                nativeArgs[i] = fromObject(param.type.?, Rml.getRml(interpreter), args[i]) catch |err| {
                    try interpreter.abort(callOrigin, err, "failed to convert argument {} from rml {} to native {s}", .{i, args[i], @typeName(@TypeOf(nativeArgs[i]))});
                };
            }

            const nativeResult = nativeResult: {
                // Rml.log.debug("calling native function", .{});
                const r = @call(.auto, nativeFunc, nativeArgs);
                break :nativeResult if (comptime utils.types.causesErrors(T)) try r else r;
            };

            // Rml.log.debug("native function returned {any}", .{nativeResult});

            const objWrapper = toObject(Rml.getRml(interpreter), callOrigin, nativeResult) catch |err| {
                try interpreter.abort(callOrigin, err, "failed to convert result from native to rml", .{});
            };

            return objWrapper.typeErase();
        }
    }.method });
}


pub const TypeId = struct {
    typename: [*:0]const u8,

    pub fn of(comptime T: type) TypeId {
        return TypeId { .typename = fmtNativeType(T) };
    }

    pub fn name(self: TypeId) []const u8 {
        return std.mem.span(self.typename);
    }

    pub fn format(self: TypeId, comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) anyerror!void {
        try w.print("{s}", .{self.name()});
    }
};

pub fn fmtNativeType(comptime T: type) [:0]const u8 {
    return comptime switch(T) {
        else =>
            if (Rml.isBuiltinType(T)) &fmtBuiltinTypeName(T)
            else switch (@typeInfo(T)) {
                .void, .null, .undefined, .noreturn => "Nil",
                .@"opaque" => "Opaque",
                .bool => "Bool",
                .int => |info| std.fmt.comptimePrint("{u}{}", .{switch (info.signedness) { .signed => 'S', .unsigned => 'U' }, info.bits}),
                .float => |info| std.fmt.comptimePrint("F{}", .{info.bits}),
                .error_set => "Error",
                .error_union => |info| fmtNativeType(info.error_set) ++ "! " ++ fmtNativeType(info.payload),
                .pointer => |info|
                    if (@typeInfo(info.child) == .@"fn") fmtNativeType(info.child)
                    else switch (info.size) {
                        .C, .One, .Many =>
                            if (info.alignment == Rml.object.OBJ_ALIGN) fmtNativeType(info.child)
                            else "*" ++ fmtNativeType(info.child),
                        .Slice => "[]" ++ fmtNativeType(info.child),
                    },
                .array => |info| std.fmt.comptimePrint("[{}]", .{info.len} ++ fmtNativeType(info.child)),
                .vector => |info| std.fmt.comptimePrint("<{}>", .{info.len} ++ fmtNativeType(info.child)),
                .optional => |info| "?" ++ fmtNativeType(info.child),
                .@"struct" => &fmtTypeName(T),
                .@"enum" => &fmtTypeName(T),
                .@"union" => &fmtTypeName(T),
                .@"fn" => |info| fun: {
                    var x: []const u8 = "(";

                    for (info.params) |param| {
                        x = x ++ fmtNativeType(param.type.?) ++ " ";
                    }

                    x = x ++ "-> " ++ fmtNativeType(info.return_type.?);

                    break :fun x ++ ")";
                },
                .enum_literal => "Symbol",
                else => fmtTypeName(T),
            }
    };
}

pub fn builtinTypeNameLen(comptime T: type) usize {
    comptime {
        for (std.meta.fieldNames(@TypeOf(Rml.builtin.types))) |builtinName| {
            const builtin = @field(Rml.builtin.types, builtinName);
            if (builtin == T) return builtinName.len;
        }

        @compileError("fmtBuiltinTypeName: " ++ @typeName(T) ++ " is not a builtin type");
    }
}

pub fn fmtBuiltinTypeName(comptime T: type) [builtinTypeNameLen(T):0] u8 {
    comptime {
        for (std.meta.fieldNames(@TypeOf(Rml.builtin.types))) |builtinName| {
            const builtin = @field(Rml.builtin.types, builtinName);
            if (builtin == T) return @as(*const [builtinTypeNameLen(T):0] u8, @ptrCast(builtinName.ptr)).*;
        }

        @compileError("fmtBuiltinTypeName: " ++ @typeName(T) ++ " is not a builtin type");
    }
}

pub fn typeNameLen(comptime T: type) usize {
    comptime return
        if (Rml.isBuiltinType(T)) builtinTypeNameLen(T)
        else externTypeNameLen(T)
    ;
}

pub const NATIVE_PREFIX = "native:";

pub fn externTypeNameLen(comptime T: type) usize {
    comptime return
        if (Rml.isBuiltinType(T)) @compileError("externTypeNameLen used with builtin type")
        else @typeName(T).len + NATIVE_PREFIX.len
    ;
}

pub fn fmtExternTypeName(comptime T: type) [externTypeNameLen(T):0]u8 {
    @setEvalBranchQuota(10_000);

    comptime
        if (Rml.isBuiltinType(T)) @compileLog("fmtExternTypeName used with builtin type")
        else {
            const baseName = @typeName(T).*;
            var outName = std.mem.zeroes([externTypeNameLen(T):0]u8);
            for (NATIVE_PREFIX, 0..) |c, i| {
                outName[i] = c;
            }

            for (baseName, 0..) |c, i| {
                if (c == '.') {
                    outName[i + NATIVE_PREFIX.len] = '/';
                } else if (std.mem.indexOfScalar(u8, "()[]{}", c) != null) {
                    outName[i + NATIVE_PREFIX.len] = '_';
                } else {
                    outName[i + NATIVE_PREFIX.len] = c;
                }
            }

            return outName;
        };
}

pub fn fmtTypeName(comptime T: type) [typeNameLen(T):0]u8 {
    comptime return
        if (Rml.isBuiltinType(T)) fmtBuiltinTypeName(T)
        else fmtExternTypeName(T)
    ;
}
