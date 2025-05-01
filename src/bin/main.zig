const driver = @This();

const std = @import("std");

const ribbon = @import("ribbon_language");

const log = std.log.scoped(.main);

pub const std_options = std.Options{
    .log_level = .debug,
};

pub fn main() !void {
    log.debug("parsed rml expr: {?}", .{
        ribbon.meta_language.getCst(
            std.heap.page_allocator, .{},
            \\foo
            \\   1
            \\   2
            \\   3
            \\   bar
            \\     4
            \\     5
            \\   baz
            \\     6
            \\     7
        ) catch |err| {
            log.debug("Error: {}", .{err});
            return err;
        }
    });
}
