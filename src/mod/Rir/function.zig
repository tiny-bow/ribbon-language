const Rir = @import("../Rir.zig");

const function = @This();

const std = @import("std");
const utils = @import("utils");

const BlockList = std.ArrayListUnmanaged(*Rir.Block);
const UpvalueList = std.ArrayListUnmanaged(Rir.LocalId);

pub const Function = struct {
    pub const Id = Rir.FunctionId;

    ir: *Rir,
    module: *Rir.Module,

    id: Rir.FunctionId,
    name: Rir.NameId,

    type: *Rir.Type,

    evidence: ?Rir.EvidenceId = null,
    blocks: BlockList = .{},
    parent: ?*Rir.Block = null,
    upvalue_indices: UpvalueList = .{},
    local_id_counter: usize = 0,

    pub fn getRef(self: *const Function) Rir.value.OpRef(Rir.Function) {
        return Rir.value.OpRef(Rir.Function){
            .module_id = self.module.id,
            .id = self.id,
        };
    }

    pub fn init(module: *Rir.Module, id: Rir.FunctionId, name: Rir.NameId, typeIr: *Rir.Type) error{ ExpectedFunctionType, OutOfMemory }!*Function {
        const ir = module.ir;

        const self = try ir.allocator.create(Function);
        errdefer ir.allocator.destroy(self);

        self.* = Function{
            .ir = ir,
            .module = module,

            .id = id,
            .name = name,

            .type = typeIr,
        };

        const funcTyInfo = try self.getTypeInfo();

        if (funcTyInfo.call_conv == .foreign) {
            return error.ExpectedFunctionType;
        }

        const entryName = try ir.internName("entry");

        const entryBlock = try Rir.Block.init(self, null, @enumFromInt(0), entryName);
        errdefer entryBlock.deinit();

        try self.blocks.append(ir.allocator, entryBlock);

        for (funcTyInfo.parameters) |param| {
            _ = entryBlock.createLocal(param.name, param.type) // shouldn't be able to get error.TooManyLocals here; the type was already checked
            catch |err| return utils.types.forceErrorSet(error{OutOfMemory}, err);
        }

        return self;
    }

    pub fn deinit(self: *Function) void {
        for (self.blocks.items) |b| b.deinit();

        self.blocks.deinit(self.ir.allocator);

        self.upvalue_indices.deinit(self.ir.allocator);

        self.ir.allocator.destroy(self);
    }

    pub fn onFormat(self: *const Function, formatter: Rir.Formatter) !void {
        const oldActiveFunction = formatter.swapFunction(self);
        defer formatter.setFunction(oldActiveFunction);

        try formatter.fmt(self.name);
        if (formatter.getFlag(.show_ids)) try formatter.print("#{}", .{@intFromEnum(self.id)});
        try formatter.writeAll(": ");
        try formatter.fmt(self.type);
        try formatter.writeAll(" =");
        try formatter.beginBlock();
        for (self.blocks.items, 0..) |b, i| {
            if (i > 0) try formatter.endLine();
            try formatter.fmt(b);
        }
        try formatter.endBlock();
    }

    pub fn freshLocalId(self: *Function) error{TooManyLocals}!Rir.LocalId {
        const id = self.local_id_counter;

        if (id > Rir.MAX_LOCALS) {
            return error.TooManyLocals;
        }

        self.local_id_counter += 1;

        return @enumFromInt(id);
    }

    pub fn getTypeInfo(self: *const Function) error{ExpectedFunctionType}!Rir.type_info.Function {
        return self.type.info.forceFunction();
    }

    pub fn getParameters(self: *const Function) error{ExpectedFunctionType}![]const Rir.type_info.Parameter {
        return (try self.getTypeInfo()).parameters;
    }

    pub fn getReturnType(self: *const Function) error{ExpectedFunctionType}!*Rir.Type {
        return (try self.getTypeInfo()).return_type;
    }

    pub fn getEffects(self: *const Function) error{ExpectedFunctionType}![]const *Rir.Type {
        return (try self.getTypeInfo()).effects;
    }

    pub fn getArity(self: *const Function) error{ExpectedFunctionType}!Rir.Arity {
        return @intCast((try self.getParameters()).len);
    }

    pub fn getArgument(self: *const Function, argIndex: Rir.Arity) error{ InvalidArgument, ExpectedFunctionType }!*Rir.Local {
        if (argIndex >= try self.getArity()) {
            return error.InvalidArgument;
        }

        return self.getEntryBlock().local_map.values()[argIndex];
    }

    pub fn createUpvalue(self: *Function, parentLocal: Rir.LocalId) error{ TooManyUpvalues, InvalidLocal, InvalidUpvalue, OutOfMemory }!Rir.UpvalueId {
        if (self.parent) |parent| {
            _ = try parent.getLocal(parentLocal);

            const index = self.upvalue_indices.items.len;

            if (index >= Rir.MAX_LOCALS) {
                return error.TooManyUpvalues;
            }

            try self.upvalue_indices.append(self.ir.allocator, parentLocal);

            return @enumFromInt(index);
        } else {
            return error.InvalidUpvalue;
        }
    }

    pub fn getUpvalue(self: *const Function, u: Rir.UpvalueId) error{ InvalidUpvalue, InvalidLocal }!*Rir.Local {
        if (self.parent) |parent| {
            if (@intFromEnum(u) >= self.upvalue_indices.items.len) {
                return error.InvalidUpvalue;
            }

            return parent.getLocal(self.upvalue_indices.items[@intFromEnum(u)]);
        } else {
            return error.InvalidUpvalue;
        }
    }

    pub fn getEntryBlock(self: *const Function) *Rir.Block {
        return self.blocks.items[0];
    }

    pub fn createBlock(self: *Function, parent: *Rir.Block, name: Rir.NameId) error{ TooManyBlocks, OutOfMemory }!*Rir.Block {
        const index = self.blocks.items.len;

        if (index >= Rir.MAX_BLOCKS) {
            return error.TooManyBlocks;
        }

        const newBlock = try Rir.Block.init(self, parent, @enumFromInt(index), name);

        try self.blocks.append(self.ir.allocator, newBlock);

        return newBlock;
    }

    pub fn getBlock(self: *const Function, id: Rir.BlockId) error{InvalidBlock}!*Rir.Block {
        if (@intFromEnum(id) >= self.blocks.items.len) {
            return error.InvalidBlock;
        }

        return self.blocks.items[@intFromEnum(id)];
    }
};
