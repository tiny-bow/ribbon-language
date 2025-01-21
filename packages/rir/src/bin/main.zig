const std = @import("std");

const Rir = @import("Rir");

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
                        .type = S32.id,
                    },
                    Rir.type_info.StructField {
                        .name = try ir.internName("y"),
                        .type = S32.id,
                    },
                },
            }
        });

        const FOO = try module.createGlobal(try ir.internName("FOO"), Foo.id, &.{
            0x01, 0x01, 0x00, 0x00, // x
            0x01, 0x00, 0x00, 0x00, // y
        });

        _ = FOO;
    }

    { // incr
        const one = try module.createGlobalFromNative(try ir.internName("one"), @as(i32, 1));

        const Incr = try ir.createTypeFromNative(fn (i32) i32, null, &.{"n"});
        const incr = try module.createFunction(try ir.internName("incr"), Incr.id);

        const arg = try incr.getArgument(0);

        const entry = incr.getEntryBlock();
        try entry.ref_local(arg.id);
        try entry.ref_global(one.id);
        try entry.add();
        try entry.ret();
    }

    { // fib
        const Fib = try ir.createTypeFromNative(fn (i32) i32, null, &.{"n"});
        const fib = try module.createFunction(try ir.internName("fib"), Fib.id);

        const arg = try fib.getArgument(0);

        const entry = fib.getEntryBlock();
        const thenBlock = try fib.createBlock(entry, "then");
        const elseBlock = try fib.createBlock(entry, "else");

        try entry.ref_local(arg.id);
        try entry.im(@as(i32, 2));
        try entry.lt();
        try entry.ref_block(thenBlock.id);
        try entry.ref_block(elseBlock.id);
        try entry.@"if"(.non_zero);

        try thenBlock.ref_local(arg.id);
        try thenBlock.ret();

        try elseBlock.ref_local(arg.id);
        try elseBlock.im(@as(i32, 1));
        try elseBlock.sub();
        try elseBlock.ref_function(fib.id);
        try elseBlock.call();

        try elseBlock.ref_local(arg.id);
        try elseBlock.im(@as(i32, 2));
        try elseBlock.sub();
        try elseBlock.ref_function(fib.id);
        try elseBlock.call();

        try elseBlock.add();
        try elseBlock.ret();
    }

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
}
