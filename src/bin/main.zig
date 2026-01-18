const driver = @This();

const std = @import("std");

const ribbon = @import("ribbon_language");

const log = std.log.scoped(.main);

const repl = @import("repl");

pub const std_options = std.Options{
    .log_level = .debug,
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

    var line_accumulator = std.ArrayList(u8).empty;
    defer line_accumulator.deinit(allocator);

    var out_buf: [4096]u8 = undefined;

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

        line_accumulator.appendSlice(allocator, input) catch @panic("OOM in line accumulator");

        var diag = ribbon.analysis.Diagnostic.Context.init(allocator);
        defer diag.deinit();

        var expr = ribbon.meta_language.Expr.parseSource(
            allocator,
            &diag,
            .{ .attrOffset = .{ .column = 0, .line = line_count } },
            "stdin",
            line_accumulator.items,
        ) catch |err| {
            if (err == error.UnexpectedEof) {
                std.debug.print("Incomplete input, waiting for more...\n", .{});
            } else {
                log.debug("Error parsing input: {}", .{err});
                var stderr = std.debug.lockStderrWriter(&out_buf);
                defer std.debug.unlockStderrWriter();

                try diag.writeAll(stderr, .{});
                try stderr.flush();
                R.history.add(line_accumulator.items) catch @panic("OOM in history");

                line_accumulator.clearRetainingCapacity();
            }

            continue;
        } orelse continue;
        defer expr.deinit(allocator);

        R.history.add(line_accumulator.items) catch @panic("OOM in history");

        line_accumulator.clearRetainingCapacity();

        const stderr = std.fs.File.stderr();
        var writer = stderr.writer(&out_buf);
        try expr.dumpTree(&writer.interface, 0);
        try writer.interface.flush();

        std.debug.print("{f}\n", .{expr});
    }
}
