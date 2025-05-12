const driver = @This();

const std = @import("std");

const ribbon = @import("ribbon_language");
const pl = @import("platform");

const log = std.log.scoped(.main);

pub const std_options = std.Options{
    .log_level = .warn,
};

pub fn main() !void {
    log.warn("todo: REPL", .{});
}

