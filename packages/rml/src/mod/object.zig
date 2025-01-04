const std = @import("std");
const MiscUtils = @import("Utils").Misc;
const TypeUtils = @import("Utils").Type;

const dispatch = std.log.scoped(.@"object-dispatch");

const Rml = @import("root.zig");
const Nil = Rml.Nil;
const Bool = Rml.Bool;
const bindgen = Rml.bindgen;
const Error = Rml.Error;
const Ordering = Rml.Ordering;
const OOM = Rml.OOM;
const log = Rml.log;
const TypeId = Rml.TypeId;
const map = Rml.map;
const Writer = Rml.Writer;
const Symbol = Rml.Symbol;
const Origin = Rml.Origin;


pub const OBJ_ALIGN = 16;

pub const ObjData = extern struct { data: u8 align(OBJ_ALIGN) };
pub fn ptr(comptime T: type) type { return *align(OBJ_ALIGN) T; }
pub fn const_ptr(comptime T: type) type { return *const align(OBJ_ALIGN) T; }

pub const PropertySet = map.MapUnmanaged;

pub const Header = struct {
    rml: *Rml,
    blob_id: Rml.Storage.BlobId,
    type_id: TypeId,
    vtable: *const VTable,
    origin: Origin,
    properties: PropertySet,

    pub fn onInit(self: ptr(Header), comptime T: type, rml: *Rml, origin: Origin) void {
        self.* = Header {
            .rml = rml,
            .blob_id = rml.blobId(),
            .type_id = TypeId.of(T),
            .vtable = VTable.of(T),
            .origin = origin,
            .properties = .{},
        };
    }

    pub fn onCompare(self: ptr(Header), other: ptr(Header)) Ordering {
        const obj = other.getObject();
        return self.vtable.onCompare(self, obj);
    }

    pub fn onFormat(self: ptr(Header), writer: std.io.AnyWriter) Error! void {
        return self.vtable.onFormat(self, writer) catch |err| Rml.errorCast(err);
    }

    pub fn getObject(self: ptr(Header)) Object {
        return getObj(self.getData());
    }

    pub fn getObjMemory(self: ptr(Header)) *ObjMemory(ObjData) {
        return @fieldParentPtr("header", @as(ptr(TypeUtils.ToBytes(Header)), @ptrCast(self)));
    }

    pub fn getData(self: ptr(Header)) ptr(ObjData) {
        return self.getObjMemory().getData();
    }
};


pub const VTable = struct {
    obj_memory: ObjMemoryFunctions,
    obj_data: ObjDataFunctions,

    pub const ObjMemoryFunctions = struct { };

    pub const ObjDataFunctions = struct {
        onCompare: ?*const fn (const_ptr(ObjData), Rml.Object) Ordering = null,
        onFormat: ?*const fn (const_ptr(ObjData), std.io.AnyWriter) anyerror! void = null,
    };

    pub fn of(comptime T: type) *const VTable {
        if (comptime T == ObjData) return undefined;

        const x = struct {
            const vtable = VTable {
                .obj_memory = obj_memory: {
                    var functionSet: ObjMemoryFunctions = .{};

                    for (std.meta.fields(ObjMemoryFunctions)) |field| {
                        const funcName = field.name;

                        const G = @typeInfo(@typeInfo(field.type).optional.child).pointer.child;
                        const gInfo = @typeInfo(G).@"fn";

                        const F = @TypeOf(@field(ObjMemory(T), funcName));
                        const fInfo = @typeInfo(F).@"fn";

                        std.debug.assert(!fInfo.is_generic);
                        std.debug.assert(!fInfo.is_var_args);
                        std.debug.assert(fInfo.return_type.? == gInfo.return_type.?);
                        std.debug.assert(fInfo.params.len == gInfo.params.len);

                        @field(functionSet, funcName) = @ptrCast(&@field(ObjMemory(T), funcName));
                    }

                    break :obj_memory functionSet;
                },
                .obj_data = obj_data: {
                    var functionSet: ObjDataFunctions = .{};

                    const support = bindgen.Support(T);
                    for (std.meta.fields(ObjDataFunctions)) |field| {
                        const funcName = field.name;

                        const def =
                            if (TypeUtils.supportsDecls(T) and @hasDecl(T, funcName)) &@field(T, funcName)
                            else if (@hasDecl(support, funcName)) &@field(support, funcName)
                            else @compileError("no " ++ @typeName(T) ++ "." ++ funcName ++ " found");

                        const G = @typeInfo(@typeInfo(field.type).optional.child).pointer.child;
                        const gInfo = @typeInfo(G).@"fn";

                        const F = @typeInfo(@TypeOf(def)).pointer.child;
                        if (@typeInfo(F) != .@"fn") {
                            @compileError("expected fn: " ++ @typeName(T) ++ "." ++ @typeName(@TypeOf(def)));
                        }
                        const fInfo = @typeInfo(F).@"fn";

                        std.debug.assert(!fInfo.is_generic);
                        std.debug.assert(!fInfo.is_var_args);
                        std.debug.assert(fInfo.return_type.? == gInfo.return_type.?);
                        std.debug.assert(fInfo.params.len == gInfo.params.len);

                        @field(functionSet, funcName) = @ptrCast(def);
                    }

                    break :obj_data functionSet;
                },
            };
        };

        return &x.vtable;
    }

    pub fn onCompare(self: *const VTable, header: ptr(Header), other: Object) Ordering {
        const data = header.getData();
        dispatch.debug("VTable/onCompare {s}", .{TypeId.name(header.type_id)});
        return self.obj_data.onCompare.?(data, other);
    }

    pub fn onFormat(self: *const VTable, header: ptr(Header), writer: std.io.AnyWriter) Error! void {
        const data = header.getData();
        // too noisy
        // dispatch.debug("VTable/onFormat {s}", .{TypeId.name(header.type_id)});
        return self.obj_data.onFormat.?(data, writer) catch |err| Rml.errorCast(err);
    }
};

pub const ObjectMemory = ObjMemory(ObjData);
pub fn ObjMemory (comptime T: type) type {
    return extern struct {
        const Self = @This();

        // this sucks but we need extern to guarantee layout here & don't want it on Header / T
        header: TypeUtils.ToBytes(Header) align(OBJ_ALIGN),
        data: TypeUtils.ToBytes(T) align(OBJ_ALIGN),

        pub fn onInit(self: *Self, rml: *Rml, origin: Origin, data: T) void {
            Header.onInit(@ptrCast(&self.header), T, rml, origin);
            self.data = std.mem.toBytes(data);
        }

        pub fn getHeader(self: *Self) ptr(Header) {
            return @ptrCast(&self.header);
        }

        pub fn getTypeId(self: *Self) TypeId {
            return self.getHeader().type_id;
        }

        pub fn getData(self: ptr(Self)) ptr(T) {
            return @ptrCast(&self.data);
        }
    };
}

pub fn ref (comptime T: type) type {
    return struct {
        obj: Object,
        data: if (@typeInfo(T) == .pointer) T else *T,
    };
}

pub const Object = Obj(ObjData);
pub fn Obj(comptime T: type) type {
    std.debug.assert(@alignOf(T) <= OBJ_ALIGN);

    return struct {
        const Self = @This();

        data: ptr(T),

        pub fn typeErase(self: Self) Object {
            return .{ .data = @alignCast(@ptrCast(self.data)) };
        }

        pub fn wrap(rml: *Rml, origin: Origin, val: T) OOM! Self {
            const memory = try rml.blobAllocator().create(ObjMemory(T));

            memory.onInit(rml, origin, val);

            return Self { .data = memory.getData() };
        }

        pub fn compare(self: Self, other: Obj(T)) Ordering {
            return self.getHeader().onCompare(other.getHeader());
        }

        pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror! void {
            const w: Rml.writer.Native = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();

            try self.getHeader().onFormat(w);
        }

        pub fn getMemory(self: Self) *ObjMemory(T) {
            return @fieldParentPtr("data", @as(ptr(TypeUtils.ToBytes(T)), @ptrCast(self.data)));
        }

        pub fn getHeader(self: Self) ptr(Header) {
            return @ptrCast(&getMemory(self).header);
        }

        pub fn getTypeId(self: Self) TypeId {
            return self.getHeader().type_id;
        }

        pub fn getOrigin(self: Self) Origin {
            return self.getHeader().origin;
        }

        pub fn getRml(self: Self) *Rml {
            return self.getHeader().rml;
        }

        pub fn onCompare(self: Self, other: Object) Ordering {
            return self.getHeader().onCompare(other.getHeader());
        }

        pub fn onFormat(self: Self, writer: std.io.AnyWriter) Error! void {
            return self.getHeader().onFormat(writer);
        }
    };
}

pub fn getObj(p: anytype) Obj(@typeInfo(@TypeOf(p)).pointer.child) {
    return Obj(@typeInfo(@TypeOf(p)).pointer.child) { .data = p };
}

pub fn getHeader(p: anytype) ptr(Header) {
    return getObj(p).getHeader();
}

pub fn getOrigin(p: anytype) Origin {
    return getHeader(p).origin;
}

pub fn getTypeId(p: anytype) TypeId {
    return getHeader(p).type_id;
}

pub fn getRml(p: anytype) *Rml {
    return getHeader(p).rml;
}

pub fn castObj(comptime T: type, obj: Object) ?Obj(T) {
    return if (isType(T, obj)) forceObj(T, obj) else null;
}

pub fn isType(comptime T: type, obj: Object) bool {
    return MiscUtils.equal(obj.getTypeId(), TypeId.of(T));
}

pub fn isUserdata(obj: Object) bool {
    return !isBuiltin(obj);
}

pub fn isBuiltinType(comptime T: type) bool {
    return comptime {
        const typeId = TypeId.of(T);

        for (std.meta.fields(@TypeOf(Rml.BUILTIN_TYPES))) |builtin| {
            if (Rml.equal(typeId, TypeId.of(@field(Rml.BUILTIN_TYPES, builtin.name)))) return true;
        }

        return false;
    };
}

pub fn isBuiltin(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(Rml.BUILTIN_TYPES))) |builtin| {
        if (Rml.equal(typeId, TypeId.of(@field(Rml.BUILTIN_TYPES, builtin.name)))) return true;
    }

    return false;
}

pub fn isValue(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(Rml.VALUE_TYPES))) |value| {
        if (Rml.equal(typeId, TypeId.of(@field(Rml.VALUE_TYPES, value.name)))) return true;
    }

    return false;
}

pub fn isAtom(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(Rml.ATOM_TYPES))) |atom| {
        if (Rml.equal(typeId, TypeId.of(@field(Rml.ATOM_TYPES, atom.name)))) return true;
    }

    return false;
}

pub fn isData(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(Rml.DATA_TYPES))) |data| {
        if (Rml.equal(typeId, TypeId.of(@field(Rml.DATA_TYPES, data.name)))) return true;
    }

    return false;
}

pub fn isObject(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(Rml.OBJECT_TYPES))) |object| {
        if (Rml.equal(typeId, TypeId.of(@field(Rml.OBJECT_TYPES, object.name)))) return true;
    }

    return false;
}

pub fn isSource(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(Rml.SOURCE_TYPES))) |source| {
        if (Rml.equal(typeId, TypeId.of(@field(Rml.SOURCE_TYPES, source.name)))) return true;
    }

    return false;
}

pub fn isCollection(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(Rml.COLLECTION_TYPES))) |collection| {
        if (Rml.equal(typeId, TypeId.of(@field(Rml.COLLECTION_TYPES, collection.name)))) return true;
    }

    return false;
}

pub fn isObjectType(comptime T: type) bool {
    const typeId = TypeId.of(T);

    inline for (comptime std.meta.fields(Rml.OBJECT_TYPES)) |field| {
        if (Rml.equal(typeId, TypeId.of(@field(Rml.COLLECTION_TYPES, field.name)))) return true;
    }

    return false;
}

pub fn forceObj(comptime T: type, obj: Object) Obj(T) {
    return .{.data = @ptrCast(obj.data)};
}


pub fn coerceBool(obj: Object) Bool {
    if (castObj(Bool, obj)) |b| {
        return b.data.*;
    } else if (isType(Nil, obj)) {
        return false;
    } else {
        return true;
    }
}

pub fn coerceArray(obj: Object) OOM! ?Obj(Rml.Array) {
    if (castObj(Rml.Array, obj)) |x| return x
    else if (castObj(Rml.Map, obj)) |x| {
        return try x.data.toArray();
    } else if (castObj(Rml.Set, obj)) |x| {
        return try x.data.toArray();
    } else if (castObj(Rml.Block, obj)) |x| {
        return try x.data.toArray();
    } else return null;
}

pub fn isArrayLike(obj: Object) bool {
    return isType(Rml.Array, obj)
        or isType(Rml.Map, obj)
        or isType(Rml.Set, obj)
        or isType(Rml.Block, obj)
        ;
}


pub fn isExactString(name: []const u8, obj: Object) bool {
    if (castObj(Rml.String, obj)) |sym| {
        return std.mem.eql(u8, sym.data.text(), name);
    } else {
        return false;
    }
}

pub fn isExactSymbol(name: []const u8, obj: Object) bool {
    if (castObj(Symbol, obj)) |sym| {
        return std.mem.eql(u8, sym.data.text(), name);
    } else {
        return false;
    }
}
