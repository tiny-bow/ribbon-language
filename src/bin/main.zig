const driver = @This();

const std = @import("std");

const ribbon = @import("ribbon_language");

const log = std.log.scoped(.main);

pub const std_options = std.Options{
    .log_level = .debug,
};

const input =
    \\foo + 1 * 3 * 2 +
    \\  1 * 2
    \\
    ;
const expect = "(+ foo (+ (* 1 (* 3 2)) (do (* 1 2))))"
    ;

pub fn main() !void {
    var syn = try ribbon.meta_language.getCst(std.heap.page_allocator, .{}, input) orelse {
        log.err("Failed to parse source", .{});
        return error.BadEncoding;
    };
    defer syn.deinit(std.heap.page_allocator);

    log.info("Parsed source:", .{});
    try ribbon.meta_language.dumpCstSExprs(input, syn, std.io.getStdErr().writer());

    var buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer buf.deinit();

    const writer = buf.writer();

    try ribbon.meta_language.dumpCstSExprs(input, syn, writer);

    try std.testing.expectEqualStrings(expect, buf.items);
}
