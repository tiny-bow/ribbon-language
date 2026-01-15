const std = @import("std");

const ribbon = @import("ribbon_language");
const PrettyPrinter = ribbon.common.PrettyPrinter;
const Doc = PrettyPrinter.Doc;

test "pretty: group vs fill" {
    var pp = PrettyPrinter.init(std.testing.allocator);
    defer pp.deinit();

    var buf_mem: [1024]u8 = undefined;

    const list = &[_]*const Doc{
        pp.text("foo,"),
        pp.text("bar,"),
        pp.text("baz,"),
        pp.text("qux,"),
    };

    {
        var writer = std.io.Writer.fixed(&buf_mem);
        const expected =
            \\[
            \\    foo,
            \\    bar,
            \\    baz,
            \\    qux,
            \\]
        ;

        // Case 1: Group (Consistent)
        // [foo, bar, baz, qux]
        // If it breaks, it breaks ALL of them.
        const doc_group = pp.concat(&.{
            pp.text("["),
            pp.hang(1, pp.join(pp.space(), list)),
            pp.line(),
            pp.text("]"),
        });

        // Render Group (Narrow)
        try pp.render(doc_group, &writer, .{ .max_width = 10 });

        try std.testing.expectEqualStrings(expected, writer.buffered());
    }

    {
        var writer = std.io.Writer.fixed(&buf_mem);

        const expected =
            \\foo, bar,
            \\baz, qux,
        ;

        // Render Fill (Narrow)
        try pp.render(pp.flow(list), &writer, .{ .max_width = 10 });

        try std.testing.expectEqualStrings(expected, writer.buffered());
    }

    const doc_nested = pp.breaker(pp.concat(&.{
        pp.text("Items: ["),
        pp.hang(1, pp.filler(pp.concat(&.{
            pp.breaker(pp.concat(&.{
                pp.text("["),
                pp.hang(1, pp.filler(pp.flow(&.{
                    pp.text("foo,"),
                    pp.text("bar,"),
                    pp.text("baz,"),
                    pp.text("qux,"),
                    pp.text("foo,"),
                    pp.text("bar,"),
                    pp.text("baz,"),
                    pp.text("qux,"),
                    pp.text("foo,"),
                    pp.text("bar,"),
                    pp.text("baz,"),
                    pp.text("qux,"),
                }))),
                pp.space(),
                pp.text("],"),
            })),
            pp.space(),
            pp.breaker(pp.concat(&.{
                pp.text("["),
                pp.hang(1, pp.filler(pp.flow(list))),
                pp.space(),
                pp.text("],"),
            })),
        }))),
        pp.space(),
        pp.text("],"),
    }));

    {
        var writer = std.io.Writer.fixed(&buf_mem);

        const expected =
            \\Items: [
            \\    [
            \\        foo, bar, baz, qux,
            \\        foo, bar, baz, qux,
            \\        foo, bar, baz, qux,
            \\    ],
            \\    [ foo, bar, baz, qux, ],
            \\],
        ;

        try pp.render(doc_nested, &writer, .{ .max_width = 30 });

        try std.testing.expectEqualStrings(expected, writer.buffered());
    }

    {
        var writer = std.io.Writer.fixed(&buf_mem);

        const expected =
            \\Items: [
            \\    [ foo, bar, baz, qux, foo, bar, baz, qux, foo, bar, baz, qux, ],
            \\    [ foo, bar, baz, qux, ],
            \\],
        ;

        try pp.render(doc_nested, &writer, .{ .max_width = 80 });

        try std.testing.expectEqualStrings(expected, writer.buffered());
    }
}
