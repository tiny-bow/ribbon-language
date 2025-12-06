//! # ir
//! This namespace provides a mid-level hybrid SSA Intermediate Representation (ir) for Ribbon.
//!
//! It is used to represent the program in a way that is easy to optimize and transform.
//!
//! This ir targets:
//! * rvm's core bytecode (via the `bytecode` module)
//! * native machine code, in two ways:
//!    + in house x64 jit (the `machine` module)
//!    + freestanding (eventually)
//!
//! ### TODO
//!
//! #### Core IR Infrastructure & Correctness
//!
//! *   ** Thread Safety:**
//!     *   Currently, the ir context and its contents are not thread-safe.
//!     *   Implement atomic operations for identifier generation.
//!     *   Use mutex for modifications to shared data structures like interned name and data sets.
//!     *   TODO: study plan.md and higher level modules to see if this is necessary.
//!
//! *   ** Serialization/Deserialization:**
//!     *   Create a textual representation of the IR for debugging. This is invaluable for inspecting the output of compiler passes.
//!     *   Implement a binary serialization format for caching IR or saving it for later stages.
//!
//! *   ** Create a Builder API:**
//!     *   Design a `Builder` struct to simplify IR construction.
//!     *   Methods like `builder.setInsertPoint(*Block)`, `builder.createAdd(lhs, rhs, ?name)`, `builder.createBr(dest_block)`.
//!     *   The builder should handle memory allocation for instructions and operands, and automatically link instructions into the block.
//!
//! *   ** Implement an IR Verifier:**
//!     *   Verify that every block ends with a `Termination` instruction.
//!     *   Check that `phi` nodes only appear at the beginning of a block.
//!     *   Validate that the number of `phi` operands matches the number of predecessor blocks.
//!     *   Ensure that an instruction's result is used only by instructions that it dominates (the core SSA property).
//!     *   Type check every instruction, ensuring operand types match what the operation expects.
//!     *   Verify that `prev` and `next` pointers in blocks are consistent.
//!     *   Check that `predecessors` and `successors` lists are correctly maintained.
//!
//! #### Type System (`Term`s)
//!
//! *   ** Implement Type System `TODO`s:**
//!     *   Add support for bit-offset pointers as mentioned in the `PointerType` `TODO`.
//!
//! #### Instruction Set & Semantics
//!
//! *   ** Define User-Defined Operation (`_`) Semantics:**
//!     *   The `Operation._` is only the start for extensibility.
//!         A mechanism is needed for extensions to register these operations,
//!         including their type-checking rules, semantics, and how they are eventually lowered or code-generated.
//! *   ** Specify Intrinsic Functions:**
//!     *   Many operations are better represented as "intrinsics" (special functions known to the compiler) rather than low-level instructions.
//!         This could include things like `memcpy`, `memset`, or complex math operations. Decide which should be instructions vs. intrinsics.
//! *   ** Define `reify` and `lift` Semantics:**
//!     *   The purpose of `reify` (term to SSA) and `lift` (SSA to term) is clear, but their exact semantics and constraints need to be rigorously defined.
//!         For example, what happens if we try to `reify` a type that has no runtime representation?
//!
//! #### Analysis & Transformation Framework
//!
//! *   ** SSA Construction Utilities:**
//!     *   Implement a standard "Mem2Reg" pass that converts stack allocations (`stack_alloc`, `load`, `store`) of local variables into SSA registers (`phi` nodes). This is a cornerstone of building SSA form from an AST.
//!     *   Develop an algorithm for computing dominance frontiers, which is required for placing `phi` nodes.
//! *   ** Create a Pass Manager:**
//!     *   Design a system to schedule and run analysis and transformation passes over the IR.
//!     *   It should handle dependencies between passes (e.g., a dominance analysis must run before Mem2Reg).
//!     *   It should support passes at different granularities (Module, Function, etc.).
//! *   ** Implement Standard Analyses:**
//!     *   **Dominator Tree:** Essential for SSA construction and many optimizations.
//!     *   **Control Flow Graph (CFG) Analysis:** Already partially present with `predecessors`/`successors`, but could be formalized.
//!     *   **Alias Analysis:** To determine if two pointers can refer to the same memory location. Crucial for reordering `load`/`store` operations.
//!     *   **Loop Analysis:** To find loops in the CFG, which are prime candidates for optimization.
//! *   ** Implement Foundational Optimizations:**
//!     *   Constant Folding and Propagation
//!     *   Dead Code Elimination
//!     *   Common Subexpression Elimination
//!     *   Instruction Combining
//!     *   Global Value Numbering (GVN)
//!
//! #### Tooling & Debugging
//!
//! *   ** Source-Level Debug Information:**
//!     *   Extend the IR to carry debug information. `Instruction`s should be able to store a source location (file, line, column).
//!     *   This is non-negotiable for producing debuggable executables.
//! *   ** Graph Visualization:**
//!     *   Write a utility to export the CFG of a `Function` to a format like Graphviz `.dot`. This is one of the most effective ways to debug a compiler's IR.
//!
//! #### Documentation
//!
//! *   ** Write Comprehensive Documentation:**
//!     *   Document the semantics of every single `Operation` and `Termination`.
//!     *   Explain the purpose and structure of every `Term`.
//!     *   Provide a high-level overview of the IR architecture and its design philosophy.
//!     *   Document the invariants that the IR Verifier checks.
const ir = @This();

const std = @import("std");
const log = std.log.scoped(.Rir);

const core = @import("core");
const common = @import("common");
const analysis = @import("analysis");
const bytecode = @import("bytecode");

test {
    // std.debug.print("semantic analysis for ir\n", .{});
    std.testing.refAllDeclsRecursive(@This());
}

pub const Cbr = u128;


pub const Sma = struct {
    pub const magic = "RIBBONIR";

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    version: common.SemVer = core.VERSION,

    tags: common.ArrayList([]const u8) = .empty,
    names: common.ArrayList([]const u8) = .empty,
    blobs: common.ArrayList(*const BlobHeader) = .empty,
    shared: common.ArrayList(u32) = .empty,
    terms: common.ArrayList(Sma.Term) = .empty,
    modules: common.ArrayList(Sma.Module) = .empty,
    expressions: common.ArrayList(Sma.Expression) = .empty,
    functions: common.ArrayList(Sma.Function) = .empty,

    pub fn init(allocator: std.mem.Allocator) !*Sma {
        const self = try allocator.create(Sma);
        self.* = Sma{
            .allocator = allocator,
            .arena = .init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Sma) void {
        self.arena.deinit();

        self.tags.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.shared.deinit(self.allocator);

        for (self.blobs.items) |blob| blob.deinit(self.allocator);
        self.blobs.deinit(self.allocator);

        for (self.terms.items) |*term| term.deinit(self.allocator);
        self.terms.deinit(self.allocator);

        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.modules.deinit(self.allocator);

        for (self.expressions.items) |*expression| expression.deinit(self.allocator);
        self.expressions.deinit(self.allocator);

        for (self.functions.items) |*function| function.deinit(self.allocator);
        self.functions.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    pub const Dehydrator = struct {
        sma: *Sma,
        ctx: *Context,

        tag_to_index: common.UniqueReprMap(Tag, u8) = .empty,
        name_to_index: common.StringMap(u32) = .empty,
        blob_to_index: common.UniqueReprMap(*const BlobHeader, u32) = .empty,
        term_to_index: common.UniqueReprMap(ir.Term, u32) = .empty,
        module_to_index: common.UniqueReprMap(*ir.Module, u32) = .empty,
        expression_to_index: common.UniqueReprMap(*ir.Block, u32) = .empty,
        function_to_index: common.UniqueReprMap(*ir.Function, u32) = .empty,
        block_to_index: common.UniqueReprMap(*ir.Block, struct { u32, common.UniqueReprMap(*ir.Instruction, u32) }) = .empty,

        pub fn init(ctx: *Context, allocator: std.mem.Allocator) !Dehydrator {
            const sma = try Sma.init(allocator);
            return Dehydrator{
                .sma = sma,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Dehydrator) void {
            self.finalize().deinit();
        }

        pub fn finalize(self: *Dehydrator) *Sma {
            self.tag_to_index.deinit(self.ctx.allocator);
            self.name_to_index.deinit(self.ctx.allocator);
            self.blob_to_index.deinit(self.ctx.allocator);
            self.term_to_index.deinit(self.ctx.allocator);
            self.module_to_index.deinit(self.ctx.allocator);
            self.expression_to_index.deinit(self.ctx.allocator);
            self.function_to_index.deinit(self.ctx.allocator);
            self.block_to_index.deinit(self.ctx.allocator);
            defer self.* = undefined;
            return self.sma;
        }
    };

    pub const Rehydrator = struct {
        sma: *Sma,
        ctx: *Context,

        index_to_tag: common.UniqueReprMap(u32, Tag) = .empty,
        index_to_name: common.UniqueReprMap(u32, Name) = .empty,
        index_to_blob: common.UniqueReprMap(u32, *const BlobHeader) = .empty,
        index_to_term: common.UniqueReprMap(u32, ir.Term) = .empty,
        index_to_module: common.UniqueReprMap(u32, *ir.Module) = .empty,
        index_to_expression: common.UniqueReprMap(u32, *ir.Block) = .empty,
        index_to_function: common.UniqueReprMap(u32, *ir.Function) = .empty,
        index_to_block: common.UniqueReprMap(u32, struct { *ir.Block, common.UniqueReprMap(u32, *ir.Instruction) }) = .empty,

        pub fn init(ctx: *Context, sma: *Sma) !Rehydrator {
            return Rehydrator{
                .sma = sma,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Rehydrator) void {
            self.sma.deinit();

            self.index_to_tag.deinit(self.ctx.allocator);
            self.index_to_name.deinit(self.ctx.allocator);
            self.index_to_blob.deinit(self.ctx.allocator);
            self.index_to_term.deinit(self.ctx.allocator);
            self.index_to_module.deinit(self.ctx.allocator);
            self.index_to_expression.deinit(self.ctx.allocator);
            self.index_to_function.deinit(self.ctx.allocator);
            self.index_to_block.deinit(self.ctx.allocator);
            self.* = undefined;
        }
    };

    pub const Module = struct {
        guid: ModuleGUID,
        name: u32,
        cbr: Cbr,
        exported_terms: common.ArrayList(Sma.Export) = .empty,
        exported_functions: common.ArrayList(Sma.Export) = .empty,

        pub fn deinit(self: *Sma.Module, allocator: std.mem.Allocator) void {
            self.exported_terms.deinit(allocator);
            self.exported_functions.deinit(allocator);
        }

        pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Module {
            const guid_u128 = try reader.takeInt(u128, .little);
            const guid: ModuleGUID = @enumFromInt(guid_u128);

            const name = try reader.takeInt(u32, .little);
            const cbr = try reader.takeInt(u128, .little);

            const exported_term_count = try reader.takeInt(u32, .little);
            var exported_terms = common.ArrayList(Sma.Export).empty;
            errdefer exported_terms.deinit(allocator);
            for (0..exported_term_count) |_| {
                const ex = try Sma.Export.deserialize(reader);
                try exported_terms.append(allocator, ex);
            }

            const exported_function_count = try reader.takeInt(u32, .little);
            var exported_functions = common.ArrayList(Sma.Export).empty;
            errdefer exported_functions.deinit(allocator);
            for (0..exported_function_count) |_| {
                const ex = try Sma.Export.deserialize(reader);
                try exported_functions.append(allocator, ex);
            }

            return Sma.Module{
                .guid = guid,
                .name = name,
                .cbr = cbr,
                .exported_terms = exported_terms,
                .exported_functions = exported_functions,
            };
        }

        pub fn serialize(self: *Sma.Module, writer: *std.io.Writer) error{WriteFailed}!void {
            try writer.writeInt(u128, @intFromEnum(self.guid), .little);

            try writer.writeInt(u32, self.name, .little);
            try writer.writeInt(u128, self.cbr, .little);

            try writer.writeInt(u32, @intCast(self.exported_terms.items.len), .little);
            for (self.exported_terms.items) |*ex| try ex.serialize(writer);

            try writer.writeInt(u32, @intCast(self.exported_functions.items.len), .little);
            for (self.exported_functions.items) |*ex| try ex.serialize(writer);
        }
    };

    pub const Export = struct {
        name: u32,
        value: u32,

        pub fn deserialize(reader: *std.io.Reader) error{ EndOfStream, ReadFailed }!Sma.Export {
            const name = try reader.takeInt(u32, .little);
            const value = try reader.takeInt(u32, .little);
            return Sma.Export{
                .name = name,
                .value = value,
            };
        }

        pub fn serialize(self: *Sma.Export, writer: *std.io.Writer) error{WriteFailed}!void {
            try writer.writeInt(u32, self.name, .little);
            try writer.writeInt(u32, self.value, .little);
        }
    };

    pub const Function = struct {
        name: u32,
        type: u32,
        kind: ir.Function.Kind,
        body: Expression,

        pub fn deinit(self: *Sma.Function, allocator: std.mem.Allocator) void {
            self.body.deinit(allocator);
        }

        pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Function {
            const name = try reader.takeInt(u32, .little);
            const ty = try reader.takeInt(u32, .little);
            const kind_u8 = try reader.takeInt(u8, .little);
            const kind: ir.Function.Kind = @enumFromInt(kind_u8);
            const body = try Sma.Expression.deserialize(reader, allocator);

            return Sma.Function{
                .name = name,
                .type = ty,
                .kind = kind,
                .body = body,
            };
        }

        pub fn serialize(self: *Sma.Function, writer: *std.io.Writer) error{WriteFailed}!void {
            try writer.writeInt(u32, self.name, .little);
            try writer.writeInt(u32, self.type, .little);
            try writer.writeInt(u8, @intFromEnum(self.kind), .little);
            try self.body.serialize(writer);
        }
    };

    pub const Expression = struct {
        blocks: common.ArrayList(Sma.Block) = .empty,

        pub fn deinit(self: *Sma.Expression, allocator: std.mem.Allocator) void {
            for (self.blocks.items) |*block| block.deinit(allocator);
            self.blocks.deinit(allocator);
        }

        pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Expression {
            const block_count = try reader.takeInt(u32, .little);

            var blocks = common.ArrayList(Sma.Block).empty;
            errdefer blocks.deinit(allocator);

            for (0..block_count) |_| {
                const block = try Sma.Block.deserialize(reader, allocator);
                try blocks.append(allocator, block);
            }

            return Sma.Expression{
                .blocks = blocks,
            };
        }

        pub fn serialize(self: *Sma.Expression, writer: *std.io.Writer) error{WriteFailed}!void {
            try writer.writeInt(u32, @intCast(self.blocks.items.len), .little);
            for (self.blocks.items) |*block| try block.serialize(writer);
        }
    };

    pub const Block = struct {
        instructions: common.ArrayList(Sma.Instruction) = .empty,

        pub fn deinit(self: *Sma.Block, allocator: std.mem.Allocator) void {
            for (self.instructions.items) |*inst| inst.deinit(allocator);
            self.instructions.deinit(allocator);
        }

        pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Block {
            const instruction_count = try reader.takeInt(u32, .little);

            var instructions = common.ArrayList(Sma.Instruction).empty;
            errdefer instructions.deinit(allocator);

            for (0..instruction_count) |_| {
                const inst = try Sma.Instruction.deserialize(reader, allocator);
                try instructions.append(allocator, inst);
            }

            return Sma.Block{
                .instructions = instructions,
            };
        }

        pub fn serialize(self: *Sma.Block, writer: *std.io.Writer) error{WriteFailed}!void {
            try writer.writeInt(u32, @intCast(self.instructions.items.len), .little);
            for (self.instructions.items) |*inst| try inst.serialize(writer);
        }
    };

    pub const Term = struct {
        tag: u8,
        operands: common.ArrayList(Sma.Operand) = .empty,

        pub fn deinit(self: *Sma.Term, allocator: std.mem.Allocator) void {
            self.operands.deinit(allocator);
        }

        pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Term {
            const tag = try reader.takeInt(u8, .little);
            const operand_count = try reader.takeInt(u32, .little);

            var operands = common.ArrayList(Sma.Operand).empty;
            errdefer operands.deinit(allocator);

            for (0..operand_count) |_| {
                const op = try Sma.Operand.deserialize(reader);
                try operands.append(allocator, op);
            }

            return Sma.Term{
                .tag = tag,
                .operands = operands,
            };
        }

        pub fn serialize(self: *Sma.Term, writer: *std.io.Writer) error{WriteFailed}!void {
            try writer.writeInt(u8, self.tag, .little);
            try writer.writeInt(u32, @intCast(self.operands.items.len), .little);
            for (self.operands.items) |*op| try op.serialize(writer);
        }
    };

    pub const Instruction = struct {
        command: u8,
        type: u32,
        operands: common.ArrayList(Sma.Operand) = .empty,

        pub fn deinit(self: *Sma.Instruction, allocator: std.mem.Allocator) void {
            self.operands.deinit(allocator);
        }

        pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Instruction {
            const command = try reader.takeInt(u8, .little);
            const ty = try reader.takeInt(u32, .little);
            const operand_count = try reader.takeInt(u32, .little);

            var operands = common.ArrayList(Sma.Operand).empty;
            errdefer operands.deinit(allocator);

            for (0..operand_count) |_| {
                const op = try Sma.Operand.deserialize(reader);
                try operands.append(allocator, op);
            }

            return Sma.Instruction{
                .command = command,
                .type = ty,
                .operands = operands,
            };
        }

        pub fn serialize(self: *Sma.Instruction, writer: *std.io.Writer) error{WriteFailed}!void {
            try writer.writeInt(u8, self.command, .little);
            try writer.writeInt(u32, self.type, .little);
            try writer.writeInt(u32, @intCast(self.operands.items.len), .little);
            for (self.operands.items) |*op| try op.serialize(writer);
        }
    };

    pub const Operand = struct {
        kind: Kind,
        value: u32,

        pub const Kind = enum(u8) { name, expression, term, blob, function, block, variable };

        pub fn deserialize(reader: *std.io.Reader) error{ EndOfStream, ReadFailed }!Sma.Operand {
            const kind = try reader.takeInt(u8, .little);
            const value = try reader.takeInt(u32, .little);
            return Sma.Operand{
                .kind = @enumFromInt(kind),
                .value = value,
            };
        }

        pub fn serialize(self: *Sma.Operand, writer: *std.io.Writer) error{WriteFailed}!void {
            try writer.writeInt(u8, @intFromEnum(self.kind), .little);
            try writer.writeInt(u32, self.value, .little);
        }
    };

    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ InvalidMagic, EndOfStream, ReadFailed, OutOfMemory }!*Sma {
        const sma = try Sma.init(allocator);
        errdefer sma.deinit();

        const magic_len = Sma.magic.len;
        var magic_buf: [magic_len]u8 = undefined;
        var writer = std.io.Writer.fixed(&magic_buf);
        reader.streamExact(&writer, magic_len) catch return error.ReadFailed;

        if (std.mem.eql(u8, &magic_buf, Sma.magic) == false) {
            return error.InvalidMagic;
        }

        sma.version = try common.SemVer.deserialize(reader);

        if (!sma.version.eql(&core.VERSION)) {
            log.warn("SMA version mismatch: file version {f} does not match host version {f}", .{ sma.version, core.VERSION });
        }

        const tag_count = try reader.takeInt(u32, .little);
        for (0..tag_count) |_| {
            const tag_len = try reader.takeInt(u32, .little);
            const tag_buf = try sma.arena.allocator().alloc(u8, tag_len);
            writer = std.io.Writer.fixed(tag_buf);
            reader.streamExact(&writer, tag_len) catch return error.ReadFailed;
            try sma.tags.append(allocator, tag_buf);
        }

        const name_count = try reader.takeInt(u32, .little);
        for (0..name_count) |_| {
            const name_len = try reader.takeInt(u32, .little);
            const name_buf = try sma.arena.allocator().alloc(u8, name_len);
            writer = std.io.Writer.fixed(name_buf);
            reader.streamExact(&writer, name_len) catch return error.ReadFailed;
            try sma.names.append(allocator, name_buf);
        }

        const blob_count = try reader.takeInt(u32, .little);
        for (0..blob_count) |i| {
            const blob = try BlobHeader.deserialize(reader, @enumFromInt(i), sma.arena.allocator());
            try sma.blobs.append(allocator, blob);
        }

        const shared_count = try reader.takeInt(u32, .little);
        for (0..shared_count) |_| {
            const shared_index = try reader.takeInt(u32, .little);
            try sma.shared.append(allocator, shared_index);
        }

        const term_count = try reader.takeInt(u32, .little);
        for (0..term_count) |_| {
            const term = try Sma.Term.deserialize(reader, allocator);
            try sma.terms.append(allocator, term);
        }

        const module_count = try reader.takeInt(u32, .little);
        for (0..module_count) |_| {
            const module = try Sma.Module.deserialize(reader, allocator);
            try sma.modules.append(allocator, module);
        }

        const expression_count = try reader.takeInt(u32, .little);
        for (0..expression_count) |_| {
            const expression = try Sma.Expression.deserialize(reader, allocator);
            try sma.expressions.append(allocator, expression);
        }

        const function_count = try reader.takeInt(u32, .little);
        for (0..function_count) |_| {
            const function = try Sma.Function.deserialize(reader, allocator);
            try sma.functions.append(allocator, function);
        }

        return sma;
    }

    pub fn serialize(self: *Sma, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeAll(Sma.magic);

        try self.version.serialize(writer);

        try writer.writeInt(u32, @intCast(self.tags.items.len), .little);
        for (self.tags.items) |tag| {
            try writer.writeInt(u32, @intCast(tag.len), .little);
            try writer.writeAll(tag);
        }

        try writer.writeInt(u32, @intCast(self.names.items.len), .little);
        for (self.names.items) |name| {
            try writer.writeInt(u32, @intCast(name.len), .little);
            try writer.writeAll(name);
        }

        try writer.writeInt(u32, @intCast(self.blobs.items.len), .little);
        for (self.blobs.items) |blob| try blob.serialize(writer);

        try writer.writeInt(u32, @intCast(self.shared.items.len), .little);
        for (self.shared.items) |shared_index| {
            try writer.writeInt(u32, shared_index, .little);
        }

        try writer.writeInt(u32, @intCast(self.terms.items.len), .little);
        for (self.terms.items) |*term| try term.serialize(writer);

        try writer.writeInt(u32, @intCast(self.modules.items.len), .little);
        for (self.modules.items) |*module| try module.serialize(writer);

        try writer.writeInt(u32, @intCast(self.expressions.items.len), .little);
        for (self.expressions.items) |*expression| try expression.serialize(writer);

        try writer.writeInt(u32, @intCast(self.functions.items.len), .little);
        for (self.functions.items) |*function| try function.serialize(writer);
    }
};

/// A hasher for computing canonical binary representation (CBR) hashes.
pub const CbrHasher = struct {
    blake: std.crypto.hash.Blake3,

    /// Initialize a new CbrHasher.
    pub fn init() CbrHasher {
        return CbrHasher{
            .blake = std.crypto.hash.Blake3.init(.{}),
        };
    }

    /// Update the hasher with the given value converted to bytes
    pub inline fn update(self: *CbrHasher, value: anytype) void {
        const T_info = @typeInfo(@TypeOf(value));
        if (comptime T_info == .pointer) {
            if (comptime T_info.pointer.child == u8) {
                if (comptime T_info.pointer.size == .slice) {
                    self.blake.update(value);
                } else {
                    self.blake.update(std.mem.span(value));
                }
            } else {
                self.blake.update(std.mem.asBytes(value));
            }
        } else {
            self.blake.update(std.mem.asBytes(&value));
        }
    }

    /// Finalize the hasher and return the resulting hash bytes.
    pub fn final(self: *CbrHasher) u128 {
        var out: Cbr = 0;
        self.blake.final(std.mem.asBytes(&out));
        return out;
    }
};

pub const QuickHasher = struct {
    fnv: std.hash.Fnv1a_64,

    pub fn init() QuickHasher {
        return QuickHasher{
            .fnv = std.hash.Fnv1a_64.init(),
        };
    }

    pub inline fn update(self: *QuickHasher, value: anytype) void {
        const T_info = @typeInfo(@TypeOf(value));
        if (comptime T_info == .pointer) {
            if (comptime T_info.pointer.child == u8) {
                if (comptime T_info.pointer.size == .slice) {
                    self.fnv.update(value);
                } else {
                    self.fnv.update(std.mem.span(value));
                }
            } else {
                self.fnv.update(std.mem.asBytes(value));
            }
        } else {
            self.fnv.update(std.mem.asBytes(&value));
        }
    }

    pub fn final(self: *QuickHasher) u64 {
        return self.fnv.final();
    }
};

/// The "universe" for an ir compilation session.
pub const Context = struct {
    /// Standard allocator for managed data in the context.
    allocator: std.mem.Allocator,
    /// Arena allocator for terms and other static data.
    arena: std.heap.ArenaAllocator,

    /// Map from ModuleGUID to an index in the `modules` array
    modules: common.UniqueReprMap(ModuleGUID, *Module) = .empty,
    /// Map from module name string to ModuleGUID
    name_to_module_guid: common.StringMap(ModuleGUID) = .empty,

    /// A set of all names in the context, de-duplicated and owned by the context itself
    interned_name_set: common.StringMap(NameId) = .empty,
    /// Reverse mapping for interned names.
    name_id_to_string: common.UniqueReprMap(NameId, []const u8) = .empty,
    /// A set of all constant data blobs in the context, de-duplicated and owned by the context itself
    interned_data_set: common.HashSet(*const BlobHeader, BlobHeader.HashContext) = .empty,

    /// Contains all terms created in this context
    all_terms: common.ArrayList(Term) = .empty,

    /// Contains terms that are not subject to interface association, such as ints and arrays
    shared_terms: common.HashSet(Term, Term.IdentityContext) = .empty,
    /// Contains terms that are commonly used, such as "i32"
    named_shared_terms: common.StringMap(Term) = .empty,

    /// Map from @typeName to Tag
    tags: common.StringMap(Tag) = .empty,
    /// Map from Tag to TermVTable for the associated type
    vtables: common.UniqueReprMap(Tag, TermVTable) = .empty,

    /// Source of fresh TermId values
    fresh_term_id: std.meta.Tag(TermId) = 0,

    /// Initialize a new ir context on the given allocator.
    pub fn init(allocator: std.mem.Allocator) !*Context {
        const self = try allocator.create(Context);

        self.* = Context{
            .allocator = allocator,
            .arena = .init(allocator),
        };

        inline for (comptime std.meta.declarations(terms)) |decl| {
            try self.registerTermType(@field(terms, decl.name));
        }

        return self;
    }

    /// Deinitialize this context and all its contents.
    pub fn deinit(self: *Context) void {
        var module_it = self.modules.valueIterator();
        while (module_it.next()) |module_p2p| module_p2p.*.deinit();
        self.modules.deinit(self.allocator);

        self.all_terms.deinit(self.allocator);
        self.name_to_module_guid.deinit(self.allocator);
        self.interned_name_set.deinit(self.allocator);
        self.name_id_to_string.deinit(self.allocator);
        self.interned_data_set.deinit(self.allocator);
        self.shared_terms.deinit(self.allocator);
        self.named_shared_terms.deinit(self.allocator);

        self.arena.deinit();

        self.allocator.destroy(self);
    }

    /// Get the Tag for a term type in the context. See also `registerTermType`.
    pub fn tagFromType(self: *Context, comptime T: type) ?Tag {
        return self.tags.get(@typeName(T));
    }

    /// Register a term type in the context.
    /// Generally, it is not necessary to call this function manually, as all term types in the `terms` namespace are registered automatically on context initialization.
    /// This is provided for extensibility. See also `tagFromType`.
    pub fn registerTermType(self: *Context, comptime T: type) error{ DuplicateTermType, TooManyTermTypes, OutOfMemory }!void {
        if (self.tags.contains(@typeName(T))) {
            return error.DuplicateTermType;
        }

        const tag_number = self.tags.count();
        if (tag_number > std.math.maxInt(std.meta.Tag(Tag))) {
            return error.TooManyTermTypes;
        }

        const tag: Tag = @enumFromInt(tag_number);

        try self.tags.put(self.allocator, @typeName(T), tag);
        errdefer _ = self.tags.remove(@typeName(T));

        try self.vtables.put(self.allocator, tag, TermVTable{
            .eql = @ptrCast(&T.eql),
            .hash = @ptrCast(&T.hash),
            .cbr = @ptrCast(&T.cbr),
            .writeSma = @ptrCast(&T.writeSma),
        });
        errdefer _ = self.vtables.remove(tag);
    }

    /// Create a new module in the context.
    pub fn createModule(self: *Context, name: []const u8, guid: ModuleGUID) error{ DuplicateModuleGUID, DuplicateModuleName, OutOfMemory }!*Module {
        if (self.modules.contains(guid)) {
            return error.DuplicateModuleGUID;
        }

        if (self.name_to_module_guid.contains(name)) {
            return error.DuplicateModuleName;
        }

        const interned_name = try self.internName(name);
        const new_module = try Module.init(self, interned_name, guid);

        try self.name_to_module_guid.put(self.allocator, interned_name.value, guid);
        errdefer _ = self.name_to_module_guid.remove(interned_name.value);

        try self.modules.put(self.allocator, guid, new_module);
        errdefer _ = self.modules.remove(guid);

        return new_module;
    }

    /// Intern a symbolic name in the context. If an identical name already exists, returns a reference to the existing name.
    pub fn internName(self: *Context, name: []const u8) error{OutOfMemory}!Name {
        const gop = try self.interned_name_set.getOrPut(self.allocator, name);

        if (!gop.found_existing) {
            const owned_buf = try self.arena.allocator().dupe(u8, name);
            const fresh_id: NameId = @enumFromInt(self.name_id_to_string.count());
            gop.key_ptr.* = owned_buf;
            gop.value_ptr.* = fresh_id;
            try self.name_id_to_string.put(self.allocator, fresh_id, owned_buf);
        }

        return Name{ .value = gop.key_ptr.* };
    }

    /// Intern a constant data blob in the context. If an identical blob already exists, returns a pointer to the existing BlobHeader.
    pub fn internData(self: *Context, alignment: core.Alignment, bytes: []const u8) error{OutOfMemory}!*const BlobHeader {
        if (self.interned_data_set.getKeyAdapted(.{ alignment, bytes }, BlobHeader.AdaptedHashContext{})) |existing_blob| {
            return existing_blob;
        }

        const new_buf = try self.arena.allocator().alignedAlloc(u8, .fromByteUnits(@alignOf(BlobHeader)), @sizeOf(BlobHeader) + bytes.len);
        const blob: *BlobHeader = @ptrCast(new_buf.ptr);
        blob.* = .{
            .id = @enumFromInt(self.interned_data_set.count()),
            .layout = core.Layout{ .alignment = alignment, .size = @intCast(bytes.len) },
        };
        @memcpy(new_buf.ptr + @sizeOf(BlobHeader), bytes);
        try self.interned_data_set.put(self.allocator, blob, {});

        return blob;
    }

    /// Create a new term in the context. This allocates memory for the term value and returns both a typed pointer to the value and the type-erased Term.
    pub fn createTerm(self: *Context, comptime T: type, module: ?*Module) error{ ZigTypeNotRegistered, OutOfMemory }!struct { *T, Term } {
        const ptr = try TermData(T).allocate(self, module);
        const term = Term.fromPtr(self, ptr);
        try self.all_terms.append(self.allocator, term);
        return .{ ptr, term };
    }

    /// Add a new term to the context. This provides type erasure and memory management for the term value.
    pub fn addTerm(self: *Context, module: ?*Module, value: anytype) error{OutOfMemory}!Term {
        const T = @TypeOf(value);
        const ptr, const term = try self.createTerm(T, module);
        ptr.* = value;
        return term;
    }

    /// Get or create a shared term in the context. If a name is provided, the term is also interned under that name for access with `getNamedSharedTerm`.
    pub fn getOrCreateSharedTerm(self: *Context, name: ?Name, value: anytype) error{ MismatchedNamedTermDefinitions, OutOfMemory }!Term {
        const T = @TypeOf(value);
        if (self.shared_terms.getKeyAdapted(&value, Term.AdaptedIdentityContext(T){ .ctx = self })) |existing_term| {
            if (name) |new_name| {
                if (self.named_shared_terms.get(new_name)) |named_term| {
                    if (named_term != existing_term) return error.MismatchedNamedTermDefinitions;
                } else {
                    try self.named_shared_terms.put(self.allocator, new_name, existing_term);
                }
            }

            return existing_term;
        } else {
            const new_term = try self.addTerm(null, value);
            if (name) |new_name| {
                if (self.named_shared_terms.contains(new_name)) return error.MismatchedNamedTermDefinitions;
                try self.named_shared_terms.put(self.allocator, new_name, new_term);
            }
            try self.shared_terms.put(self.allocator, new_term, {});

            return new_term;
        }
    }

    /// Get a shared term from the context using the name passed when it was interned. See also `getOrCreateSharedTerm`.
    pub fn getNamedSharedTerm(self: *Context, name: Name) ?Term {
        return self.named_shared_terms.get(name.value);
    }

    /// Get a fresh unique TermId for this context.
    pub fn generateTermId(self: *Context) TermId {
        const id = self.fresh_term_id;
        self.fresh_term_id += 1;
        return @enumFromInt(id);
    }
};

/// Identifier for a type within the IR term type registry
pub const Tag = enum(u8) { _ };

/// Unique identifier for a Term within its context.
pub const TermId = enum(u32) { _ };

/// Description of a type erased term in the ir context.
pub const TermHeader = struct {
    /// The root context for this term.
    root: *Context,
    /// The module this term belongs to, if any.
    module: ?*Module,
    /// The tag identifying the term's type.
    tag: Tag,
    /// The offset (forwards) from the header to the term value.
    value_offset: u8,
    /// Unique identifier for this term within its context.
    id: TermId,
    /// The cached CBR for the attached term.
    cached_cbr: ?Cbr = null,

    /// Get the parent TermData pair containing this header.
    fn toTermData(self: *TermHeader, comptime T: type) error{ZigTypeMismatch}!*TermData(T) {
        if (self.tag != self.root.tagFromType(T)) return error.ZigTypeMismatch;
        return @fieldParentPtr("header", self);
    }

    /// Get the Term for this header.
    fn toTerm(self: *TermHeader) Term {
        return .{
            .tag = self.tag,
            .header_offset = self.value_offset,
            .ptr = @intFromPtr(self) + self.value_offset,
        };
    }

    /// Get a typed pointer to the term value.
    fn toTermPtr(self: *TermHeader, comptime T: type) error{ZigTypeMismatch}!*T {
        return &(try self.toTermData(T)).value;
    }

    /// Get an opaque pointer to the term value.
    fn toOpaqueTermAddress(self: *TermHeader) *anyopaque {
        return @ptrFromInt(@intFromPtr(self) + self.value_offset);
    }

    /// Get a TermHeader from a term value.
    fn fromTerm(term: Term) *TermHeader {
        return term.toHeader();
    }

    /// Get a TermHeader from a typed pointer to a term value.
    fn fromTermPtr(ptr: anytype) *TermHeader {
        const data: *TermData(@typeInfo(@TypeOf(ptr)).pointer.child) = @fieldParentPtr("value", ptr);
        return &data.header;
    }

    /// Get the CBR for the attached term.
    fn getCbr(self: *TermHeader) Cbr {
        if (self.cached_cbr) |cached| {
            return cached;
        }

        const new_hash = self.root.vtables.get(self.tag).?.cbr(self.toOpaqueTermAddress());
        self.cached_cbr = new_hash;
        return new_hash;
    }

    /// Write the term in SMA format to the given writer.
    fn writeSma(self: *TermHeader, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u8, @intFromEnum(self.tag), .little);
        try self.root.vtables.get(self.tag).?.writeSma(self.toOpaqueTermAddress(), self.root, writer);
    }
};

/// A vtable of functions for type erased term operations.
pub const TermVTable = struct {
    eql: *const fn (*const anyopaque, *const anyopaque) bool,
    hash: *const fn (*const anyopaque, *QuickHasher) void,
    cbr: *const fn (*const anyopaque) Cbr,
    writeSma: *const fn (*const anyopaque, *Context, *std.io.Writer) error{WriteFailed}!void,
};

/// A pair of a TermHeader and a value of type T. Defines the storage layout for Term objects.
pub fn TermData(comptime T: type) type {
    return struct {
        const Self = @This();

        header: TermHeader,
        value: T,

        fn allocate(context: *Context, module: ?*Module) error{ ZigTypeNotRegistered, OutOfMemory }!*T {
            const self = try context.arena.allocator().create(Self);
            self.header = .{
                .root = context,
                .module = module,
                .tag = context.tagFromType(T) orelse return error.ZigTypeNotRegistered,
                .value_offset = @offsetOf(Self, "value"),
                .id = context.generateTermId(),
            };
            return &self.value;
        }
    };
}

/// A type erased, tagged pointer to a term value in an ir context.
/// Terms represent types and other compile time expressions in the ir.
pub const Term = packed struct(u64) {
    /// The tag identifying the term's type.
    tag: Tag,
    /// The offset (backwards) from the term's value pointer to its header.
    header_offset: u8,
    /// Address of the term's value.
    ptr: u48,

    /// Create a term from a typed pointer to its value.
    fn fromPtr(context: *Context, ptr: anytype) error{ZigTypeMismatch}!Term {
        const T = @typeInfo(@TypeOf(ptr)).pointer.child;
        return .{
            .tag = context.tagFromType(T) orelse return error.ZigTypeMismatch,
            // we need the offset of value so that we can subtract it to get header
            .header_offset = @offsetOf(TermData(T), "value"),
            .ptr = @intCast(@intFromPtr(ptr)),
        };
    }

    /// Get a typed pointer to the term's value.
    pub fn toMutPtr(self: Term, context: *const Context, comptime T: type) error{ZigTypeMismatch}!*T {
        if (self.tag != context.tagFromType(T)) return error.ZigTypeMismatch;
        return @ptrFromInt(self.ptr);
    }

    /// Get an immutable, type checked pointer to the term's value.
    pub fn toPtr(self: Term, context: *const Context, comptime T: type) error{ZigTypeMismatch}!*const T {
        if (self.tag != context.tagFromType(T)) return error.ZigTypeMismatch;
        return @ptrFromInt(self.ptr);
    }

    /// Get an opaque pointer to the term's value.
    fn toOpaquePtr(self: Term) *anyopaque {
        return @ptrFromInt(self.ptr);
    }

    /// Get the TermHeader for this term.
    fn toHeader(self: Term) *TermHeader {
        return @ptrFromInt(self.ptr - self.header_offset);
    }

    /// Get the root context for this term.
    pub fn toRoot(self: Term) *Context {
        return self.toHeader().root;
    }

    /// Get the module this term belongs to, if any.
    pub fn toModule(self: Term) ?*Module {
        return self.toHeader().module;
    }

    /// Get the TermData for this term.
    fn toTermData(self: Term, comptime T: type) error{ZigTypeMismatch}!*TermData(T) {
        return self.toHeader().toTermData();
    }

    /// Get the CBR for this term.
    pub fn getCbr(self: Term) Cbr {
        return self.toHeader().getCbr();
    }

    /// Get the unique id for this term within its context.
    pub fn getId(self: Term) TermId {
        return self.toHeader().id;
    }

    /// Write the term in SMA format to the given writer.
    fn writeSma(self: Term, writer: *std.io.Writer) error{WriteFailed}!void {
        try self.toHeader().writeSma(writer);
    }

    /// An adapted identity context for terms of type T before marshalling and type erasure; used when interning terms.
    pub fn AdaptedIdentityContext(comptime T: type) type {
        return struct {
            ctx: *Context,

            pub fn hash(self: @This(), t: *const T) u64 {
                const tag = self.ctx.tagFromType(T);
                var hasher = QuickHasher.init();
                hasher.hash(tag);
                self.ctx.vtables[@intFromEnum(tag)].cbr(t, &hasher);
                return hasher.final();
            }

            pub fn eql(self: @This(), a: Term, b: *const T) bool {
                const tag = self.ctx.tagFromType(T);
                if (a.tag != tag) return false;
                return self.ctx.vtables[@intFromEnum(tag)].eql(a.toOpaquePtr(), b);
            }
        };
    }

    /// The standard identity context for terms, used in the interned term set.
    pub const IdentityContext = struct {
        pub fn hash(_: @This(), t: Term) u64 {
            var hasher = QuickHasher.init();
            hasher.update(t.tag);
            t.toHeader().root.vtables.get(t.tag).?.hash(t.toOpaquePtr(), &hasher);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: Term, b: Term) bool {
            if (a.tag != b.tag) return false;
            return a.toHeader().root.vtables.get(a.tag).?.eql(a.toOpaquePtr(), b.toOpaquePtr());
        }
    };
};

/// A unique identifier for a ribbon module.
pub const ModuleGUID = enum(u128) { _ };

/// Identifier for a symbolic name within the ir context.
pub const NameId = enum(u32) { _ };

/// A reference to an interned symbolic name within the ir context.
pub const Name = struct {
    value: []const u8,
};

/// Identifier for a data blob within the ir context.
pub const BlobId = enum(u32) { _ };

/// A constant data blob, stored in the ir context. Data such as string literals are stored as blobs.
pub const BlobHeader = struct {
    id: BlobId,
    layout: core.Layout,
    cached_cbr: ?Cbr = null,

    pub fn deinit(self: *const BlobHeader, allocator: std.mem.Allocator) void {
        const base: [*]const u8 = @ptrCast(self);
        allocator.free(base[0 .. @sizeOf(BlobHeader) + self.layout.size]);
    }

    pub fn clone(self: *const BlobHeader, allocator: std.mem.Allocator) error{OutOfMemory}!*const BlobHeader {
        const new_buf = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(BlobHeader)), @sizeOf(BlobHeader) + self.layout.size);
        const new_blob: *BlobHeader = @ptrCast(new_buf.ptr);
        new_blob.* = self.*;
        @memcpy(new_buf.ptr + @sizeOf(BlobHeader), self.getBytes());
        return new_blob;
    }

    pub fn deserialize(reader: *std.io.Reader, id: BlobId, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!*const BlobHeader {
        const alignment = try reader.takeInt(u32, .little);
        const size = try reader.takeInt(u32, .little);

        const new_buf = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(BlobHeader)), @sizeOf(BlobHeader) + size);
        const blob: *BlobHeader = @ptrCast(new_buf.ptr);
        blob.* = .{
            .id = id, // id will be assigned when interned
            .layout = core.Layout{ .alignment = @intCast(alignment), .size = @intCast(size) },
        };

        const bytes = (new_buf.ptr + @sizeOf(BlobHeader))[0..size];

        var writer = std.io.Writer.fixed(bytes);

        reader.streamExact(&writer, size) catch return error.ReadFailed;

        return blob;
    }

    pub fn serialize(self: *const BlobHeader, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u32, @intCast(self.layout.alignment), .little);
        try writer.writeInt(u32, @intCast(self.layout.size), .little);
        try writer.writeAll(self.getBytes());
    }

    /// Get the (unaligned) byte value for this blob.
    pub inline fn getBytes(self: *const BlobHeader) []const u8 {
        return (@as([*]const u8, @ptrCast(self)) + @sizeOf(BlobHeader))[0..self.layout.size];
    }

    /// Get the CBR for this blob.
    pub fn getCbr(self: *const BlobHeader) error{OutOfMemory}!u128 {
        if (self.cached_cbr) |cached| {
            return cached;
        }

        var hasher = CbrHasher.init();
        hasher.update("Blob");

        hasher.update("id:");
        hasher.update(self.id);

        hasher.update("layout:");
        hasher.update(self.layout);

        hasher.update("bytes:");
        hasher.update(self.getBytes());

        const buf = hasher.final();
        @constCast(self).cached_cbr = buf;
        return buf;
    }

    /// An adapted hash context for blobs, used when interning yet-unmarshalled data.
    pub const AdaptedHashContext = struct {
        pub fn hash(_: @This(), descriptor: struct { core.Alignment, []const u8 }) u64 {
            const layout = core.Layout{ .alignment = descriptor[0], .size = @intCast(descriptor[1].len) };
            var hasher = QuickHasher.init();
            hasher.update(layout);
            hasher.update(descriptor[1]);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: *const BlobHeader, b: struct { core.Alignment, []const u8 }) bool {
            const layout = core.Layout{ .alignment = b[0], .size = @intCast(b[1].len) };
            if (a.layout != layout) return false;
            return std.mem.eql(u8, a.getBytes(), b[1]);
        }
    };

    /// The standard hash context for blobs, used in the interned data set.
    pub const HashContext = struct {
        pub fn hash(_: @This(), blob: *const BlobHeader) u64 {
            var hasher = QuickHasher.init();
            hasher.update(blob.layout);
            hasher.update(blob.getBytes());
            return hasher.final();
        }

        pub fn eql(_: @This(), a: *const BlobHeader, b: *const BlobHeader) bool {
            if (a.layout != b.layout) return false;
            return std.mem.eql(u8, a.getBytes(), b.getBytes());
        }
    };
};

/// An ir module, representing a single compilation unit within a context/compilation session.
pub const Module = struct {
    /// The context this module belongs to.
    root: *Context,
    /// Globally unique identifier for this module.
    guid: ModuleGUID,
    /// Symbolic name of this module.
    name: Name,

    /// Symbols exported from this module.
    exported_symbols: common.StringMap(Binding) = .empty,
    /// Pool allocator for functions in this module.
    function_pool: common.ManagedPool(Function),
    /// Pool allocator for blocks in this module.
    block_pool: common.ManagedPool(Block),

    /// Id generation state for this module.
    fresh_ids: struct {
        function: std.meta.Tag(FunctionId) = 0,
        block: std.meta.Tag(BlockId) = 0,
    } = .{},

    /// The cached CBR for the module.
    cached_cbr: ?Cbr = null,

    /// Create a new module in the given context.
    pub fn init(root: *Context, name: Name, guid: ModuleGUID) !*Module {
        const self = try root.arena.allocator().create(Module);

        self.* = Module{
            .root = root,
            .guid = guid,
            .name = name,
            .function_pool = .init(root.allocator),
            .block_pool = .init(root.allocator),
        };

        return self;
    }

    /// Deinitialize this module and all its contents.
    pub fn deinit(self: *Module) void {
        self.exported_symbols.deinit(self.root.allocator);

        var func_it = self.function_pool.iterate();
        while (func_it.next()) |func_p2p| func_p2p.*.deinit();
        self.function_pool.deinit();

        var block_it = self.block_pool.iterate();
        while (block_it.next()) |block_p2p| block_p2p.*.deinit();
        self.block_pool.deinit();
    }

    /// Export a term from this module.
    pub fn exportTerm(self: *Module, name: Name, term: Term) error{ DuplicateModuleExports, OutOfMemory }!void {
        const gop = try self.exported_symbols.getOrPut(self.root.allocator, name.value);
        if (gop.found_existing) {
            return error.DuplicateModuleExports;
        }
        gop.value_ptr.* = .{ .term = term };
    }

    /// Export a function from this module.
    pub fn exportFunction(self: *Module, name: Name, function: *Function) error{ DuplicateModuleExports, OutOfMemory }!void {
        const gop = try self.exported_symbols.getOrPut(self.root.allocator, name.value);
        if (gop.found_existing) {
            return error.DuplicateModuleExports;
        }
        gop.value_ptr.* = .{ .function = function };
    }

    /// Generate a fresh unique FunctionId for this module.
    pub fn generateFunctionId(self: *Module) FunctionId {
        const id = self.fresh_ids.function;
        self.fresh_ids.function += 1;
        return @enumFromInt(id);
    }

    /// Generate a fresh unique BlockId for this module.
    pub fn generateBlockId(self: *Module) BlockId {
        const id = self.fresh_ids.block;
        self.fresh_ids.block += 1;
        return @enumFromInt(id);
    }

    /// Calculate the cbr for this module.
    pub fn getCbr(self: *Module) Cbr {
        if (self.cached_cbr) |cached| {
            return cached;
        }

        var hasher = CbrHasher.init();
        hasher.update("Module");

        hasher.update("guid:");
        hasher.update(self.guid);

        hasher.update("exports:");
        var exp_it = self.exported_symbols.iterator(); // TODO: this is incorrect as the map iterator order is arbitrary
        while (exp_it.next()) |exp_kv| {
            const exp_name_id = self.root.interned_name_set.get(exp_kv.key_ptr.*).?;
            const binding = exp_kv.value_ptr.*;

            hasher.update("name:");
            hasher.update(exp_name_id);

            switch (binding) {
                .term => |t| {
                    hasher.update("term:");
                    hasher.update(t.getCbr()); // TODO: probably need to handle globals differently than types here
                },
                .function => |f| {
                    hasher.update("function:");
                    hasher.update(f.type.getCbr());
                },
            }
        }

        const buf = hasher.final();
        self.cached_cbr = buf;
        return buf;
    }

    /// Write the module in SMA format to the given writer.
    pub fn writeSma(self: *Module, writer: *std.io.Writer) error{WriteFailed}!void {
        const mod_name_id = self.root.interned_name_set.get(self.name.value).?;

        try writer.writeInt(u128, @intFromEnum(self.guid), .little);
        try writer.writeInt(u128, self.getCbr(), .little);
        try writer.writeInt(u32, @intFromEnum(mod_name_id), .little);

        try writer.writeInt(u32, @intCast(self.exported_symbols.count()), .little);
        var exp_it = self.exported_symbols.iterator();
        while (exp_it.next()) |exp_kv| {
            const exp_name_id = self.root.interned_name_set.get(exp_kv.key_ptr.*).?;
            const binding = exp_kv.value_ptr.*;

            try writer.writeInt(u32, @intFromEnum(exp_name_id), .little);
            switch (binding) {
                .term => |t| {
                    try writer.writeInt(u8, 0, .little); // term binding
                    try writer.writeInt(u32, @intFromEnum(t.getId()), .little);
                },
                .function => |f| {
                    try writer.writeInt(u8, 1, .little); // function binding
                    try writer.writeInt(u32, @intFromEnum(f.id), .little);
                },
            }

            // TODO:
            // write all the functions in the module
            // write all the blocks in the module
            // this also seems like it should be done via traversal of exports; but ordering is an issue here as well (see Context.writeSmaTerms)
        }
    }
};

/// A binding exported from a module.
pub const Binding = union(enum) {
    /// A term binding.
    term: Term,
    /// A function binding.
    function: *Function,
};

/// Identifier for an instruction within a block.
pub const InstructionId = enum(u32) { _ };

/// An instruction within a basic block.
pub const Instruction = struct {
    /// The block that contains this operation.
    block: *Block,
    /// Function-unique id for this instruction, used for hashing and debugging.
    id: InstructionId,
    /// The type of value produced by this operation, if any.
    type: Term,
    /// The command code for this operation, ie an Operation or Termination.
    command: u8,
    /// The number of operands encoded after this Instruction in memory.
    num_operands: usize,

    /// Optional debug name for the SSA variable binding the result of this operation.
    name: ?Name = null,

    /// The first operation in the block, or null if this is the first operation.
    prev: ?*Instruction = null,
    /// The next operation in the block, or null if this is the last operation.
    next: ?*Instruction = null,

    /// The first use of the SSA variable produced by this instruction, or null if the variable is never used.
    first_user: ?*Use = null,

    /// A pointer to the head of the singly-linked list of all Uses that refer to this Instruction.
    pub fn init(block: *Block, ty: Term, command: anytype, name: ?Name, ops: []const Operand) error{OutOfMemory}!*Instruction {
        comptime {
            // invariant: the Instruction struct must be aligned such that the operands can be placed directly after it
            std.debug.assert(@alignOf(Instruction) >= @alignOf(Use));

            const T = @TypeOf(command);
            if (T != Operation and T != Termination) {
                @compileError("Instruction command must be an Operation or Termination");
            }
        }

        const buf = try block.arena.alignedAlloc(
            u8,
            .fromByteUnits(@alignOf(Instruction)),
            @sizeOf(Instruction) + @sizeOf(Use) * ops.len,
        );

        const self: *Instruction = @ptrCast(buf.ptr);
        const uses = self.operands();
        self.* = Instruction{
            .block = block,
            .id = block.module.generateInstructionId(),
            .type = ty,
            .command = @intFromEnum(command),
            .num_operands = ops.len,
            .name = name,
        };

        for (ops, uses) |op, *use| {
            use.* = Use{
                .operand = op,
                .user = self,
            };

            if (op == .variable) {
                const var_inst = op.variable;
                const var_first_user = var_inst.first_user;
                use.next = var_first_user;
                var_inst.first_user = use;
            }
        }

        return self;
    }

    /// Get a slice of the operands encoded after this Instruction in memory.
    pub fn operands(self: *Instruction) []Use {
        // invariant: the Instruction struct must be sized such that the operands can be placed directly after it
        comptime std.debug.assert(common.alignDelta(@sizeOf(Instruction), @alignOf(Use)) == 0);

        return @as([*]Use, @ptrCast(@alignCast(@as([*]u8, @ptrCast(self)) + @sizeOf(Instruction))))[0..self.num_operands];
    }

    /// Determine if this Instruction is a Termination.
    pub fn isTermination(self: *Instruction) bool {
        return self.command < Operation.start_offset;
    }

    /// Determine if this Instruction is an Operation.
    pub fn isOperation(self: *Instruction) bool {
        return self.command >= Operation.start_offset;
    }

    /// Determine if this Instruction is an extension op.
    pub fn isExtension(self: *Instruction) bool {
        return self.command >= Operation.extension_offset;
    }

    /// Cast this Instruction's command to a Termination. Returns null if this Instruction is an Operation.
    pub fn asTermination(self: *Instruction) ?Termination {
        return if (self.isTermination()) @enumFromInt(self.command) else null;
    }

    /// Cast this Instruction's command to an Operation. Returns null if this Instruction is a Termination.
    pub fn asOperation(self: *Instruction) ?Operation {
        return if (self.isOperation()) @enumFromInt(self.command) else null;
    }

    /// Cast this Instruction's command to a specific value. Returns false if this Instruction does not match the expected command.
    pub fn isCommand(self: *Instruction, command: anytype) bool {
        const expected_command = @intFromEnum(command);
        return self.command == expected_command;
    }

    /// Get the CBR for this instruction.
    pub fn getCbr(self: *Instruction) Cbr {
        var hasher = CbrHasher.init();
        hasher.update("Instruction");

        hasher.update("id:");
        hasher.update(self.id);

        hasher.update("name:");
        if (self.name) |name| {
            hasher.update(name.value);
        } else {
            hasher.update("[null]");
        }

        hasher.update("type:");
        hasher.update(self.type.getCbr());

        hasher.update("command:");
        hasher.update(self.command);

        for (self.operands(), 0..) |use, i| {
            hasher.update("operand.index:");
            hasher.update(i);

            hasher.update("operand.value:");
            hasher.update(use.operand.getCbr());
        }

        return hasher.final();
    }
};

/// An operand to an instruction.
pub const Operand = union(enum) {
    /// A term operand.
    term: Term,
    /// A reference to a data blob.
    blob: *const BlobHeader,
    /// A reference to a basic block.
    block: *Block,
    /// A reference to a function.
    function: *Function,
    /// A reference to an instruction producing an SSA variable.
    variable: *Instruction,

    /// Get the CBR for this operand.
    pub fn getCbr(self: Operand) Cbr {
        var hasher = CbrHasher.init();
        hasher.update("Operand");

        switch (self) {
            .term => |term| {
                hasher.update("term:");
                hasher.update(term.getCbr());
            },
            .blob => |blob| {
                hasher.update("blob:");
                hasher.update(blob.id);
            },
            .block => |block| {
                hasher.update("block:");
                hasher.update(block.id);
            },
            .function => |function| {
                // We must include the module guid to differentiate between internal and external references
                hasher.update("function.module.guid:");
                hasher.update(function.module.guid);
                hasher.update("function.id:");
                hasher.update(function.id);
            },
            .variable => |variable| {
                // We must include the block id to differentiate between variables with the same id in different blocks
                hasher.update("variable.block.id:");
                hasher.update(variable.block.id);
                hasher.update("variable.id:");
                hasher.update(variable.id);
            },
        }

        return hasher.final();
    }
};

/// A use of an operand by an instruction.
pub const Use = struct {
    /// The operand being used.
    operand: Operand,
    /// Back pointer to the Instruction that uses this operand.
    user: *Instruction,
    /// Next use of the same operand if it is an ssa variable.
    next: ?*Use = null,
};

/// Identifier for a function within a module.
pub const FunctionId = enum(u32) { _ };

/// A procedure or effect handler within a module.
pub const Function = struct {
    /// The context this function belongs to.
    module: *Module,
    /// Globally unique id for this function, used for hashing and debugging.
    id: FunctionId,
    /// The kind of function, either a procedure or an effect handler.
    kind: Kind,
    /// The type of this function, which must be a function type or a polymorphic type that instantiates to a function.
    type: Term,
    /// The entry block of this function.
    entry: *Block,
    /// Storage for the function's instructions.
    /// While slightly less memory efficient than a Pool, this allows us to include operands in the same allocation as the instruction.
    arena: std.heap.ArenaAllocator,

    /// Optional abi name for this function.
    name: ?Name = null,

    /// Cached CBR for this function.
    cached_cbr: ?Cbr = null,

    pub fn init(module: *Module, name: ?Name, kind: Kind, ty: Term) error{OutOfMemory}!*Function {
        const self = try module.function_pool.create();
        const entry_name = try module.root.internName("entry");
        self.* = Function{
            .module = module,
            .id = module.generateFunctionId(),
            .kind = kind,
            .type = ty,

            .entry = try Block.init(module, self, entry_name),
            .arena = .init(module.root.allocator),

            .name = name,
        };
        return self;
    }

    pub fn deinit(self: *Function) void {
        self.arena.deinit();
    }

    /// The kind of a function, either a procedure or an effect handler.
    pub const Kind = enum(u1) {
        /// The function is a normal procedure.
        procedure,
        /// The function is an effect handler.
        handler,
    };

    /// Get the CBR for this function.
    pub fn getCbr(self: *Function) Cbr {
        if (self.cached_cbr) |cached| {
            return cached;
        }

        var hasher = CbrHasher.init();
        hasher.update("Function");

        // We must include the module guid to differentiate between internal and external references
        hasher.update("module.guid:");
        hasher.update(self.module.guid);

        hasher.update("id:");
        hasher.update(self.id);

        hasher.update("name:");
        if (self.name) |name| {
            hasher.update(name.value);
        } else {
            hasher.update("[null]");
        }

        hasher.update("type:");
        hasher.update(self.type.getCbr());

        hasher.update("kind:");
        hasher.update(self.kind);

        hasher.update("body:");
        hasher.update(self.entry.getCbr());

        const buf = hasher.final();

        self.cached_cbr = buf;

        return buf;
    }
};

/// Identifier for a basic block within a function.
pub const BlockId = enum(u32) { _ };

/// A basic block within a function's control flow graph.
pub const Block = struct {
    /// The module this block belongs to.
    module: *Module,

    /// The arena allocator for instructions in this block.
    arena: std.mem.Allocator,
    /// Globally unique id for this block within its function, used for hashing and debugging.
    id: BlockId,

    /// Optional debug name for this block.
    name: ?Name = null,

    /// The function this block belongs to, if any.
    function: ?*Function = null,

    /// The first operation in this block, or null if the block is empty.
    first_op: ?*Instruction = null,
    /// The last operation in this block, or null if the block is empty.
    last_op: ?*Instruction = null,

    /// Predecessor blocks in the control flow graph.
    predecessors: common.ArrayList(*Block) = .empty,
    /// Successor blocks in the control flow graph.
    successors: common.ArrayList(*Block) = .empty,

    /// Cached CBR for this block.
    cached_cbr: ?Cbr = null,

    /// Source for instruction ids within this block.
    fresh_instruction_id: std.meta.Tag(InstructionId) = 0,

    pub fn init(module: *Module, function: ?*Function, name: ?Name) error{OutOfMemory}!*Block {
        const self = try module.block_pool.create();
        self.* = Block{
            .module = module,
            .id = module.generateBlockId(),
            .name = name,
            .arena = if (function) |f| f.arena.allocator() else module.root.arena.allocator(),
            .function = function,
        };
        return self;
    }

    pub fn deinit(self: *Block) void {
        self.predecessors.deinit(self.module.root.allocator);
        self.successors.deinit(self.module.root.allocator);
    }

    /// An iterator over the instructions in a Block.
    pub const Iterator = struct {
        op: ?*Instruction,
        /// Advance the linked list pointer and return the current instruction.
        pub fn next(self: *Iterator) ?*Instruction {
            const current = self.op orelse return null;
            self.op = current.next;
            return current;
        }
    };

    /// Get an iterator over the instructions in this block.
    pub fn iterate(self: *Block) Iterator {
        return Iterator{ .op = self.first_op };
    }

    /// Get the CBR for this block.
    pub fn getCbr(self: *Block) Cbr {
        if (self.cached_cbr) |cached| {
            return cached;
        }

        var visited = common.UniqueReprSet(*Block).empty;
        defer visited.deinit(self.module.root.allocator);

        return self.getCbrRecurse(&visited) catch |err| {
            std.debug.panic("Failed to compute CBR for Block: {}\n", .{err});
        };
    }

    /// Recursive helper for computing the CBR of this block, tracking visited blocks to avoid cycles.
    fn getCbrRecurse(self: *Block, visited: *common.UniqueReprSet(*Block)) error{OutOfMemory}!Cbr {
        if (self.cached_cbr) |cached| {
            return cached;
        }

        var hasher = CbrHasher.init();
        hasher.update("Block");

        // We must include the module guid to differentiate between internal and external references
        hasher.update("module.guid:");
        hasher.update(self.module.guid);

        hasher.update("block_id:");
        hasher.update(self.id);

        if (visited.contains(self)) {
            const buf = hasher.final();
            self.cached_cbr = buf;
            return buf;
        }

        try visited.put(self.module.root.allocator, self, {});

        hasher.update("name:");
        if (self.name) |name| {
            hasher.update(name.value);
        } else {
            hasher.update("[null]");
        }

        {
            var op_it = self.iterate();
            var i: usize = 0;

            hasher.update("operations:");
            while (op_it.next()) |op| : (i += 1) {
                hasher.update("op.index:");
                hasher.update(i);

                hasher.update("op.value:");
                hasher.update(op.getCbr());
            }
        }

        hasher.update("predecessors:");
        for (self.predecessors.items, 0..) |pred, i| {
            hasher.update("pred.index:");
            hasher.update(i);

            hasher.update("pred.value:");
            hasher.update(pred.getCbrRecurse(visited));
        }

        hasher.update("successors:");
        for (self.successors.items, 0..) |succ, i| {
            hasher.update("succ.index:");
            hasher.update(i);

            hasher.update("succ.value:");
            hasher.update(succ.getCbrRecurse(visited));
        }

        const buf = hasher.final();
        self.cached_cbr = buf;
        return buf;
    }

    pub fn generateInstructionId(self: *Block) InstructionId {
        const id = self.fresh_instruction_id;
        self.fresh_instruction_id += 1;
        return @enumFromInt(id);
    }
};

/// Defines the action performed by a Termination
pub const Termination = enum(u8) {
    /// represents an unreachable point in the program
    @"unreachable",
    /// returns a value from a function
    @"return",
    /// calls an effect handler;
    /// must provide one successor block for the nominal return; a second successor block is taken from the handlerset for the cancellation
    // TODO: should this just take two successor blocks directly? not sure which would be better
    prompt,
    /// returns a substitute value from an effect handler's binding block
    cancel,
    /// unconditionally branches to a block
    br,
    /// conditionally branches to a block
    br_if,
    /// runtime panic
    panic,
    /// returns an ssa variable as the value of a term
    lift,
};

/// Defines the action performed by an Operation
pub const Operation = enum(u8) {
    /// The offset at which Operations start in the instruction command space.
    /// We start the Operation enum at the end of the Termination enum so they can both be compared generically to u8
    pub const start_offset = calc_offset: {
        const tags = std.meta.tags(Termination);
        break :calc_offset @intFromEnum(tags[tags.len - 1]) + 1;
    };

    /// allocate a value on the stack and return a pointer to it
    stack_alloc = start_offset,
    /// load a value from an address
    load,
    /// store a value to an address
    store,
    /// get an element pointer from a pointer
    get_element_ptr,
    /// get the address of a global
    get_address,
    /// create an ssa variable merging values from predecessor blocks
    phi,
    /// addition
    add,
    /// subtraction
    sub,
    /// multiplication
    mul,
    /// division
    div,
    /// remainder division
    rem,
    /// equality comparison
    eq,
    /// inequality comparison
    ne,
    /// less than comparison
    lt,
    /// less than or equal comparison
    le,
    /// greater than comparison
    gt,
    /// greater than or equal comparison
    ge,
    /// logical and
    l_and,
    /// logical or
    l_or,
    /// logical not
    l_not,
    /// bitwise and
    b_and,
    /// bitwise or
    b_or,
    /// bitwise xor
    b_xor,
    /// bitwise left shift
    b_shl,
    /// bitwise right shift
    b_shr,
    /// bitwise not
    b_not,
    /// direct bitcast between types, changing meaning without changing value
    bitcast,
    /// indirect cast between types, changing value without changing meaning
    convert,
    /// calls a standard function
    call,
    /// lowers a term to an ssa variable
    reify,
    /// pushes a new effect handler set onto the stack
    push_set,
    /// pops the current effect handler set from the stack
    pop_set,
    /// represents a debugger breakpoint
    breakpoint,
    /// user-defined operations, which must be handled by extensions
    _,

    /// The offset at which extension Operations start in the instruction command space.
    pub const extension_offset = @intFromEnum(Operation.breakpoint) + 1;
};

/// A namespace for all builtin ir Term definitions.
pub const terms = struct {
    /// Binds information about a global variable.
    pub const Global = struct {
        name: Name,
        type: Term,
        initializer: Term,

        pub fn eql(self: *const Global, other: *const Global) bool {
            return self.name.value.ptr == other.name.value.ptr and self.type == other.type and self.initializer == other.initializer;
        }

        pub fn hash(self: *const Global, hasher: *QuickHasher) void {
            hasher.update(self.name.value.ptr);
            hasher.update(self.type);
            hasher.update(self.initializer);
        }

        pub fn cbr(self: *const Global) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("Global");

            hasher.update("name:");
            hasher.update(self.name.value);

            hasher.update("type:");
            hasher.update(self.type.getCbr());

            hasher.update("initializer:");
            hasher.update(self.initializer.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const Global, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            const name_id = context.interned_name_set.get(self.name.value).?;
            try writer.writeInt(u32, @intFromEnum(name_id), .little);
            try writer.writeInt(u32, @intFromEnum(self.type.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.initializer.getId()), .little);
        }
    };

    /// Binds a set of handlers and cancellation information for a push_set instruction
    pub const HandlerSet = struct {
        /// the set of handlers in this handler set
        handlers: []const *Function,
        /// a HandlerType that describes the unified type of the handlers in this set
        handler_type: Term,
        /// the type of value the handler set resolves to, either directly or by cancellation
        result_type: Term,
        /// the basic block where this handler set yields its value
        cancellation_point: *Block,

        pub fn eql(self: *const HandlerSet, other: *const HandlerSet) bool {
            if (self.handlers.len != other.handlers.len or self.handler_type != other.handler_type or self.result_type != other.result_type or self.cancellation_point != other.cancellation_point) return false;
            for (0..self.handlers.len) |i| {
                if (self.handlers[i] != other.handlers[i]) return false;
            }
            return true;
        }

        pub fn hash(self: *const HandlerSet, hasher: *QuickHasher) void {
            hasher.update(self.handlers.len);
            for (self.handlers) |handler| {
                hasher.update(handler);
            }
            hasher.update(self.handler_type);
            hasher.update(self.result_type);
            hasher.update(self.cancellation_point);
        }

        pub fn cbr(self: *const HandlerSet) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("HandlerSet");

            hasher.update("handlers.count:");
            hasher.update(self.handlers.len);

            hasher.update("handlers:");
            for (self.handlers) |handler| {
                hasher.update("handler:");
                hasher.update(handler.getCbr());
            }

            hasher.update("handler_type:");
            hasher.update(self.handler_type.getCbr());

            hasher.update("result_type:");
            hasher.update(self.result_type.getCbr());

            hasher.update("cancellation_point:");
            hasher.update(self.cancellation_point.id);

            return hasher.final();
        }

        pub fn writeSma(self: *const HandlerSet, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intCast(self.handlers.len), .little);
            for (self.handlers) |handler| {
                try writer.writeInt(u128, @intFromEnum(handler.module.guid), .little);
                try writer.writeInt(u32, @intFromEnum(handler.id), .little);
            }
            try writer.writeInt(u32, @intFromEnum(self.handler_type.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.result_type.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.cancellation_point.id), .little);
        }
    };

    /// Binds a set of member definitions for a typeclass
    pub const Implementation = struct {
        class: Term,
        members: []const Field,

        pub const Field = struct {
            name: Name,
            value: Term,
        };

        pub fn eql(self: *const Implementation, other: *const Implementation) bool {
            if (self.class != other.class and self.members.len == other.members.len) return false;

            for (0..self.members.len) |i| {
                const field1 = self.members[i];
                const field2 = other.members[i];
                if (field1.name.value.ptr != field2.name.value.ptr or field1.value != field2.value) return false;
            }

            return true;
        }

        pub fn hash(self: *const Implementation, hasher: *QuickHasher) void {
            hasher.update(self.class);
            hasher.update(self.members.len);
            for (self.members) |field| {
                hasher.update(field.name.value.ptr);
                hasher.update(field.value);
            }
        }

        pub fn cbr(self: *const Implementation) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("Implementation");

            hasher.update("class:");
            hasher.update(self.class.getCbr());

            hasher.update("members.count:");
            hasher.update(self.members.len);

            hasher.update("members:");
            for (self.members) |field| {
                hasher.update("field.name:");
                hasher.update(field.name.value);

                hasher.update("field.value:");
                hasher.update(field.value.getCbr());
            }

            return hasher.final();
        }

        pub fn writeSma(self: *const Implementation, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            try writer.writeInt(u32, @intFromEnum(self.class.getId()), .little);
            try writer.writeInt(u32, @intCast(self.members.len), .little);
            for (self.members) |field| {
                const name_id = context.interned_name_set.get(field.name.value).?;
                try writer.writeInt(u32, @intFromEnum(name_id), .little);
                try writer.writeInt(u32, @intFromEnum(field.value.getId()), .little);
            }
        }
    };

    /// A symbol is a term that can appear in both values and types, and is simply a nominative identity in the form of a name.
    pub const Symbol = struct {
        name: Name,

        pub fn eql(self: *const Symbol, other: *const Symbol) bool {
            return self.name.value.ptr == other.name.value.ptr;
        }

        pub fn hash(self: *const Symbol, hasher: *QuickHasher) void {
            hasher.update(self.name.value.ptr);
        }

        pub fn cbr(self: *const Symbol) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("Symbol");

            hasher.update(self.name.value);

            return hasher.final();
        }

        pub fn writeSma(self: *const Symbol, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            const name_id = context.interned_name_set.get(self.name.value).?;
            try writer.writeInt(u32, @intFromEnum(name_id), .little);
        }
    };

    /// Data for a typeclass repr.
    pub const Class = struct {
        /// Nominative identity for this typeclass.
        name: Name,
        /// Descriptions of each element required for the implementation of this typeclass.
        elements: []const Field = &.{},

        pub const Field = struct {
            name: Name,
            type: Term,
        };

        pub fn eql(self: *const Class, other: *const Class) bool {
            if (self.name.value.ptr != other.name.value.ptr and self.elements.len == other.elements.len) return false;

            for (0..self.elements.len) |i| {
                const field1 = self.elements[i];
                const field2 = other.elements[i];
                if (field1.name.value.ptr != field2.name.value.ptr or field1.type != field2.type) return false;
            }

            return true;
        }

        pub fn hash(self: *const Class, hasher: *QuickHasher) void {
            hasher.update(self.name);
            hasher.update(self.elements.len);
            for (self.elements) |field| {
                hasher.update(field.name.value.ptr);
                hasher.update(field.type);
            }
        }

        pub fn cbr(self: *const Class) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("Class");

            hasher.update("name:");
            hasher.update(self.name.value);

            hasher.update("elements.count:");
            hasher.update(self.elements.len);

            hasher.update("elements:");
            for (self.elements) |elem| {
                hasher.update("elem.name:");
                hasher.update(elem.name.value);

                hasher.update("elem.type:");
                hasher.update(elem.type.getCbr());
            }

            return hasher.final();
        }

        pub fn writeSma(self: *const Class, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            const name_id = context.interned_name_set.get(self.name.value).?;
            try writer.writeInt(u32, @intFromEnum(name_id), .little);
            try writer.writeInt(u32, @intCast(self.elements.len), .little);
            for (self.elements) |field| {
                const field_name_id = context.interned_name_set.get(field.name.value).?;
                try writer.writeInt(u32, @intFromEnum(field_name_id), .little);
                try writer.writeInt(u32, @intFromEnum(field.type.getId()), .little);
            }
        }
    };

    /// Data for an effect repr.
    pub const Effect = struct {
        /// Nominative identity for this effect.
        name: Name,
        /// Descriptions of each element required for the handling of this effect.
        elements: []const Field = &.{},

        pub const Field = struct {
            name: Name,
            type: Term,
        };

        pub fn eql(self: *const Effect, other: *const Effect) bool {
            if (self.name.value.ptr != other.name.value.ptr or self.elements.len != other.elements.len) return false;

            for (0..self.elements.len) |i| {
                const field1 = self.elements[i];
                const field2 = other.elements[i];
                if (field1.name.value.ptr != field2.name.value.ptr or field1.type != field2.type) return false;
            }

            return true;
        }

        pub fn hash(self: *const Effect, hasher: *QuickHasher) void {
            hasher.update(self.name);
            hasher.update(self.elements.len);
            for (self.elements) |field| {
                hasher.update(field.name.value.ptr);
                hasher.update(field.type);
            }
        }

        pub fn cbr(self: *const Effect) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("Effect");

            hasher.update("name:");
            hasher.update(self.name.value);

            hasher.update("elements.count:");
            hasher.update(self.elements.len);

            hasher.update("elements:");
            for (self.elements) |elem| {
                hasher.update("elem.name:");
                hasher.update(elem.name.value);

                hasher.update("elem.type:");
                hasher.update(elem.type.getCbr());
            }

            return hasher.final();
        }

        pub fn writeSma(self: *const Effect, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            const name_id = context.interned_name_set.get(self.name.value).?;
            try writer.writeInt(u32, @intFromEnum(name_id), .little);
            try writer.writeInt(u32, @intCast(self.elements.len), .little);
            for (self.elements) |field| {
                const field_name_id = context.interned_name_set.get(field.name.value).?;
                try writer.writeInt(u32, @intFromEnum(field_name_id), .little);
                try writer.writeInt(u32, @intFromEnum(field.type.getId()), .little);
            }
        }
    };

    /// Defines a variable in a Polymorphic repr.
    pub const Quantifier = struct {
        /// Unique ID binding variables within a PolymorphicType.
        id: u32,
        /// Type kind required for instantiations of this quantifier.
        kind: Term,

        pub fn eql(self: *const Quantifier, other: *const Quantifier) bool {
            return self.id == other.id and self.kind == other.kind;
        }

        pub fn hash(self: *const Quantifier, hasher: *QuickHasher) void {
            hasher.update(self.id);
            hasher.update(self.kind);
        }

        pub fn cbr(self: *const Quantifier) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("Quantifier");

            hasher.update("id:");
            hasher.update(self.id);

            hasher.update("kind:");
            hasher.update(self.kind.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const Quantifier, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, self.id, .little);
            try writer.writeInt(u32, @intFromEnum(self.kind.getId()), .little);
        }
    };

    /// The kind of a type that is a symbolic identity.
    pub const SymbolKind = IdentityTerm("SymbolKind");

    /// The kind of a standard type.
    pub const TypeKind = IdentityTerm("TypeKind");

    /// The kind of a type class type.
    pub const ClassKind = IdentityTerm("ClassKind");

    /// The kind of an effect type.
    pub const EffectKind = IdentityTerm("EffectKind");

    /// The kind of a handler type.
    pub const HandlerKind = IdentityTerm("HandlerKind");

    /// The kind of a raw function type.
    pub const FunctionKind = IdentityTerm("FunctionKind");

    /// The kind of a type constraint.
    pub const ConstraintKind = IdentityTerm("ConstraintKind");

    /// The kind of a data value lifted to type level.
    pub const LiftedDataKind = struct {
        unlifted_type: Term,

        pub fn eql(self: *const LiftedDataKind, other: *const LiftedDataKind) bool {
            return self.unlifted_type == other.unlifted_type;
        }

        pub fn hash(self: *const LiftedDataKind, hasher: *QuickHasher) void {
            hasher.update(self.unlifted_type);
        }

        pub fn cbr(self: *const LiftedDataKind) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("LiftedDataKind");
            hasher.update(self.unlifted_type.getCbr());
            return hasher.final();
        }

        pub fn writeSma(self: *const LiftedDataKind, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.unlifted_type.getId()), .little);
        }
    };

    /// The kind of type constructors, functions on types.
    pub const ArrowKind = struct {
        /// The kind of the input type provided to a constructor of this arrow kind.
        input: Term,
        /// The kind of the output type produced by a constructor of this arrow kind.
        output: Term,

        pub fn eql(self: *const ArrowKind, other: *const ArrowKind) bool {
            return self.input == other.input and self.output == other.output;
        }

        pub fn hash(self: *const ArrowKind, hasher: *QuickHasher) void {
            hasher.update(self.input);
            hasher.update(self.output);
        }

        pub fn cbr(self: *const ArrowKind) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("ArrowKind");

            hasher.update("input:");
            hasher.update(self.input.getCbr());

            hasher.update("output:");
            hasher.update(self.output.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const ArrowKind, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.input.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.output.getId()), .little);
        }
    };

    /// Type data for a void type repr.
    pub const VoidType = IdentityTerm("VoidType");

    /// Type data for a boolean type repr.
    pub const BoolType = IdentityTerm("BoolType"); // TODO: it may be better to represent this as a sum or enum; currently this was chosen because bool is a bit special in that it is representable as a single bit. Ideally, this property should be representable on the aformentioned options as well.

    /// Type data for a unit type repr.
    pub const UnitType = IdentityTerm("UnitType");

    /// Type data for the top type repr representing the absence of control flow resulting from an expression.
    pub const NoReturnType = IdentityTerm("NoReturnType");

    /// Type data for an integer type repr.
    pub const IntegerType = struct {
        /// Indicates whether or not the integer type is signed.
        signedness: Term,
        /// Precise width of the integer type in bits, allowing arbitrary value ranges.
        bit_width: Term,

        pub fn eql(self: *const IntegerType, other: *const IntegerType) bool {
            return self.signedness == other.signedness and self.bit_width == other.bit_width;
        }

        pub fn hash(self: *const IntegerType, hasher: *QuickHasher) void {
            hasher.update(self.signedness);
            hasher.update(self.bit_width);
        }

        pub fn cbr(self: *const IntegerType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("IntegerType");

            hasher.update("signedness:");
            hasher.update(self.signedness.getCbr());

            hasher.update("bit_width:");
            hasher.update(self.bit_width.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const IntegerType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.signedness.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.bit_width.getId()), .little);
        }
    };

    /// Type data for a floating point type repr.
    pub const FloatType = struct {
        /// Precise width of the floating point type in bits;
        /// unlike Integer, this should not allow arbitrary value ranges.
        bit_width: Term,

        pub fn eql(self: *const FloatType, other: *const FloatType) bool {
            return self.bit_width == other.bit_width;
        }

        pub fn hash(self: *const FloatType, hasher: *QuickHasher) void {
            hasher.update(self.bit_width);
        }

        pub fn cbr(self: *const FloatType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("FloatType");

            hasher.update(self.bit_width.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const FloatType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.bit_width.getId()), .little);
        }
    };

    /// Type data for an array type repr.
    pub const ArrayType = struct {
        /// Number of elements in the array type.
        len: Term,
        /// Optional constant value transparently attached to the end of the array,
        /// allowing easy creation of sentinel buffers.
        /// (ie, in zig syntax: [*:0]u8 for null-terminated string)
        sentinel_value: Term,
        /// Value type at each element slot in the array type.
        payload: Term,

        pub fn eql(self: *const ArrayType, other: *const ArrayType) bool {
            return self.len == other.len and self.sentinel_value == other.sentinel_value and self.payload == other.payload;
        }

        pub fn hash(self: *const ArrayType, hasher: *QuickHasher) void {
            hasher.update(self.len);
            hasher.update(self.sentinel_value);
            hasher.update(self.payload);
        }

        pub fn cbr(self: *const ArrayType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("ArrayType");

            hasher.update("len:");
            hasher.update(self.len.getCbr());

            hasher.update("sentinel_value:");
            hasher.update(self.sentinel_value.getCbr());

            hasher.update("payload:");
            hasher.update(self.payload.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const ArrayType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.len.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.sentinel_value.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.payload.getId()), .little);
        }
    };

    /// Type data for a pointer type repr.
    pub const PointerType = struct {
        /// Alignment override for addresses of this type.
        /// `nil` indicates natural alignment of `payload`.
        alignment: Term,
        /// Symbolic tag indicating the allocator this pointer belongs to.
        address_space: Term,
        /// Value type at the destination address of pointers with this type.
        payload: Term,
        // TODO: support bit offset ala zig extended alignment? e.g. `align(10:4:10)`

        pub fn eql(self: *const PointerType, other: *const PointerType) bool {
            return self.alignment == other.alignment and self.address_space == other.address_space and self.payload == other.payload;
        }

        pub fn hash(self: *const PointerType, hasher: *QuickHasher) void {
            hasher.update(self.alignment);
            hasher.update(self.address_space);
            hasher.update(self.payload);
        }

        pub fn cbr(self: *const PointerType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("PointerType");

            hasher.update("alignment:");
            hasher.update(self.alignment.getCbr());

            hasher.update("address_space:");
            hasher.update(self.address_space.getCbr());

            hasher.update("payload:");
            hasher.update(self.payload.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const PointerType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.alignment.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.address_space.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.payload.getId()), .little);
        }
    };

    /// Type data for a pointer-to-many type repr.
    pub const BufferType = struct {
        /// Alignment override for addresses of this type.
        /// `nil` indicates natural alignment of `payload`.
        alignment: Term,
        /// Symbolic tag indicating the allocator this pointer belongs to.
        address_space: Term,
        /// Optional constant value transparently attached to the end of the buffer,
        /// (ie, in zig syntax: [*:0]u8 for null-terminated string)
        sentinel_value: Term,
        /// Value type at the destination address of pointers with this type.
        payload: Term,

        pub fn eql(self: *const BufferType, other: *const BufferType) bool {
            return self.alignment == other.alignment and self.address_space == other.address_space and self.sentinel_value == other.sentinel_value and self.payload == other.payload;
        }

        pub fn hash(self: *const BufferType, hasher: *QuickHasher) void {
            hasher.update(self.alignment);
            hasher.update(self.address_space);
            hasher.update(self.sentinel_value);
            hasher.update(self.payload);
        }

        pub fn cbr(self: *const BufferType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("BufferType");

            hasher.update("alignment:");
            hasher.update(self.alignment.getCbr());

            hasher.update("address_space:");
            hasher.update(self.address_space.getCbr());

            hasher.update("sentinel_value:");
            hasher.update(self.sentinel_value.getCbr());

            hasher.update("payload:");
            hasher.update(self.payload.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const BufferType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.alignment.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.address_space.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.sentinel_value.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.payload.getId()), .little);
        }
    };

    /// Type data for a wide-pointer-to-many type repr.
    pub const SliceType = struct {
        /// Alignment override for addresses of this type.
        /// `nil` indicates natural alignment of `payload`.
        alignment: Term,
        /// Symbolic tag indicating the allocator this pointer belongs to.
        address_space: Term,
        /// Optional constant value transparently attached to the end of the slice,
        /// (ie, in zig syntax: [:0]u8 for slice of null-terminated string buffer)
        sentinel_value: Term,
        /// Value type at the destination address of pointers with this type.
        payload: Term,

        pub fn eql(self: *const SliceType, other: *const SliceType) bool {
            return self.alignment == other.alignment and self.address_space == other.address_space and self.sentinel_value == other.sentinel_value and self.payload == other.payload;
        }

        pub fn hash(self: *const SliceType, hasher: *QuickHasher) void {
            hasher.update(self.alignment);
            hasher.update(self.address_space);
            hasher.update(self.sentinel_value);
            hasher.update(self.payload);
        }

        pub fn cbr(self: *const SliceType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("SliceType");

            hasher.update("alignment:");
            hasher.update(self.alignment.getCbr());

            hasher.update("address_space:");
            hasher.update(self.address_space.getCbr());

            hasher.update("sentinel_value:");
            hasher.update(self.sentinel_value.getCbr());

            hasher.update("payload:");
            hasher.update(self.payload.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const SliceType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.alignment.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.address_space.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.sentinel_value.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.payload.getId()), .little);
        }
    };

    /// Used for abstract data description.
    pub const RowElementType = struct {
        label: Term,
        payload: Term,

        pub fn eql(self: *const RowElementType, other: *const RowElementType) bool {
            return self.label == other.label and self.payload == other.payload;
        }

        pub fn hash(self: *const RowElementType, hasher: *QuickHasher) void {
            hasher.update(self.label);
            hasher.update(self.payload);
        }

        pub fn cbr(self: *const RowElementType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("RowElementType");

            hasher.update("label:");
            hasher.update(self.label.getCbr());

            hasher.update("payload:");
            hasher.update(self.payload.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const RowElementType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.label.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.payload.getId()), .little);
        }
    };

    /// Used for abstract data description.
    pub const LabelType = union(enum) {
        name: Term,
        index: Term,
        exact: struct {
            name: Term,
            index: Term,
        },

        pub fn eql(self: *const LabelType, other: *const LabelType) bool {
            if (@as(std.meta.Tag(LabelType), self.*) != other.*) return false;
            return switch (self.*) {
                .name => |n| n == other.name,
                .index => |i| i == other.index,
                .exact => |e| e.name == other.exact.name and e.index == other.exact.index,
            };
        }

        pub fn hash(self: *const LabelType, hasher: *QuickHasher) void {
            hasher.update(@as(std.meta.Tag(LabelType), self.*));
            switch (self.*) {
                .name => |n| {
                    hasher.update(n);
                },
                .index => |i| {
                    hasher.update(i);
                },
                .exact => |e| {
                    hasher.update(e.name);
                    hasher.update(e.index);
                },
            }
        }

        pub fn cbr(self: *const LabelType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("LabelType");

            switch (self.*) {
                .name => |n| {
                    hasher.update("name:");
                    hasher.update(n.getCbr());
                },
                .index => |i| {
                    hasher.update("index:");
                    hasher.update(i.getCbr());
                },
                .exact => |e| {
                    hasher.update("exact.name:");
                    hasher.update(e.name.getCbr());

                    hasher.update("exact.index:");
                    hasher.update(e.index.getCbr());
                },
            }

            return hasher.final();
        }

        pub fn writeSma(self: *const LabelType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            switch (self.*) {
                .name => |n| {
                    try writer.writeInt(u8, 0, .little);
                    try writer.writeInt(u32, @intFromEnum(n.getId()), .little);
                },
                .index => |i| {
                    try writer.writeInt(u8, 1, .little);
                    try writer.writeInt(u32, @intFromEnum(i.getId()), .little);
                },
                .exact => |e| {
                    try writer.writeInt(u8, 2, .little);
                    try writer.writeInt(u32, @intFromEnum(e.name.getId()), .little);
                    try writer.writeInt(u32, @intFromEnum(e.index.getId()), .little);
                },
            }
        }
    };

    /// Used for compile time constants as types, such as integer values.
    pub const LiftedDataType = struct {
        /// The type of the data before it was lifted to a type value.
        unlifted_type: Term,
        /// The actual value of the data.
        value: *Block,

        pub fn eql(self: *const LiftedDataType, other: *const LiftedDataType) bool {
            return self.unlifted_type == other.unlifted_type and self.value == other.value;
        }

        pub fn hash(self: *const LiftedDataType, hasher: *QuickHasher) void {
            hasher.update(self.unlifted_type);
            hasher.update(&self.value);
        }

        pub fn cbr(self: *const LiftedDataType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("LiftedDataType");

            hasher.update("unlifted_type:");
            hasher.update(self.unlifted_type.getCbr());

            hasher.update("value:");
            hasher.update(self.value.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const LiftedDataType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.unlifted_type.getId()), .little);
            try writer.writeInt(u128, @intFromEnum(self.value.module.guid), .little);
            try writer.writeInt(u32, @intFromEnum(self.value.id), .little);
        }
    };

    /// Type data for a structure type repr.
    pub const StructureType = struct {
        /// Nominative identity of this structure type.
        name: Name,
        /// Layout heuristic determining how fields are to be arranged in memory.
        layout: Term,
        /// Optional integer representation of the structure type.
        /// For example, when specifying bit_packed, it helps to prevent errors if one specifies the precise integer size.
        backing_integer: Term,
        /// Descriptions of each field of this structure type.
        elements: []const Field = &.{},

        /// Descriptor for structural fields.
        pub const Field = struct {
            /// Nominative identity of this field.
            name: Name,
            /// The type of data stored in this field.
            payload: Term,
            /// An optional custom alignment for this field, overriding the natural alignment of `payload`;
            /// used by `Heuristic.optimal`; not allowed by others.
            alignment_override: Term,
        };

        pub fn eql(self: *const StructureType, other: *const StructureType) bool {
            if (self.name.value.ptr != other.name.value.ptr or self.layout != other.layout or self.backing_integer != other.backing_integer or self.elements.len != other.elements.len) return false;

            for (0..self.elements.len) |i| {
                const a = self.elements[i];
                const b = other.elements[i];
                if (a.name.value.ptr != b.name.value.ptr or a.payload != b.payload or a.alignment_override != b.alignment_override) return false;
            }

            return true;
        }

        pub fn hash(self: *const StructureType, hasher: *QuickHasher) void {
            hasher.update(self.name);
            hasher.update(self.layout);
            hasher.update(self.backing_integer);
            hasher.update(self.elements.len);
            for (self.elements) |elem| {
                hasher.update(elem.name.value);
                hasher.update(elem.payload);
                hasher.update(elem.alignment_override);
            }
        }

        pub fn cbr(self: *const StructureType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("StructureType");

            hasher.update("name:");
            hasher.update(self.name.value);

            hasher.update("layout:");
            hasher.update(self.layout.getCbr());

            hasher.update("backing_integer:");
            hasher.update(self.backing_integer.getCbr());

            hasher.update("elements.len:");
            hasher.update(self.elements.len);

            hasher.update("elements:");
            for (self.elements) |elem| {
                hasher.update("elem.name:");
                hasher.update(elem.name.value);

                hasher.update("elem.payload:");
                hasher.update(elem.payload.getCbr());

                hasher.update("elem.alignment_override:");
                hasher.update(elem.alignment_override.getCbr());
            }

            return hasher.final();
        }

        pub fn writeSma(self: *const StructureType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            const name_id = context.interned_name_set.get(self.name.value).?;
            try writer.writeInt(u32, @intFromEnum(name_id), .little);
            try writer.writeInt(u32, @intFromEnum(self.layout.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.backing_integer.getId()), .little);
            try writer.writeInt(u32, @intCast(self.elements.len), .little);
            for (self.elements) |field| {
                const field_name_id = context.interned_name_set.get(field.name.value).?;
                try writer.writeInt(u32, @intFromEnum(field_name_id), .little);
                try writer.writeInt(u32, @intFromEnum(field.payload.getId()), .little);
                try writer.writeInt(u32, @intFromEnum(field.alignment_override.getId()), .little);
            }
        }
    };

    /// Type data for a tagged sum type repr.
    pub const UnionType = struct {
        /// Nominative identity for this undiscriminated union type.
        name: Name,
        /// Heuristic determining the variant tagging and data layout strategy.
        layout: Term,
        /// Descriptions of each descriminant and variant of this union type.
        elements: []const Field = &.{},

        /// Descriptor for union fields.
        pub const Field = struct {
            /// Nominative identity for this variant.
            name: Name,
            /// Optional type of data stored in this variant;
            /// nil indicates discriminant-only variation.
            payload: Term,
        };

        pub fn eql(self: *const UnionType, other: *const UnionType) bool {
            if (self.name.value.ptr != other.name.value.ptr or self.layout != other.layout or self.elements.len != other.elements.len) return false;

            for (0..self.elements.len) |i| {
                const a = self.elements[i];
                const b = other.elements[i];
                if (a.name.value.ptr != b.name.value.ptr or a.payload != b.payload) return false;
            }

            return true;
        }

        pub fn hash(self: *const UnionType, hasher: *QuickHasher) void {
            hasher.update(self.name);
            hasher.update(self.layout);
            hasher.update(self.elements.len);
            for (self.elements) |elem| {
                hasher.update(elem.name.value.ptr);
                hasher.update(elem.payload);
            }
        }

        pub fn cbr(self: *const UnionType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("UnionType");

            hasher.update("name:");
            hasher.update(self.name.value);

            hasher.update("layout:");
            hasher.update(self.layout.getCbr());

            hasher.update("elements.len:");
            hasher.update(self.elements.len);

            hasher.update("elements:");
            for (self.elements) |elem| {
                hasher.update("elem.name:");
                hasher.update(elem.name.value);

                hasher.update("elem.payload:");
                hasher.update(elem.payload.getCbr());
            }

            return hasher.final();
        }

        pub fn writeSma(self: *const UnionType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            const name_id = context.interned_name_set.get(self.name.value).?;
            try writer.writeInt(u32, @intFromEnum(name_id), .little);
            try writer.writeInt(u32, @intFromEnum(self.layout.getId()), .little);
            try writer.writeInt(u32, @intCast(self.elements.len), .little);
            for (self.elements) |field| {
                const field_name_id = context.interned_name_set.get(field.name.value).?;
                try writer.writeInt(u32, @intFromEnum(field_name_id), .little);
                try writer.writeInt(u32, @intFromEnum(field.payload.getId()), .little);
            }
        }
    };

    /// Type data for a tagged sum type repr.
    pub const SumType = struct {
        /// Nominative identity for this discriminated union type.
        name: Name,
        /// Type for the discriminant tag in this union.
        tag_type: Term,
        /// Heuristic determining the variant tagging and data layout strategy.
        layout: Term,
        /// Descriptions of each descriminant and variant of this union type.
        elements: []const Field = &.{},

        /// Descriptor for union fields.
        pub const Field = struct {
            /// Nominative identity for this variant.
            name: Name,
            /// Optional type of data stored in this variant;
            /// nil indicates discriminant-only variation.
            payload: Term,
            /// Constant value of this variant's discriminant.
            tag: Term,
        };

        pub fn eql(self: *const SumType, other: *const SumType) bool {
            if (self.name.value.ptr != other.name.value.ptr or self.tag_type != other.tag_type or self.layout != other.layout or self.elements.len != other.elements.len) return false;

            for (0..self.elements.len) |i| {
                const a = self.elements[i];
                const b = other.elements[i];
                if (a.name.value.ptr != b.name.value.ptr or a.payload != b.payload or a.tag != b.tag) return false;
            }

            return true;
        }

        pub fn hash(self: *const SumType, hasher: *QuickHasher) void {
            hasher.update(self.name);
            hasher.update(self.tag_type);
            hasher.update(self.layout);
            hasher.update(self.elements.len);
            for (self.elements) |elem| {
                hasher.update(elem.name);
                hasher.update(elem.payload);
                hasher.update(elem.tag);
            }
        }

        pub fn cbr(self: *const SumType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("SumType");

            hasher.update("name:");
            hasher.update(self.name.value);

            hasher.update("tag_type:");
            hasher.update(self.tag_type.getCbr());

            hasher.update("layout:");
            hasher.update(self.layout.getCbr());

            hasher.update("elements.len:");
            hasher.update(self.elements.len);

            hasher.update("elements:");
            for (self.elements) |elem| {
                hasher.update("elem.name:");
                hasher.update(elem.name.value);

                hasher.update("elem.payload:");
                hasher.update(elem.payload.getCbr());

                hasher.update("elem.tag:");
                hasher.update(elem.tag.getCbr());
            }

            return hasher.final();
        }

        pub fn writeSma(self: *const SumType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            const name_id = context.interned_name_set.get(self.name.value).?;
            try writer.writeInt(u32, @intFromEnum(name_id), .little);
            try writer.writeInt(u32, @intFromEnum(self.tag_type.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.layout.getId()), .little);
            try writer.writeInt(u32, @intCast(self.elements.len), .little);
            for (self.elements) |field| {
                const field_name_id = context.interned_name_set.get(field.name.value).?;
                try writer.writeInt(u32, @intFromEnum(field_name_id), .little);
                try writer.writeInt(u32, @intFromEnum(field.payload.getId()), .little);
                try writer.writeInt(u32, @intFromEnum(field.tag.getId()), .little);
            }
        }
    };

    /// Type data for a function type repr.
    pub const FunctionType = struct {
        /// Parameter type for this function signature. Multiple input values are represented by Product.
        input: Term,
        /// Result type for this function.
        output: Term,
        /// Side effect type incurred when calling this function. Multiple effects are represented by Product.
        effects: Term,

        pub fn eql(self: *const FunctionType, other: *const FunctionType) bool {
            return self.input == other.input and self.output == other.output and self.effects == other.effects;
        }

        pub fn hash(self: *const FunctionType, hasher: *QuickHasher) void {
            hasher.update(self.input);
            hasher.update(self.output);
            hasher.update(self.effects);
        }

        pub fn cbr(self: *const FunctionType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("FunctionType");

            hasher.update("input:");
            hasher.update(self.input.getCbr());

            hasher.update("output:");
            hasher.update(self.output.getCbr());

            hasher.update("effects:");
            hasher.update(self.effects.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const FunctionType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.input.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.output.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.effects.getId()), .little);
        }
    };

    /// Type data for an effect handler repr.
    pub const HandlerType = struct {
        /// Parameter type for this handler signature. Multiple input values are represented by Product.
        input: Term,
        /// Result type for this handler.
        output: Term,
        /// Effect that is (at least temporarily) eliminated by this handler.
        handled_effect: Term,
        /// Side effects that are incurred in the process of handling this handler's effect. May include `handled_effect` for modulating handlers.
        added_effects: Term,

        pub fn eql(self: *const HandlerType, other: *const HandlerType) bool {
            return self.input == other.input and self.output == other.output and self.handled_effect == other.handled_effect and self.added_effects == other.added_effects;
        }

        pub fn hash(self: *const HandlerType, hasher: *QuickHasher) void {
            hasher.update(self.input);
            hasher.update(self.output);
            hasher.update(self.handled_effect);
            hasher.update(self.added_effects);
        }

        pub fn cbr(self: *const HandlerType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("HandlerType");

            hasher.update("input:");
            hasher.update(self.input.getCbr());

            hasher.update("output:");
            hasher.update(self.output.getCbr());

            hasher.update("handled_effect:");
            hasher.update(self.handled_effect.getCbr());

            hasher.update("added_effects:");
            hasher.update(self.added_effects.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const HandlerType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.input.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.output.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.handled_effect.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.added_effects.getId()), .little);
        }
    };

    /// Type data for a polymorphic type repr, with quantifiers and/or qualifiers.
    pub const PolymorphicType = struct {
        /// Type variable declarations for this polymorphic type.
        quantifiers: []const Term = &.{},
        /// Type constraints declarations for this polymorphic type.
        qualifiers: Term,
        /// The type to be instantiated by this polymorphic repr.
        payload: Term,

        pub fn eql(self: *const PolymorphicType, other: *const PolymorphicType) bool {
            if (self.quantifiers.len != other.quantifiers.len or self.qualifiers != other.qualifiers or self.payload != other.payload) return false;

            for (0..self.quantifiers.len) |i| {
                if (self.quantifiers[i] != other.quantifiers[i]) return false;
            }

            return true;
        }

        pub fn hash(self: *const PolymorphicType, hasher: *QuickHasher) void {
            hasher.update(self.quantifiers.len);
            for (self.quantifiers) |quant| {
                hasher.update(quant);
            }
            hasher.update(self.qualifiers);
            hasher.update(self.payload);
        }

        pub fn cbr(self: *const PolymorphicType) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("PolymorphicType");

            hasher.update("quantifiers_count:");
            hasher.update(self.quantifiers.len);

            hasher.update("quantifiers:");
            for (self.quantifiers) |quant| {
                hasher.update("quantifier:");
                hasher.update(quant.getCbr());
            }

            hasher.update("qualifiers:");
            hasher.update(self.qualifiers.getCbr());

            hasher.update("payload:");
            hasher.update(self.payload.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const PolymorphicType, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intCast(self.quantifiers.len), .little);
            for (self.quantifiers) |quant| {
                try writer.writeInt(u32, @intFromEnum(quant.getId()), .little);
            }
            try writer.writeInt(u32, @intFromEnum(self.qualifiers.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.payload.getId()), .little);
        }
    };

    /// Constraint checking that `subtype_row` is a subset of `primary_row`.
    pub const IsSubRowConstraint = struct {
        /// The larger product type.
        primary_row: Term,
        /// The smaller product type that must be a subset of `primary_row`.
        subtype_row: Term,

        pub fn eql(self: *const IsSubRowConstraint, other: *const IsSubRowConstraint) bool {
            return self.primary_row == other.primary_row and self.subtype_row == other.subtype_row;
        }

        pub fn hash(self: *const IsSubRowConstraint, hasher: *QuickHasher) void {
            hasher.update(self.primary_row);
            hasher.update(self.subtype_row);
        }

        pub fn cbr(self: *const IsSubRowConstraint) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("IsSubRowConstraint");

            hasher.update("primary_row:");
            hasher.update(self.primary_row.getCbr());

            hasher.update("subtype_row:");
            hasher.update(self.subtype_row.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const IsSubRowConstraint, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.primary_row.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.subtype_row.getId()), .little);
        }
    };

    /// Constraint checking that `row_result` is the disjoint union of `row_a` and `row_b`.
    pub const RowsConcatenateConstraint = struct {
        /// The LHS input to the concatenation.
        row_a: Term,
        /// The RHS input to the concatenation.
        row_b: Term,
        /// The product type that must match the disjoint union of `row_a` and `row_b`.
        row_result: Term,

        pub fn eql(self: *const RowsConcatenateConstraint, other: *const RowsConcatenateConstraint) bool {
            return self.row_a == other.row_a and self.row_b == other.row_b and self.row_result == other.row_result;
        }

        pub fn hash(self: *const RowsConcatenateConstraint, hasher: *QuickHasher) void {
            hasher.update(self.row_a);
            hasher.update(self.row_b);
            hasher.update(self.row_result);
        }

        pub fn cbr(self: *const RowsConcatenateConstraint) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("RowsConcatenateConstraint");

            hasher.update("row_a:");
            hasher.update(self.row_a.getCbr());

            hasher.update("row_b:");
            hasher.update(self.row_b.getCbr());

            hasher.update("row_result:");
            hasher.update(self.row_result.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const RowsConcatenateConstraint, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.row_a.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.row_b.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.row_result.getId()), .little);
        }
    };

    /// Constraint checking that the `data` type implements the `class` typeclass.
    pub const ImplementsClassConstraint = struct {
        /// The type that must implement the `class` typeclass.
        data: Term,
        /// The typeclass that must be implemented by `data`.
        class: Term,

        pub fn eql(self: *const ImplementsClassConstraint, other: *const ImplementsClassConstraint) bool {
            return self.data == other.data and self.class == other.class;
        }

        pub fn hash(self: *const ImplementsClassConstraint, hasher: *QuickHasher) void {
            hasher.update(self.data);
            hasher.update(self.class);
        }

        pub fn cbr(self: *const ImplementsClassConstraint) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("ImplementsClassConstraint");

            hasher.update("data:");
            hasher.update(self.data.getCbr());

            hasher.update("class:");
            hasher.update(self.class.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const ImplementsClassConstraint, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.data.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.class.getId()), .little);
        }
    };

    /// Constraint checking that the `data` type is a nominative identity for a structure over the `row` type.
    pub const IsStructureConstraint = struct {
        /// The nominative structural type that must contain `row`.
        data: Term,
        /// The structural description type that must match the layout of `data`.
        row: Term,

        pub fn eql(self: *const IsStructureConstraint, other: *const IsStructureConstraint) bool {
            return self.data == other.data and self.row == other.row;
        }

        pub fn hash(self: *const IsStructureConstraint, hasher: *QuickHasher) void {
            hasher.update(self.data);
            hasher.update(self.row);
        }

        pub fn cbr(self: *const IsStructureConstraint) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("IsStructureConstraint");

            hasher.update("data:");
            hasher.update(self.data.getCbr());

            hasher.update("row:");
            hasher.update(self.row.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const IsStructureConstraint, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.data.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.row.getId()), .little);
        }
    };

    /// Constraint checking that the `data` type is a nominative identity for a union over the `row` type.
    pub const IsUnionConstraint = struct {
        /// The nominative structural type that must contain `row`.
        data: Term,
        /// The structural description type that must match the layout of `data`.
        row: Term,

        pub fn eql(self: *const IsUnionConstraint, other: *const IsUnionConstraint) bool {
            return self.data == other.data and self.row == other.row;
        }

        pub fn hash(self: *const IsUnionConstraint, hasher: *QuickHasher) void {
            hasher.update(self.data);
            hasher.update(self.row);
        }

        pub fn cbr(self: *const IsUnionConstraint) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("IsUnionConstraint");

            hasher.update("data:");
            hasher.update(self.data.getCbr());

            hasher.update("row:");
            hasher.update(self.row.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const IsUnionConstraint, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.data.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.row.getId()), .little);
        }
    };

    /// Constraint checking that the `data` type is a nominative identity for a sum over the `row` type.
    pub const IsSumConstraint = struct {
        /// The nominative structural type that must contain `row`.
        data: Term,
        /// The structural description type that must match the layout of `data`.
        row: Term,

        pub fn eql(self: *const IsSumConstraint, other: *const IsSumConstraint) bool {
            return self.data == other.data and self.row == other.row;
        }

        pub fn hash(self: *const IsSumConstraint, hasher: *QuickHasher) void {
            hasher.update(self.data);
            hasher.update(self.row);
        }

        pub fn cbr(self: *const IsSumConstraint) Cbr {
            var hasher = CbrHasher.init();
            hasher.update("IsSumConstraint");

            hasher.update("data:");
            hasher.update(self.data.getCbr());

            hasher.update("row:");
            hasher.update(self.row.getCbr());

            return hasher.final();
        }

        pub fn writeSma(self: *const IsSumConstraint, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = context;
            try writer.writeInt(u32, @intFromEnum(self.data.getId()), .little);
            try writer.writeInt(u32, @intFromEnum(self.row.getId()), .little);
        }
    };
};

/// A constructor for term types that have no internal data,
/// and are uniquely identified by a compile-time name.
pub fn IdentityTerm(comptime name: []const u8) type {
    return struct {
        const Self = @This();

        pub fn eql(_: *const Self, _: *const Self) bool {
            return true;
        }

        pub fn hash(_: *const Self, hasher: *QuickHasher) void {
            hasher.update(name);
        }

        pub fn cbr(_: *const Self) Cbr {
            var hasher = CbrHasher.init();
            hasher.update(name);
            return hasher.final();
        }

        pub fn writeSma(self: *const Self, context: *const Context, writer: *std.io.Writer) error{WriteFailed}!void {
            _ = self;
            _ = context;
            _ = writer;
            // Identity terms have no data to write.
        }
    };
}
