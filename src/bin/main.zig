const driver = @This();

const std = @import("std");

const ribbon = @import("ribbon_language");

const log = std.log.scoped(.main);

pub const std_options = std.Options{
    .log_level = .debug,
};

const tests: []const struct {input: []const u8, expect: []const u8} = &.{
    .{ .input = "()", .expect = "()" },
    .{ .input = "a b", .expect = "⟨𝓪𝓹𝓹 a b⟩" },
    .{ .input = "a b c", .expect = "⟨𝓪𝓹𝓹 ⟨𝓪𝓹𝓹 a b⟩ c⟩" },
    .{ .input = "1 * a b", .expect = "⟨* 1 ⟨𝓪𝓹𝓹 a b⟩⟩" },
    .{ .input = "1 * (a b)", .expect = "⟨* 1 (⟨𝓪𝓹𝓹 a b⟩)⟩" },
    .{ .input = "1 + 2", .expect = "⟨+ 1 2⟩" },
    .{ .input = "1 * 2", .expect = "⟨* 1 2⟩" },
    .{ .input = "1 + 2 + 3", .expect = "⟨+ ⟨+ 1 2⟩ 3⟩" },
    .{ .input = "1 - 2 - 3", .expect = "⟨- ⟨- 1 2⟩ 3⟩" },
    .{ .input = "1 * 2 * 3", .expect = "⟨* ⟨* 1 2⟩ 3⟩" },
    .{ .input = "1 / 2 / 3", .expect = "⟨/ ⟨/ 1 2⟩ 3⟩" },
    .{ .input = "1 + 2 * 3", .expect = "⟨+ 1 ⟨* 2 3⟩⟩" },
    .{ .input = "x y\nz w", .expect = "⟨𝓼𝓮𝓺 ⟨𝓪𝓹𝓹 x y⟩ ⟨𝓪𝓹𝓹 z w⟩⟩" },
    .{ .input = "x y\nz w\n", .expect = "⟨𝓼𝓮𝓺 ⟨𝓪𝓹𝓹 x y⟩ ⟨𝓪𝓹𝓹 z w⟩⟩" },
    .{ .input = "a b\nc d\ne f\n", .expect = "⟨𝓼𝓮𝓺 ⟨𝓪𝓹𝓹 a b⟩ ⟨𝓼𝓮𝓺 ⟨𝓪𝓹𝓹 c d⟩ ⟨𝓪𝓹𝓹 e f⟩⟩⟩" },
    .{ .input = "1\n2\n3\n4\n", .expect = "⟨𝓼𝓮𝓺 1 ⟨𝓼𝓮𝓺 2 ⟨𝓼𝓮𝓺 3 4⟩⟩⟩" },
    .{ .input = "1 *\n  2 + 3\n", .expect = "⟨* 1 ⌊⟨+ 2 3⟩⌋⟩" },
    .{ .input = "1 *\n  2 + 3\n4", .expect = "⟨𝓼𝓮𝓺 ⟨* 1 ⌊⟨+ 2 3⟩⌋⟩ 4⟩" },
    .{ .input = "foo(1) * 3 * 2 +\n  1 * 2\nalert 'hello world' + 2\ntest 2 3\n", .expect = "⟨𝓼𝓮𝓺 ⟨+ ⟨* ⟨* ⟨𝓪𝓹𝓹 foo (1)⟩ 3⟩ 2⟩ ⌊⟨* 1 2⟩⌋⟩ ⟨𝓼𝓮𝓺 ⟨+ ⟨𝓪𝓹𝓹 alert 'hello world'⟩ 2⟩ ⟨𝓪𝓹𝓹 ⟨𝓪𝓹𝓹 test 2⟩ 3⟩⟩⟩" },
};

pub fn main() !void {
    var failures = std.ArrayList(usize).init(std.heap.page_allocator);
    defer failures.deinit();

    for (tests, 0..) |t, i| {
        log.info("test {}/{}", .{i, tests.len});
        const input = t.input;
        const expect = t.expect;

        tryTest(input, expect) catch |err| {
            log.err("input {s} failed: {}", .{input, err});
            failures.append(i) catch unreachable;
        };
    }

    if (failures.items.len > 0) {
        log.err("Failed {}/{} tests: {any}", .{failures.items.len, tests.len, failures.items});
        return error.TestFailed;
    } else {
        log.info("All tests passed", .{});
    }
}

fn tryTest(input: []const u8, expect: []const u8) !void {
    var syn = try ribbon.meta_language.getCst(std.heap.page_allocator, .{}, input) orelse {
        log.err("Failed to parse source", .{});
        return error.BadEncoding;
    };
    defer syn.deinit(std.heap.page_allocator);

    log.info("input: {s}\nresult: {}", .{
        input,
        std.fmt.Formatter(struct {
            pub fn formatter(
                data: struct { input: []const u8, syn: ribbon.analysis.SyntaxTree},
                comptime _: []const u8,
                _: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                return ribbon.meta_language.dumpCstSExprs(data.input, data.syn, writer);
            }
        }.formatter) { .data = .{ .input = input, .syn = syn } }
    });

    var buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer buf.deinit();

    const writer = buf.writer();

    try ribbon.meta_language.dumpCstSExprs(input, syn, writer);

    try std.testing.expectEqualStrings(expect, buf.items);
}
