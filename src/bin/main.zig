const driver = @This();

const std = @import("std");

const ribbon = @import("ribbon_language");
const pl = @import("platform");

const log = std.log.scoped(.main);

const repl = @import("repl");

pub const std_options = std.Options{
    .log_level = .warn,
};

const Repl = repl.Builder(ReplContext);

const ReplContext = struct {
    pub const Error = anyerror;
};

pub fn main() !void {
    log.warn("todo: full CLI; repl-only mode enabled", .{});

    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var ctx = ReplContext{};

    var R = Repl.init(&ctx, allocator);
    defer R.deinit();

    while (try R.getInput(">")) |input| {
        if (std.mem.eql(u8, input, "exit")) break;

        std.debug.print("input: {s}\n", .{input});
    }
}
