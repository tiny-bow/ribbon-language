const std = @import("std");
const TypeUtils = @import("Utils").Type;

const Rir = @import("../Rir.zig");


const BlockList = std.ArrayListUnmanaged(*Rir.Block);
const UpvalueList = std.ArrayListUnmanaged(Rir.LocalId);

pub const Function = struct {
    module: *Rir.Module,
    id: Rir.FunctionId,
    name: Rir.NameId,
    type: Rir.TypeId,
    evidence: ?Rir.EvidenceId = null,
    blocks: BlockList = .{},
    parent: ?*Rir.Block = null,
    upvalue_indices: UpvalueList = .{},
    local_id_counter: usize = 0,


    pub fn getRef(self: *const Function) Rir.Ref(Rir.FunctionId) {
        return Rir.Ref(Rir.FunctionId) {
            .id = self.id,
            .module = self.module.id,
        };
    }


    pub fn init(module: *Rir.Module, id: Rir.FunctionId, name: Rir.NameId, tyId: Rir.TypeId) error{InvalidType, OutOfMemory}! *Function {
        const self = try module.root.allocator.create(Function);
        errdefer module.root.allocator.destroy(self);

        self.* = Function {
            .module = module,
            .id = id,
            .name = name,
            .type = tyId,
        };

        const funcTyInfo = try self.getTypeInfo();

        const entryName = module.root.internName("entry")
            catch |err| return TypeUtils.forceErrorSet(error{OutOfMemory}, err);

        const entryBlock = try Rir.Block.init(self, null, @enumFromInt(0), entryName);
        errdefer entryBlock.deinit();

        try self.blocks.append(module.root.allocator, entryBlock);

        for (funcTyInfo.parameters) |param| {
            _ = entryBlock.createLocal(param.name, param.type)
                catch |err| return TypeUtils.forceErrorSet(error{OutOfMemory}, err);
        }

        return self;
    }

    pub fn deinit(self: *Function) void {
        for (self.blocks.items) |b| b.deinit();

        self.blocks.deinit(self.module.root.allocator);

        self.upvalue_indices.deinit(self.module.root.allocator);

        self.module.root.allocator.destroy(self);
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

    pub fn freshLocalId(self: *Function) error{TooManyLocals}! Rir.LocalId {
        const id = self.local_id_counter;

        if (id > Rir.MAX_LOCALS) {
            return error.TooManyLocals;
        }

        self.local_id_counter += 1;

        return @enumFromInt(id);
    }

    pub fn getTypeInfo(self: *const Function) error{InvalidType}! Rir.type_info.Function {
        return (try self.module.root.getType(self.type)).info.asFunction();
    }

    pub fn getParameters(self: *const Function) error{InvalidType}! []const Rir.type_info.Parameter {
        return (try self.getTypeInfo()).parameters;
    }

    pub fn getReturnType(self: *const Function) error{InvalidType}! Rir.TypeId {
        return (try self.getTypeInfo()).return_type;
    }

    pub fn getEffects(self: *const Function) error{InvalidType}! []const Rir.TypeId {
        return (try self.getTypeInfo()).effects;
    }

    pub fn getArity(self: *const Function) error{InvalidType}! Rir.Arity {
        return @intCast((try self.getParameters()).len);
    }

    pub fn getArgument(self: *const Function, argIndex: Rir.Arity) error{InvalidArgument, InvalidType}! *Rir.Local {
        if (argIndex >= try self.getArity()) {
            return error.InvalidArgument;
        }

        return self.getEntryBlock().locals.values()[argIndex];
    }

    pub fn createUpvalue(self: *Function, parentLocal: Rir.LocalId) error{TooManyUpvalues, InvalidLocal, InvalidUpvalue, OutOfMemory}! Rir.UpvalueId {
        if (self.parent) |parent| {
            _ = try parent.getLocal(parentLocal);

            const index = self.upvalue_indices.items.len;

            if (index >= Rir.MAX_LOCALS) {
                return error.TooManyUpvalues;
            }

            try self.upvalue_indices.append(self.module.root.allocator, parentLocal);

            return @enumFromInt(index);
        } else {
            return error.InvalidUpvalue;
        }
    }

    pub fn getUpvalue(self: *const Function, u: Rir.UpvalueId) error{InvalidUpvalue, InvalidLocal}! *Rir.Local {
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

    pub fn createBlock(self: *Function, parent: *Rir.Block, name: Rir.NameId) error{TooManyBlocks, OutOfMemory}! *Rir.Block {
        const index = self.blocks.items.len;

        if (index >= Rir.MAX_BLOCKS) {
            return error.TooManyBlocks;
        }

        const newBlock = try Rir.Block.init(self, parent, @enumFromInt(index), name);

        try self.blocks.append(self.module.root.allocator, newBlock);

        return newBlock;
    }

    pub fn getBlock(self: *const Function, id: Rir.BlockId) error{InvalidBlock}! *Rir.Block {
        if (@intFromEnum(id) >= self.blocks.items.len) {
            return error.InvalidBlock;
        }

        return self.blocks.items[@intFromEnum(id)];
    }
};
