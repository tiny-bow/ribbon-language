const std = @import("std");

const Rir = @import("Rir");

const Rbc = @import("Rbc");

const RbcGenerator = @import("RbcGenerator");

pub const std_options = std.Options {
    .log_level = .debug,
};

const log = std.log.scoped(.main);


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var ir = try Rir.init(allocator);
    defer ir.deinit();

    const module = try ir.createModule(try ir.internName("test-module"));

    const S32 = try ir.createTypeFromNative(i32, null, null);

    { // struct
        const Foo = try ir.createType(try ir.internName("Foo"), Rir.TypeInfo {
            .Struct = Rir.type_info.Struct {
                .fields = &.{
                    Rir.type_info.StructField {
                        .name = try ir.internName("x"),
                        .type = S32,
                    },
                    Rir.type_info.StructField {
                        .name = try ir.internName("y"),
                        .type = S32,
                    },
                },
            }
        });

        const FOO = try module.createGlobal(try ir.internName("FOO"), Foo);

        FOO.mutability = .mutable;
        FOO.initial_value = try ir.allocator.dupe(u8, &.{
            0x01, 0x01, 0x00, 0x00, // x
            0x01, 0x00, 0x00, 0x00, // y
        });
    }

    { // incr
        const one = try module.createGlobal(try ir.internName("one"), S32);
        try one.initializerFromNative(@as(i32, 1));

        const Incr = try ir.createTypeFromNative(fn (i32) i32, null, &.{try ir.internName("n")});
        const incr = try module.createFunction(try ir.internName("incr"), Incr);

        const arg = try incr.getArgument(0);

        const entry = incr.getEntryBlock();
        try entry.ref_local(arg);
        try entry.ref_global(one);
        try entry.add();
        try entry.ret();
    }

    const fib = fib: {
        const Fib = try ir.createTypeFromNative(fn (i32) i32, null, &.{try ir.internName("n")});
        const func = try module.createFunction(try ir.internName("fib"), Fib);

        const arg = try func.getArgument(0);

        const entry = func.getEntryBlock();
        const thenBlock = try func.createBlock(entry, try ir.internName("then"));
        const elseBlock = try func.createBlock(entry, try ir.internName("else"));

        try entry.ref_local(arg);
        try entry.im(@as(i32, 2));
        try entry.lt();
        try entry.ref_block(thenBlock);
        try entry.ref_block(elseBlock);
        try entry.@"if"(.non_zero);

        try thenBlock.ref_local(arg);
        try thenBlock.ret();

        try elseBlock.ref_local(arg);
        try elseBlock.im(@as(i32, 1));
        try elseBlock.sub();
        try elseBlock.ref_function(func);
        try elseBlock.call();

        try elseBlock.ref_local(arg);
        try elseBlock.im(@as(i32, 2));
        try elseBlock.sub();
        try elseBlock.ref_function(func);
        try elseBlock.call();

        try elseBlock.add();
        try elseBlock.ret();

        break :fib func;
    };

    { // formatting
        var text = std.ArrayList(u8).init(allocator);
        defer text.deinit();

        const writer = text.writer();

        var formatter = try Rir.Formatter.init(ir, writer.any());
        defer formatter.deinit();

        // formatter.setFlag(.show_ids, true);
        // formatter.setFlag(.show_indices, true);
        // formatter.setFlag(.show_op_code_bytes, true);
        // formatter.setFlag(.show_op_data_bytes, true);

        try formatter.writeAll("```rir\n");
        try formatter.fmt(ir);
        try formatter.writeAll("```\n");

        std.debug.print("{s}", .{text.items});
    }

    { // codegen
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var gen = try RbcGenerator.init(arena.allocator(), ir);

        const exports = [_]RbcGenerator.Export {
            .@"export"(fib),
        };

        const program = try gen.generate(allocator, &exports);
        defer program.deinit(allocator);

        std.debug.print("{}", .{program});
    }
}
