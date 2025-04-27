const driver = @This();

const std = @import("std");

const ribbon = @import("ribbon_language");
const common = @import("common");

const log = std.log.scoped(.main);

pub const std_options = std.Options{
    .log_level = .info,
};


pub fn main() !void {
    log.err("driver nyi", .{});
}
