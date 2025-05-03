const driver = @This();

const std = @import("std");

const ribbon = @import("ribbon_language");

const log = std.log.scoped(.main);

pub const std_options = std.Options{
    .log_level = .debug,
};

const test_str =
    \\foo
    \\   "
    \\   2
    \\   3
    \\   "
    \\   bar
    \\     4
    \\     5
    \\   baz
    \\     6
    \\     7
    ;

pub fn main() !void {
    var syn = try ribbon.meta_language.getCst(std.heap.page_allocator, .{}, test_str) orelse {
        log.err("Failed to parse source", .{});
        return error.BadEncoding;
    };
    defer syn.deinit(std.heap.page_allocator);

    const string_lit = syn.operands.asSlice()[1].operands.asSlice()[0].operands.asSlice()[0];

    std.debug.print("String literal: {}\n", .{string_lit});
    std.debug.assert(string_lit.type == ribbon.meta_language.cst_types.String);


    const str = try ribbon.meta_language.assembleString(std.heap.page_allocator, test_str, string_lit);

    std.debug.print("String:\n`{s}`\n", .{str});
}
