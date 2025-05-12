const driver = @This();

const std = @import("std");

const ribbon = @import("ribbon_language");
const pl = @import("platform");

const log = std.log.scoped(.main);

const repl = @import("repl");

pub const std_options = std.Options{
    .log_level = .info,
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

    var line_count: u32 = 0;

    var line_accumulator = std.ArrayList(u8).init(allocator);
    defer line_accumulator.deinit();

    while (R.getInput(">") catch |err| {
        switch (err) {
            error.EndOfStream => {
                std.debug.print("[STREAM CLOSED] goodbye 💝\n", .{});
                return;
            },
            error.CtrlC => {
                std.debug.print("[CTRL + C] goodbye 💝\n", .{});
                return;
            },
            else => {
                log.err("cannot get input: {}", .{err});
                return err;
            },
        }
    }) |input| {
        if (std.mem.eql(u8, input, "exit")) {
            std.debug.print("[EXIT] goodbye 💝\n", .{});
            return;
        }

        line_count += 1;

        line_accumulator.appendSlice(input) catch @panic("OOM in line accumulator");

        var expr = ribbon.meta_language.getExpr(
            allocator,
            .{ .attrOffset = .{ .column = 0, .line = line_count } },
            "stdin",
            line_accumulator.items,
        ) catch |err| {
            if (err == error.UnexpectedEof) {
                std.debug.print("Incomplete input, waiting for more...\n", .{});
            } else {
                log.err("Error parsing input: {}", .{err});
                R.history.add(line_accumulator.items) catch @panic("OOM in history");

                line_accumulator.clearRetainingCapacity();
            }

            continue;
        } orelse continue;
        defer expr.deinit(allocator);

        R.history.add(line_accumulator.items) catch @panic("OOM in history");

        line_accumulator.clearRetainingCapacity();

        std.debug.print("{}\n", .{expr});
    }
}
