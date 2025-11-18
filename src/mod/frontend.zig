//! # The Frontend Service
// ... (module documentation remains the same) ...

const frontend = @This();

const std = @import("std");
const log = std.log.scoped(.frontend);

const common = @import("common");
const core = @import("core");
const ir = @import("ir");
const sma = @import("sma");
const analysis = @import("analysis");
const orchestration = @import("orchestration");
const meta_language = @import("meta_language");
const bytecode = @import("bytecode");

test {
    std.testing.refAllDecls(@This());
}

/// A helper struct to encapsulate the state and logic for analyzing a single module.
const FrontendPass = struct {
    session: *orchestration.CompilationSession,
    module_info: *const orchestration.ModuleInfo,

    common: struct {
        ml_value_type: ?ir.Ref = null,
    } = .{},

    /// High-level function to manage the import of a single dependency.
    /// It handles creating the necessary IR context and updating the session maps.
    fn importDependency(self: *FrontendPass, dependency_sma: *const sma.Artifact) !void {
        const allocator = self.session.gpa;
        const root_ctx = self.session.root_context;

        // 1. Create a new, dedicated context for the dependency module.
        const child_ctx = blk: {
            const root = root_ctx.asRoot().?;
            root.mutex.lock();
            defer root.mutex.unlock();
            break :blk try root.createContext();
        };

        // 2. Associate the new context ID with the module's GUID in the session.
        try self.session.context_id_to_module.put(allocator, child_ctx.id, dependency_sma.header.module_guid);

        // 3. Call the low-level rehydrator in the `sma` module to do the mechanical translation.
        try dependency_sma.rehydrateInto(self.session, child_ctx);

        // 4. TODO: Populate the session's `ref_to_external_symbol` map so that other modules
        //    can resolve symbols from this dependency. This will require iterating the
        //    SMA's public symbol table and the node_map created during rehydration.
    }

    /// The primary method that executes the frontend pass for the given module.
    pub fn run(self: *FrontendPass) !*sma.Artifact {
        const allocator = self.session.gpa;

        // --- Phase 2: Rehydrate Dependencies ---
        // TODO: The orchestrator will load dependency SMAs and pass them here.
        // for (dependency_smas) |dep_sma| {
        //     try pass.importDependency(dep_sma);
        // }

        // Create a new context for the module we are compiling.
        const module_ctx = blk: {
            const root = self.session.root_context.asRoot().?;
            root.mutex.lock();
            defer root.mutex.unlock();
            break :blk try root.createContext();
        };
        try self.session.context_id_to_module.put(allocator, module_ctx.id, self.module_info.guid);

        // --- Analyze Source and Generate IR ---
        // TODO: Read source file from `pass.module_info.path`.
        const source_code = "// stub source code";
        var ast = try meta_language.Expr.parseSource(allocator, .{}, self.module_info.path, source_code);
        if (ast) |*root_expr| {
            defer root_expr.deinit(allocator);

            // TODO: create an ir representation of `meta_language.Value` type
            // TODO: create functions to instantiate above ir type at various variants
            // TODO: need an ir builder to manage construction of compound expressions
            _ = try self.lowerExpr(module_ctx, root_expr);
        }

        // --- Dehydrate the generated IR into an SMA ---
        log.debug("Dehydrating IR for module {s}...", .{self.module_info.path});
        const artifact = try sma.Artifact.fromIr(module_ctx, self.module_info.guid, allocator);

        // --- Phase 4: Compute Interface Hash ---
        // TODO: Compute and set `artifact.header.interface_hash`.

        return artifact;
    }

    // CRITICAL NOTE: This function must be kept in sync with the `meta_language.Value` definition.
    pub fn mlValueType(
        self: *FrontendPass,
    ) !ir.Ref {
        log.debug("creating IR value type for meta_language.Value type...", .{});

        if (self.common.ml_value_type) |existing| {
            return existing;
        }

        // meta_language.Value is an efficient, bit-packed union of all value types in the meta-language semantics.
        // ```txt
        //                                                       ┍╾on target architectures,
        //                                                       │ this bit is 1 for quiet nans, 0 for signalling.
        //   ┍╾discriminant for objects (.val_bits.obj_bits)     │
        //   │                                                   │ ┍╾f64 exponent; if not f64, these are all 1s
        //   │          discriminant for non-f64 (.tag_bits)╼┑   │ │ (encoding f64 nan), forming the first discriminant of the value
        // ┌─┤                                               ├─┐ │ ├─────────┐
        // 000_000000000000000000000000000000000000000000000_000_0_00000000000_0─╼╾f64 sign
        //     ├───────────────────────────────────────────┘     ├─────────────┘
        //     ┕╾45 bit object pointer (.val_bits.ptr_bits)      ┕╾(.nan_bits)
        //       (8 byte aligned means 3 lsb are always 0)
        //
        // ```
        // * See https://en.wikipedia.org/wiki/Double-precision_floating-point_format for more information on the f64 bit layout.
        // * Note the diagram presented here is in little-endian, despite the convention of displaying IEEE-754 diagrams in big-endian.
        //   This choice was made because Zig uses least significant bits first when bitpacking, so this diagram better matches the structure definition.

        const packed_sym = try self.session.root_context.getBuiltin(.packed_symbol);
        const ObjBits = try self.session.root_context.builder.integer_type(.unsigned, @bitSizeOf(meta_language.Value.Obj));
        const TagBits = try self.session.root_context.builder.integer_type(.unsigned, @bitSizeOf(meta_language.Value.Tag));
        const NanBits = try self.session.root_context.builder.integer_type(.unsigned, @bitSizeOf(meta_language.Value.NanBits));
        const PtrBits = try self.session.root_context.builder.integer_type(.unsigned, @bitSizeOf(meta_language.Value.PtrBits));

        const Data = try self.session.root_context.builder.struct_type(
            packed_sym,
            &.{
                try self.session.root_context.internName("obj_bits"),
                try self.session.root_context.internName("ptr_bits"),
            },
            &.{
                ObjBits,
                PtrBits,
            },
        );

        const Value = try self.session.root_context.builder.struct_type(
            packed_sym,
            &.{
                try self.session.root_context.internName("val_bits"),
                try self.session.root_context.internName("tag_bits"),
                try self.session.root_context.internName("nan_bits"),
            },
            &.{
                Data,
                TagBits,
                NanBits,
            },
        );

        log.debug("meta_language.Value type now available at {f}", .{Value});

        self.common.ml_value_type = Value;

        return Value;
    }

    pub fn mlInteger(self: *FrontendPass, comptime T: type, value: T) !ir.Ref {
        return self.session.root_context.builder.constant_value(
            try self.mlValueType(),
            (if (comptime T == i48)
                meta_language.Value.fromI48(value)
            else if (comptime T == u48)
                meta_language.Value.fromU48(value)
            else
                @compileError("mlInteger only supports i48 and u48 types")).asBytes(),
        );
    }

    // === TODO: Traverse `root_expr` and populate `module_ctx` ===
    pub fn lowerExpr(
        self: *FrontendPass,
        ctx: *ir.Context,
        expr: *meta_language.Expr,
    ) !ir.Ref {
        switch (expr.data) {
            .int => {
                log.debug("lowering 𝓲𝓷𝓽 {d}", .{expr.data.int});

                if (expr.data.int >= 0) {
                    return self.mlInteger(u48, @intCast(expr.data.int));
                } else {
                    return self.mlInteger(i48, @intCast(expr.data.int));
                }
            },
            .char => {
                log.debug("lowering 𝓬𝓱𝓪𝓻 '{u}'", .{expr.data.char});

                return self.session.root_context.builder.constant_value(
                    try self.mlValueType(),
                    meta_language.Value.fromChar(expr.data.char).asBytes(),
                );
            },
            .string => {
                log.debug("lowering 𝓼𝓽𝓻𝓲𝓷𝓰 \"{s}\"", .{expr.data.string});

                // this case is more complicated than the above because we need to intern the string data,
                // and then construct a constant expression that forms a ml.Value pointing to that interned data.
                const bytes_type = try self.session.root_context.getBuiltin(.interned_bytes_type);
                const bytes_ptr_type = try self.session.root_context.builder.pointer_type(bytes_type);

                // TODO: this will currently create an invalid Value; we need alignment overrides for constants
                // (Value objects like string must be 8-byte aligned)
                const string_constant = try self.session.root_context.builder.constant_value(
                    bytes_type,
                    expr.data.string,
                );

                const base_value_constant = try self.session.root_context.builder.constant_value(
                    try self.mlValueType(),
                    meta_language.Value.fromObjectPointer(.string, null).asBytes(),
                );

                const contents = try ctx.addList(.mutable, .nil, &.{});
                const block = try ctx.addStructure(.mutable, .block, .{
                    .parent = ir.Ref.nil,
                    .locals = ir.Ref.nil,
                    .handlers = ir.Ref.nil,
                    .contents = contents,
                    .type = try self.mlValueType(),
                });

                try ctx.setElement(
                    contents,
                    0,
                    try ctx.addStructure(.mutable, .instruction, .{
                        .parent = block,
                        .operation = try ctx.internPrimitive(ir.Operation.get_element_addr),
                        .type = bytes_ptr_type,
                        .operands = try ctx.addList(.constant, .nil, &.{
                            string_constant,
                            try ctx.internPrimitive(@as(u64, 0)), // TODO: unclear whether this is correct from current documentation, but this is the same as LLVM iirc
                        }),
                    }),
                );

                try ctx.setElement(
                    contents,
                    1,
                    try ctx.addStructure(.mutable, .instruction, .{
                        .parent = block,
                        .operation = try ctx.internPrimitive(bytecode.Instruction.OpCode.bit_lshift64), // TODO: this sucks, need to integrate full instruction set into ir.Operation
                        .type = try self.mlValueType(),
                        .operands = try ctx.addList(.constant, .nil, &.{
                            try ctx.getElement(contents, 0) orelse @panic("Expected instruction at index 0"),
                            try self.mlInteger(u48, @bitOffsetOf(meta_language.Value.Data, "ptr_bits")),
                        }),
                    }),
                );

                try ctx.setElement(
                    contents,
                    2,
                    try ctx.addStructure(.mutable, .instruction, .{
                        .parent = block,
                        .operation = try ctx.internPrimitive(bytecode.Instruction.OpCode.bit_or64), // TODO: more suck, see above
                        .type = try self.mlValueType(),
                        .operands = try ctx.addList(.constant, .nil, &.{
                            base_value_constant,
                            try ctx.getElement(contents, 1) orelse @panic("Expected instruction at index 1"),
                        }),
                    }),
                );
            },
            .identifier => {
                log.debug("lowering 𝓲𝓭𝓮𝓷𝓽𝓲𝓯𝓲𝓮𝓻 {s}", .{expr.data.identifier});
                common.todo(noreturn, .{});
            },
            .symbol => {
                log.debug("lowering 𝓼𝔂𝓶𝓫𝓸𝓵 {s}", .{expr.data.symbol});
                common.todo(noreturn, .{});
            },
            .list => {
                log.debug("lowering 𝓵𝓲𝓼𝓽", .{});
                for (expr.data.list) |*child| {
                    common.todo(noreturn, .{ child, ctx });
                }
            },
            .tuple => {
                log.debug("lowering 𝓽𝓾𝓹𝓵𝓮", .{});
                for (expr.data.tuple) |*child| {
                    common.todo(noreturn, .{ child, ctx });
                }
            },
            .array => {
                log.debug("lowering 𝓪𝓻𝓻𝓪𝔂", .{});
                for (expr.data.array) |*child| {
                    common.todo(noreturn, .{ child, ctx });
                }
            },
            .compound => {
                log.debug("lowering 𝓬𝓸𝓶𝓹𝓸𝓾𝓷𝓭", .{});
                for (expr.data.compound) |child| {
                    common.todo(noreturn, .{ child, ctx });
                }
            },
            .seq => {
                log.debug("lowering 𝓼𝓮𝓺", .{});
                for (expr.data.seq) |*child| {
                    common.todo(noreturn, .{ child, ctx });
                }
            },
            .apply => {
                log.debug("lowering 𝓪𝓹𝓹𝓵𝔂", .{});
                for (expr.data.apply) |*child| {
                    common.todo(noreturn, .{ child, ctx });
                }
            },
            .operator => {
                log.debug("lowering 𝓸𝓹𝓮𝓻𝓪𝓽𝓸𝓻 {s}", .{expr.data.operator.token.data.sequence.asSlice()});
                for (expr.data.operator.operands) |*child| {
                    common.todo(noreturn, .{ child, ctx });
                }
            },
            .decl => {
                log.debug("lowering 𝓭𝓮𝓬𝓵", .{});
                for (expr.data.decl) |*child| {
                    common.todo(noreturn, .{ child, ctx });
                }
            },
            .set => {
                log.debug("lowering 𝓼𝓮𝓽", .{});
                for (expr.data.set) |*child| {
                    common.todo(noreturn, .{ child, ctx });
                }
            },
            .lambda => {
                log.debug("lowering 𝓵𝓪𝓶𝓫𝓭𝓪", .{});
                for (expr.data.lambda) |*child| {
                    common.todo(noreturn, .{ child, ctx });
                }
            },
        }

        unreachable;
    }
};

/// The main entry point for the frontend service.
pub fn generateSMA(
    session: *orchestration.CompilationSession,
    module_info: *const orchestration.ModuleInfo,
) !*sma.Artifact {
    var pass = FrontendPass{
        .session = session,
        .module_info = module_info,
    };
    return pass.run();
}
