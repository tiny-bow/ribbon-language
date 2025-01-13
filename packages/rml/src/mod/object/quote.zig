const std = @import("std");

const Rml = @import("../root.zig");



pub const QuoteKind = enum {
    // these need to be ordered length-wise if they use the same prefix
    // (e.g. unquote_splice must come before unquote)
    basic,
    quasi,
    to_quote,
    to_quasi,
    unquote_splice,
    unquote,

    pub fn toStr(self: QuoteKind) []const u8 {
        return switch (self) {
            .basic => "'",
            .quasi => "`",
            .to_quote => "~'",
            .to_quasi => "~`",
            .unquote_splice => ",@",
            .unquote => ",",
        };
    }

    pub fn fromStr(str: []const u8) ?QuoteKind {
        return if (std.mem.eql(u8, str, "'")) .basic
          else if (std.mem.eql(u8, str, "`")) .quasi
          else if (std.mem.eql(u8, str, "~'")) .to_quote
          else if (std.mem.eql(u8, str, "~`")) .to_quasi
          else if (std.mem.eql(u8, str, ",@")) .unquote_splice
          else if (std.mem.eql(u8, str, ",")) .unquote
          else null;
    }
};

pub const Quote = struct {
    kind: QuoteKind,
    body: Rml.Object,

    pub fn onInit(self: *Quote, kind: QuoteKind, body: Rml.Object) void {
        self.kind = kind;
        self.body = body;
    }

    pub fn onCompare(self: *Quote, other: Rml.Object) Rml.Ordering {
        var ord = Rml.compare(Rml.getTypeId(self), other.getTypeId());

        if (ord == .Equal) {
            const other_quote = Rml.forceObj(Quote, other);

            ord = Rml.compare(self.kind, other_quote.data.kind);

            if (ord == .Equal) {
                ord = self.body.compare(other_quote.data.body);
            }
        }

        return ord;
    }

    pub fn onFormat(self: *Quote, fmt: Rml.Format, writer: std.io.AnyWriter) anyerror! void {
        try writer.writeAll(self.kind.toStr());
        try self.body.onFormat(fmt, writer);
    }

    pub fn run(self: *Quote, interpreter: *Rml.Interpreter) Rml.Result! Rml.Object {
        switch (self.kind) {
            .basic => {
                Rml.log.interpreter.debug("evaluating basic quote {}", .{self});
                return self.body;
            },
            .quasi => {
                Rml.log.interpreter.debug("evaluating quasi quote {}", .{self});
                return runQuasi(interpreter, self.body, null);
            },
            .to_quote => {
                Rml.log.interpreter.debug("evaluating to_quote quote {}", .{self});
                const val = try interpreter.eval(self.body);
                return (try Rml.Obj(Quote).wrap(Rml.getRml(self), self.body.getOrigin(), .{.kind = .basic, .body = val})).typeErase();
            },
            .to_quasi => {
                Rml.log.interpreter.debug("evaluating to_quasi quote {}", .{self});
                const val = try interpreter.eval(self.body);
                return (try Rml.Obj(Quote).wrap(Rml.getRml(self), self.body.getOrigin(), .{.kind = .quasi, .body = val})).typeErase();
            },
            else => {
                try interpreter.abort(Rml.getOrigin(self), error.TypeError, "unexpected {s}", .{@tagName(self.kind)});
            },
        }
    }
};


pub fn runQuasi(interpreter: *Rml.Interpreter, body: Rml.Object, out: ?*std.ArrayListUnmanaged(Rml.Object)) Rml.Result! Rml.Object {
    const rml = Rml.getRml(interpreter);

    if (Rml.castObj(Quote, body)) |quote| quote: {
        const origin = quote.getOrigin();

        switch (quote.data.kind) {
            .basic => break :quote,
            .quasi => break :quote,
            .to_quote => {
                const ranBody = try runQuasi(interpreter, quote.data.body, null);
                return (try Rml.Obj(Quote).wrap(rml, origin, .{.kind = .basic, .body = ranBody})).typeErase();
            },
            .to_quasi => {
                const ranBody = try runQuasi(interpreter, quote.data.body, null);
                return (try Rml.Obj(Quote).wrap(rml, origin, .{.kind = .quasi, .body = ranBody})).typeErase();
            },
            .unquote => {
                return interpreter.eval(quote.data.body);
            },
            .unquote_splice => {
                const outArr = out
                    orelse try interpreter.abort(body.getOrigin(), error.UnexpectedInput,
                        "unquote-splice is not allowed here", .{});

                const ranBody = try interpreter.eval(quote.data.body);

                const arrBody = try Rml.coerceArray(ranBody)
                    orelse try interpreter.abort(quote.data.body.getOrigin(), error.TypeError,
                        "unquote-splice expects an array-like, got {s}: {}", .{Rml.TypeId.name(ranBody.getTypeId()), ranBody});

                for (arrBody.data.items()) |item| {
                    try outArr.append(rml.blobAllocator(), item);
                }

                return (try Rml.Obj(Rml.Nil).wrap(rml, origin, .{})).typeErase();
            }
        }
    } else if (Rml.castObj(Rml.Block, body)) |block| {
        var subOut: std.ArrayListUnmanaged(Rml.Object) = .{};

        for (block.data.array.items) |item| {
            const len = subOut.items.len;

            const ranItem = try runQuasi(interpreter, item, &subOut);

            // don't append if its the nil from unquote-splice
            if (len == subOut.items.len) try subOut.append(rml.blobAllocator(), ranItem)
            else {
                std.debug.assert(Rml.isType(Rml.Nil, ranItem));
            }
        }

        return (try Rml.Obj(Rml.Block).wrap(rml, block.getOrigin(), try .create(Rml.getRml(interpreter), block.data.kind, subOut.items))).typeErase();
    }

    return body;
}
