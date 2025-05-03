const driver = @This();

const std = @import("std");

const ribbon = @import("ribbon_language");

const log = std.log.scoped(.main);

pub const std_options = std.Options{
    .log_level = .debug,
};

const test_str =
    \\foo + 1 * 2
    ;

pub fn main() !void {
    var syn = try ribbon.meta_language.getCst(std.heap.page_allocator, .{}, test_str) orelse {
        log.err("Failed to parse source", .{});
        return error.BadEncoding;
    };
    defer syn.deinit(std.heap.page_allocator);
    log.info("Parsed source: {s}", .{syn});
}
