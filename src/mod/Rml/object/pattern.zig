const Rml = @import("../../Rml.zig");

const std = @import("std");
const utils = @import("utils");



pub const Alias = struct {
    sym: Rml.Obj(Rml.Symbol),
    sub: Rml.Object,

    pub fn compare(self: Alias, other: Alias) utils.Ordering {
        var ord = self.sym.compare(other.sym);

        if (ord == .Equal) {
            ord = self.sub.onCompare(other.sub);
        }

        return ord;
    }
};

pub const Pattern = union(enum) {
    // _                    ;wildcard
    wildcard: void,

    // x                    ;variable
    symbol: Rml.Obj(Rml.Symbol),

    // () [] {}             ;interchangeable block syntax
    // ~() ~[] ~{}          ;literal block syntax
    block: Rml.Obj(Rml.Block),

    // nil true 1 'c' "foo" ;literal
    value_literal: Rml.Object,

    // *(foo?) *(@foo x y)  ;procedural literal syntax
    procedure: Rml.Object,

    // 'foo '(foo)          ;value-wise quotation
    // `foo `(foo)          ;pattern-wise quotation
    // ,foo ,@foo           ;unquote, unquote-splicing
    quote: Rml.Obj(Rml.Quote),

    // (as symbol patt)     ;aliasing ;outer block is not-a-block
    alias: Alias,

    // x y z                ;bare sequence
    sequence: Rml.Obj(Rml.Array),

    // (? patt)             ;optional ;outer block is not-a-block
    optional: Rml.Object,

    // (* patt)             ;zero or more ;outer block is not-a-block
    zero_or_more: Rml.Object,

    // (+ patt)             ;one or more ;outer block is not-a-block
    one_or_more: Rml.Object,

    // (| patt patt)        ;alternation ;outer block is not-a-block
    alternation: Rml.Obj(Rml.Array),

    pub fn compare(self: Pattern, other: Pattern) utils.Ordering {
        var ord = utils.compare(std.meta.activeTag(self), std.meta.activeTag(other));

        if (ord == .Equal) {
            ord = switch (self) {
                .wildcard => ord,
                .symbol => |x| x.compare(other.symbol),
                .block => |x| x.compare(other.block),
                .value_literal => |x| x.compare(other.value_literal),
                .procedure => |x| x.compare(other.procedure),
                .quote => |x| x.compare(other.quote),
                .alias => |x| x.compare(other.alias),
                .sequence => |x| x.compare(other.sequence),
                .optional => |x| x.compare(other.optional),
                .zero_or_more => |x| x.compare(other.zero_or_more),
                .one_or_more => |x| x.compare(other.one_or_more),
                .alternation => |x| x.compare(other.alternation),
            };
        }

        return ord;
    }

    pub fn format(self: *const Pattern, comptime fmtStr: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror! void {
        const fmt = Rml.Format.fromStr(fmtStr) orelse .debug;
        const w = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();
        switch (self.*) {
            .wildcard => try w.writeAll("_"),
            .symbol => |x| try x.onFormat(fmt, w),
            .block => |x| try x.onFormat(fmt, w),
            .value_literal => |x| try x.onFormat(fmt, w),
            .procedure => |x| try x.onFormat(fmt, w),
            .quote => |x| try x.onFormat(fmt, w),
            .sequence => |x| {
                try w.writeAll("${");
                try Rml.format.slice(x.data.items()).onFormat(fmt, w);
                try w.writeAll("}");
            },
            .alias => |alias| {
                try w.writeAll("{as ");
                try alias.sym.onFormat(fmt, w);
                try w.writeAll(" ");
                try alias.sub.onFormat(fmt, w);
                try w.writeAll("}");
            },
            .optional => |optional| {
                try w.writeAll("{? ");
                try optional.onFormat(fmt, w);
                try w.writeAll("}");
            },
            .zero_or_more => |zero_or_more| {
                try w.writeAll("{* ");
                try zero_or_more.onFormat(fmt, w);
                try w.writeAll("}");
            },
            .one_or_more => |one_or_more| {
                try w.writeAll("{+ ");
                try one_or_more.onFormat(fmt, w);
                try w.writeAll("}");
            },
            .alternation => |alternation| {
                try w.writeAll("{| ");
                try Rml.format.slice(alternation.data.items()).onFormat(fmt, w);
                try w.writeAll("}");
            },
        }
    }

    pub fn binders(self: *Pattern) (Rml.OOM || error{BadDomain})! Rml.object.env.Domain {
        return patternBinders(Rml.getObj(self).typeErase());
    }

    pub fn run(self: *Pattern, interpreter: *Rml.Interpreter, diag: ?*?Rml.Diagnostic, origin: Rml.Origin, input: []const Rml.Object) Rml.Result! ?Rml.Obj(Table) {
        const obj = Rml.getObj(self);

        Rml.log.match.debug("Pattern.run `{} :: {any}` @ {}", .{obj, input, origin});

        var offset: usize = 0;

        const out = try out: {
            if (self.* == .block) {
                if (input.len == 1 and Rml.isArrayLike(input[0])) {
                    Rml.log.match.debug("block pattern with array-like input", .{});
                    const inner = try Rml.coerceArray(input[0])
                        orelse @panic("array-like object is not an array");

                    break :out runSequence(interpreter, diag, origin, self.block.data.items(), inner.data.items(), &offset);
                } else {
                    Rml.log.match.debug("block pattern with input stream", .{});
                    break :out runSequence(interpreter, diag, origin, self.block.data.items(), input, &offset);
                }
            } else {
                Rml.log.match.debug("non-block pattern with input stream", .{});
                break :out runPattern(interpreter, diag, origin, obj, input, &offset);
            }
        } orelse {
            Rml.log.match.debug("Pattern.run failed", .{});
            return null;
        };

        if (offset < input.len) {
            return patternAbort(diag, origin, "expected end of input, got `{}`", .{input[offset]});
        }

        return out;
    }

    pub fn parse(diag: ?*?Rml.Diagnostic, input: []const Rml.Object) (Rml.OOM || Rml.SyntaxError)! ?ParseResult(Pattern) {
        var offset: usize = 0;
        const pattern = try parsePattern(diag, input, &offset) orelse return null;
        return .{
            .value = pattern,
            .offset = offset,
        };
    }
};

pub fn ParseResult(comptime T: type) type {
    return struct {
        value: Rml.Obj(T),
        offset: usize,
    };
}

pub const Table = Rml.object.map.TypedMap(Rml.Symbol, Rml.ObjData);

pub fn patternBinders(patternObj: Rml.Object) (Rml.OOM || error{BadDomain})! Rml.object.env.Domain {
    const rml = patternObj.getRml();

    const pattern = Rml.castObj(Pattern, patternObj) orelse return .{};

    var domain: Rml.object.env.Domain = .{};

    switch (pattern.data.*) {
        .wildcard,
        .value_literal,
        .procedure,
        .quote,
            => {},

        .symbol => |symbol| try domain.put(rml.blobAllocator(), symbol, {}),

        .block => |block| for (block.data.items()) |item| {
            const subDomain = try patternBinders(item);
            for (subDomain.keys()) |key| {
                try domain.put(rml.blobAllocator(), key, {});
            }
        },

        .alias => |alias| try domain.put(rml.blobAllocator(), alias.sym, {}),

        .sequence => |sequence| for (sequence.data.items()) |item| {
            const subDomain = try patternBinders(item);
            for (subDomain.keys()) |key| {
                try domain.put(rml.blobAllocator(), key, {});
            }
        },

        .optional => |optional| {
            const subDomain = try patternBinders(optional);
            for (subDomain.keys()) |key| {
                try domain.put(rml.blobAllocator(), key, {});
            }
        },

        .zero_or_more => |zero_or_more| {
            const subDomain = try patternBinders(zero_or_more);
            for (subDomain.keys()) |key| {
                try domain.put(rml.blobAllocator(), key, {});
            }
        },

        .one_or_more => |one_or_more| {
            const subDomain = try patternBinders(one_or_more);
            for (subDomain.keys()) |key| {
                try domain.put(rml.blobAllocator(), key, {});
            }
        },

        .alternation => |alternation| {
            var referenceSubDomain: ?Rml.object.env.Domain = null;
            for (alternation.data.items()) |item| {
                var subDomain = try patternBinders(item);

                if (referenceSubDomain) |refDomain| {
                    if (utils.equal(refDomain, subDomain)) {
                        for (subDomain.keys()) |key| {
                            try domain.put(rml.blobAllocator(), key, {});
                        }
                    } else {
                        return error.BadDomain;
                    }
                } else {
                    referenceSubDomain = subDomain;
                }
            }
        },
    }

    return domain;
}


pub fn nilBinders (interpreter: *Rml.Interpreter, table: Rml.Obj(Table), origin: Rml.Origin, patt: Rml.Obj(Pattern)) Rml.Result! void {
    var binders = patternBinders(patt.typeErase()) catch |err| switch (err) {
        error.BadDomain => try interpreter.abort(patt.getOrigin(), error.PatternFailed,
            "bad domain in pattern `{}`", .{patt}),
        error.OutOfMemory => return error.OutOfMemory,
    };

    const nil = (try Rml.Obj(Rml.Nil).wrap(Rml.getRml(interpreter), origin, .{})).typeErase();

    for (binders.keys()) |key| {
        try table.data.set(key, nil);
    }
}

pub fn runPattern(
    interpreter: *Rml.Interpreter,
    diag: ?*?Rml.Diagnostic,
    origin: Rml.Origin,
    pattern: Rml.Obj(Pattern),
    objects: []const Rml.Object,
    offset: *usize,
) Rml.Result! ?Rml.Obj(Table) {
    const table: Rml.Obj(Table) = try .wrap(Rml.getRml(interpreter), origin, .{.allocator = Rml.getRml(interpreter).blobAllocator(),});

    Rml.log.match.debug("runPattern `{} :: {?}` {any} {}", .{pattern, if (offset.* < objects.len) objects[offset.*] else null, objects, offset.*});

    switch (pattern.data.*) {
        .wildcard => {},

        .symbol => |symbol| {
            Rml.log.match.debug("match symbol {}", .{symbol});
            if (offset.* >= objects.len) return patternAbort(diag, origin, "unexpected end of input", .{});
            const input = objects[offset.*];
            offset.* += 1;
            Rml.log.match.debug("input {}", .{input});
            try table.data.set(symbol, input);
            Rml.log.match.debug("bound", .{});
        },

        .block => |block| {
            Rml.log.match.debug("match block {}", .{block});
            const patts = block.data.items();
            if (offset.* >= objects.len) return patternAbort(diag, origin, "expected {}, got end of input", .{block});

            if (Rml.castObj(Rml.Block, objects[offset.*])) |inputBlock| {
                offset.* += 1;

                const seqOrigin = pattern.getOrigin();
                switch (block.data.kind) {
                    .doc => {
                        var newOffset: usize = 0;
                        const result = try runSequence(interpreter, diag, inputBlock.getOrigin(), patts, inputBlock.data.items(), &newOffset) orelse return null;
                        try table.data.copyFrom(result.data);
                    },
                    else =>
                        if (inputBlock.data.kind == block.data.kind) {
                            var newOffset: usize = 0;
                            const result = try runSequence(interpreter, diag, inputBlock.getOrigin(), patts, inputBlock.data.items(), &newOffset) orelse return null;
                            try table.data.copyFrom(result.data);
                        } else return patternAbort(
                            diag,
                            seqOrigin,
                            "expected a `{s}{s}` block, found `{s}{s}`",
                            .{
                                block.data.kind.toOpenStr(),
                                block.data.kind.toCloseStr(),
                                inputBlock.data.kind.toOpenStr(),
                                inputBlock.data.kind.toCloseStr(),
                            }
                        ),

                }
            } else {
                const input = objects[offset.*];
                offset.* += 1;
                return patternAbort(diag, pattern.getOrigin(), "expected a block, found `{}`", .{input});
            }
        },

        .value_literal => |value_literal| {
            Rml.log.match.debug("match value {}", .{value_literal});

            if (offset.* >= objects.len) return patternAbort(diag, origin, "expected {}, got end of input", .{value_literal});

            const input = objects[offset.*];
            offset.* += 1;

            if (value_literal.onCompare(input) != .Equal)
                return patternAbort(diag, input.getOrigin(),
                    "expected `{}`, got `{}`", .{value_literal, input});
        },

        .procedure => |procedure| {
            Rml.log.match.debug("match procedure call {}", .{procedure});

            if (offset.* >= objects.len) return patternAbort(diag, origin, "expected a procedure, got end of input", .{});

            const input = objects[offset.*];
            offset.* += 1;

            const result = try interpreter.invoke(input.getOrigin(), pattern.typeErase(), procedure, &.{input});
            if (!Rml.coerceBool(result))
                return patternAbort(diag, input.getOrigin(),
                    "expected a truthy value, got `{}`", .{input});
        },

        .quote => |quote| {
            if (offset.* >= objects.len) return patternAbort(diag, origin, "expected {}, got end of input", .{quote});

            const input = objects[offset.*];
            offset.* += 1;

            switch (quote.data.kind) {
                .basic => {
                    const patt = quote.data.body;
                    if (patt.onCompare(input) != .Equal) return patternAbort(diag, input.getOrigin(),
                        "expected `{}`, got `{}`", .{patt, input});
                },
                .quasi => {
                    const w = try Rml.object.quote.runQuasi(interpreter, quote.data.body, null);
                    if (w.onCompare(input) != .Equal) return patternAbort(diag, input.getOrigin(),
                        "expected `{}`, got `{}`", .{w, input});
                },
                .to_quote => {
                    const v = try interpreter.eval(quote.data.body);
                    const q = try Rml.Obj(Rml.Quote).wrap(Rml.getRml(interpreter), quote.getOrigin(), .{ .kind = .basic, .body = v});
                    if (q.onCompare(input) != .Equal) return patternAbort(diag, input.getOrigin(),
                        "expected `{}`, got `{}`", .{q, input});
                },
                .to_quasi => {
                    const v = try interpreter.eval(quote.data.body);
                    const q = try Rml.Obj(Rml.Quote).wrap(Rml.getRml(interpreter), quote.getOrigin(), .{ .kind = .quasi, .body = v});
                    if (q.onCompare(input) != .Equal) return patternAbort(diag, input.getOrigin(),
                        "expected `{}`, got `{}`", .{q, input});
                },
                .unquote, .unquote_splice => try interpreter.abort(quote.getOrigin(), error.UnexpectedInput,
                    "unquote syntax is not allowed in this context, found `{}`", .{quote}),
            }
        },

        .alias => |alias| {
            const sub: Rml.Obj(Pattern) = Rml.castObj(Pattern, alias.sub) orelse {
                try interpreter.abort(alias.sub.getOrigin(), error.UnexpectedInput,
                    "alias syntax expects a pattern in this context, found `{}`", .{alias.sub});
            };
            const result = try runPattern(interpreter, diag, origin, sub, objects, offset) orelse return null;
            if (result.data.length() > 0) {
                try table.data.set(alias.sym, result.typeErase());
            } else {
                if (offset.* < objects.len) {
                    try table.data.set(alias.sym, objects[offset.*]);
                } else {
                    try table.data.set(alias.sym, (try Rml.Obj(Rml.Nil).wrap(Rml.getRml(interpreter), origin, .{})).typeErase());
                }
            }
        },

        .sequence => |sequence| {
            const subEnv = try runSequence(interpreter, diag, sequence.getOrigin(), sequence.data.items(), objects, offset) orelse return null;

            try table.data.copyFrom(subEnv.data);
        },

        .optional => |optional| {
            const patt = Rml.castObj(Rml.Pattern, optional) orelse {
                try interpreter.abort(optional.getOrigin(), error.TypeError,
                    "optional syntax expects a pattern in this context, found `{}`", .{optional});
            };

            var subOffset = offset.*;
            const result = try runPattern(interpreter, null, origin, patt, objects, &subOffset);

            if (result) |res| {
                offset.* = subOffset;

                try table.data.copyFrom(res.data);
            } else {
                try nilBinders(interpreter, table, origin, patt);
            }
        },

        .zero_or_more => |zero_or_more| {
            const patt = Rml.castObj(Rml.Pattern, zero_or_more) orelse {
                try interpreter.abort(zero_or_more.getOrigin(), error.TypeError,
                    "zero-or-more syntax expects a pattern in this context, found `{}`", .{zero_or_more});
            };

            var i: usize = 0;

            var binders = patternBinders(patt.typeErase()) catch |err| switch (err) {
                error.BadDomain => try interpreter.abort(patt.getOrigin(), error.PatternFailed,
                    "bad domain in pattern `{}`", .{patt}),
                error.OutOfMemory => return error.OutOfMemory,
            };

            for (binders.keys()) |key| {
                const k = key;

                const obj = try Rml.Obj(Rml.Array).wrap(Rml.getRml(interpreter), origin, .{.allocator = Rml.getRml(interpreter).blobAllocator()});

                try table.data.set(k, obj.typeErase());
            }

            while (offset.* < objects.len) {
                var subOffset = offset.*;
                Rml.log.match.debug("*{} `{} :: {}`", .{i, patt, objects[subOffset]});
                const result = try runPattern(interpreter, null, origin, patt, objects, &subOffset);
                if (result) |res| {
                    i += 1;

                    for (res.data.keys()) |key| {
                        const arrayObj = table.data.get(key) orelse @panic("binder not in patternBinders result");

                        const array = Rml.castObj(Rml.Array, arrayObj) orelse {
                            try interpreter.abort(arrayObj.getOrigin(), error.TypeError,
                                "expected an array, found `{}`", .{arrayObj});
                        };

                        const erase = res.typeErase();

                        try array.data.append(erase);
                    }

                    offset.* = subOffset;
                } else {
                    break;
                }
            }
        },

        .one_or_more => |one_or_more| {
            const patt = Rml.castObj(Rml.Pattern, one_or_more) orelse {
                try interpreter.abort(one_or_more.getOrigin(), error.TypeError,
                    "one-or-more syntax expects a pattern in this context, found `{}`", .{one_or_more});
            };

            var binders = patternBinders(patt.typeErase()) catch |err| switch (err) {
                error.BadDomain => try interpreter.abort(patt.getOrigin(), error.PatternFailed,
                    "bad domain in pattern {}", .{patt}),
                error.OutOfMemory => return error.OutOfMemory,
            };

            for (binders.keys()) |key| {
                const k = key;

                const obj = try Rml.Obj(Rml.Array).wrap(Rml.getRml(interpreter), origin, .{.allocator = Rml.getRml(interpreter).blobAllocator()});

                try table.data.set(k, obj.typeErase());
            }


            var i: usize = 0;

            while (offset.* < objects.len) {
                var subOffset = offset.* ;
                Rml.log.match.debug("+{} `{} :: {}`", .{i, patt, objects[subOffset]});
                const result = try runPattern(interpreter, null, origin, patt, objects, &subOffset);
                Rml.log.match.debug("✓", .{});
                if (result) |res| {
                    Rml.log.match.debug("matched `{} :: {}`", .{patt, objects[offset.*]});

                    i += 1;

                    for (res.data.keys()) |key| {
                        const arrayObj = table.data.get(key) orelse @panic("binder not in patternBinders result");

                        const array = Rml.castObj(Rml.Array, arrayObj) orelse {
                            try interpreter.abort(arrayObj.getOrigin(), error.TypeError,
                                "expected an array, found {}", .{arrayObj});
                        };

                        const erase = res.typeErase();

                        try array.data.append(erase);
                    }

                    offset.* = subOffset;
                } else {
                    break;
                }
            }

            if (i == 0) {
                return patternAbort(diag, origin, "expected at least one match for pattern {}", .{patt});
            }
        },

        .alternation => |alternation| {
            const pattObjs = alternation.data.items();
            var errs: Rml.String = try .create(Rml.getRml(interpreter), "");

            const errWriter = errs.writer();

            loop: for (pattObjs) |pattObj| {
                const patt = Rml.castObj(Rml.Pattern, pattObj) orelse {
                    try interpreter.abort(pattObj.getOrigin(), error.UnexpectedInput,
                        "alternation syntax expects a pattern in this context, found `{}`", .{pattObj});
                };

                var diagStorage: ?Rml.Diagnostic = null;
                const newDiag = if (diag != null) &diagStorage else null;

                var subOffset = offset.*;
                const result = try runPattern(interpreter, newDiag, origin, patt, objects, &subOffset);

                if (result) |res| {
                    offset.* = subOffset;

                    try table.data.copyFrom(res.data);

                    break :loop;
                } else if (newDiag) |dx| {
                    if (dx.*) |d| {
                        const formatter = d.formatter(error.PatternMatch);
                        Rml.log.debug("failed alternative {}", .{formatter});
                        errWriter.print("\t{}\n", .{formatter}) catch |e| @panic(@errorName(e));
                    } else {
                        Rml.log.warn("requested pattern diagnostic is null", .{});
                        errWriter.print("\tfailed\n", .{}) catch |e| @panic(@errorName(e));
                    }
                }
            }

            return patternAbort(diag, objects[offset.*].getOrigin(),
                "all alternatives failed:\n{s}", .{errs.text()});
        }
    }

    Rml.log.match.debug("completed runPattern, got {}", .{table});

    var it = table.data.native_map.iterator();
    while (it.next()) |entry| {
        Rml.log.match.debug("{} :: {}", .{
            entry.key_ptr.*,
            entry.value_ptr.*,
        });
    }

    return table;
}

fn runSequence(
    interpreter: *Rml.Interpreter,
    diag: ?*?Rml.Diagnostic,
    origin: Rml.Origin,
    patterns: []const Rml.Object,
    objects: []const Rml.Object,
    offset: *usize,
) Rml.Result! ?Rml.Obj(Table) {
    const table: Rml.Obj(Table) = try .wrap(Rml.getRml(interpreter), origin, .{.allocator = Rml.getRml(interpreter).blobAllocator()});

    for (patterns, 0..) |patternObj, p| {
        _ = p;

        const pattern = Rml.castObj(Rml.Pattern, patternObj) orelse {
            try interpreter.abort(patternObj.getOrigin(), error.UnexpectedInput,
                "sequence syntax expects a pattern in this context, found `{}`", .{patternObj});
        };

        const result = try runPattern(interpreter, diag, origin, pattern, objects, offset) orelse return null;

        try table.data.copyFrom(result.data);
    }

    if (offset.* < objects.len) return patternAbort(diag, origin, "unexpected input `{}`", .{objects[offset.*]});

    return table;
}

fn patternAbort(diagnostic: ?*?Rml.Diagnostic, origin: Rml.Origin, comptime fmt: []const u8, args: anytype) ?Rml.Obj(Table) {
    const diagPtr = diagnostic orelse return null;

    var diag = Rml.Diagnostic {
        .error_origin = origin,
    };

    // the error produced is only NoSpaceLeft, if the buffer is too small, so give the length of the buffer
    diag.message_len = len: {
        break :len (std.fmt.bufPrintZ(&diag.message_mem, fmt, args) catch {
            Rml.log.warn("Pattern Diagnostic message too long, truncating", .{});
            break :len Rml.Diagnostic.MAX_LENGTH;
        }).len;
    };

    diagPtr.* = diag;

    return null;
}


fn abortParse(diagnostic: ?*?Rml.Diagnostic, origin: Rml.Origin, err: (Rml.OOM || Rml.SyntaxError), comptime fmt: []const u8, args: anytype) (Rml.OOM || Rml.SyntaxError)! noreturn {
    const diagPtr = diagnostic orelse return err;

    var diag = Rml.Diagnostic {
        .error_origin = origin,
    };

    // the error produced is only NoSpaceLeft, if the buffer is too small, so give the length of the buffer
    diag.message_len = len: {
        break :len (std.fmt.bufPrintZ(&diag.message_mem, fmt, args) catch {
            Rml.log.warn("Diagnostic message too long, truncating", .{});
            break :len Rml.Diagnostic.MAX_LENGTH;
        }).len;
    };

    diagPtr.* = diag;

    return err;
}

fn parseSequence(rml: *Rml, diag: ?*?Rml.Diagnostic, objects: []const Rml.Object, offset: *usize) (Rml.OOM || Rml.SyntaxError)! ?[]Rml.Obj(Pattern) {
    Rml.log.match.debug("parseSequence {any} {}", .{objects, offset.*});
    var output: std.ArrayListUnmanaged(Rml.Obj(Pattern)) = .{};

    while (offset.* < objects.len) {
        const patt = try parsePattern(diag, objects, offset) orelse return null;

        try output.append(rml.blobAllocator(), patt);
    }

    return output.items;
}

fn parsePattern(diag: ?*?Rml.Diagnostic, objects: []const Rml.Object, offset: *usize) (Rml.OOM || Rml.SyntaxError)! ?Rml.Obj(Pattern) {
    const input = objects[offset.*];

    for (SENTINEL_SYMBOLS) |sentinel| {
        if (Rml.castObj(Rml.Symbol, input)) |sym| {
            if (std.mem.eql(u8, sym.data.text(), sentinel)) {
                return null;
            }
        }
    }
    offset.* += 1;

    const rml = input.getRml();

    if (Rml.castObj(Pattern, input)) |patt| {
        Rml.log.match.debug("parsePattern got existing pattern `{}`", .{patt});
        return patt;
    } else {
        Rml.log.match.debug("parsePattern {}:`{}` {any} {}", .{input.getOrigin(), input, objects, offset.*});
        const body: Pattern =
            if (Rml.castObj(Rml.Symbol, input)) |sym| sym: {
                Rml.log.match.debug("parsePattern symbol", .{});

                break :sym if (BUILTIN_SYMBOLS.matchText(sym.data.text())) |fun| {
                    return try fun(diag, input, objects, offset);
                } else .{.symbol = sym};
            }
            else if (Rml.isAtom(input)) .{.value_literal = input}
            else if (Rml.castObj(Rml.Quote, input)) |quote| .{.quote = quote}
            else if (Rml.castObj(Rml.Block, input)) |block| block: {
                Rml.log.match.debug("parsePattern block", .{});

                if (block.data.length() > 0) not_a_block: {
                    const items = block.data.items();

                    const symbol = Rml.castObj(Rml.Symbol, items[0]) orelse break :not_a_block;

                    inline for (comptime std.meta.declarations(NOT_A_BLOCK)) |decl| {
                        if (std.mem.eql(u8, decl.name, symbol.data.text())) {
                            Rml.log.match.debug("using {} as a not-a-block pattern", .{symbol});
                            var subOffset: usize = 1;
                            return try @field(NOT_A_BLOCK, decl.name)(diag, input, block.data.items(), &subOffset);
                        }
                    }
                }

                var subOffset: usize = 0;
                const seq: []Rml.Obj(Pattern) = try parseSequence(rml, diag, block.data.items(), &subOffset) orelse return null;

                break :block Pattern { .block = try Rml.Obj(Rml.Block).wrap(rml, input.getOrigin(), try .create(rml, .doc, @ptrCast(seq))) };
            }
            else {
                try abortParse(diag, input.getOrigin(), error.UnexpectedInput,
                    "`{}` is not a valid pattern", .{input});
            };

        return try Rml.Obj(Rml.Pattern).wrap(rml, input.getOrigin(), body);
    }
}

const SENTINEL_SYMBOLS: []const []const u8 = &.{ "=>" };

const BUILTIN_SYMBOLS = struct {
    fn matchText(text: []const u8) ?*const fn (?*?Rml.Diagnostic, Rml.Object, []const Rml.Object, *usize) (Rml.OOM || Rml.SyntaxError)! Rml.Obj(Pattern) {
        inline for (comptime std.meta.declarations(BUILTIN_SYMBOLS)) |decl| {
            if (std.mem.eql(u8, decl.name, text)) return @field(BUILTIN_SYMBOLS, decl.name);
        }
        return null;
    }

    pub fn @"_"(_: ?*?Rml.Diagnostic, input: Rml.Object, _: []const Rml.Object, _: *usize) (Rml.OOM || Rml.SyntaxError)! Rml.Obj(Pattern) {
        return Rml.Obj(Pattern).wrap(input.getRml(), input.getOrigin(), .wildcard);
    }

    /// literal block syntax; expect a block, return that exact block kind (do not change to doc like default)
    pub fn @"~"(diag: ?*?Rml.Diagnostic, input: Rml.Object, objects: []const Rml.Object, offset: *usize) (Rml.OOM || Rml.SyntaxError)! Rml.Obj(Pattern) {
        const rml = input.getRml();
        const origin = input.getOrigin();

        if (offset.* >= objects.len) return error.UnexpectedEOF;

        const block = Rml.castObj(Rml.Block, objects[offset.*]) orelse {
            return error.UnexpectedInput;
        };
        offset.* += 1;

        var subOffset: usize = 0;
        const body = try parseSequence(rml, diag, block.data.items(), &subOffset);

        const patternBlock = try Rml.Obj(Rml.Block).wrap(rml, origin, try .create(rml, block.data.kind, @ptrCast(body)));

        return Rml.Obj(Pattern).wrap(rml, origin, .{.block = patternBlock});
    }

    pub fn @"$"(diag: ?*?Rml.Diagnostic, input: Rml.Object, objects: []const Rml.Object, offset: *usize) (Rml.OOM || Rml.SyntaxError)! Rml.Obj(Pattern) {
        const rml = input.getRml();
        const origin = input.getOrigin();

        if (offset.* >= objects.len) return error.UnexpectedEOF;

        const block = Rml.castObj(Rml.Block, objects[offset.*])
            orelse try abortParse(diag, origin, error.UnexpectedInput, "expected a block to escape following `$`, got `{}`", .{objects[offset.*]});
        offset.* += 1;

        const seq = seq: {
            const items = try block.data.array.clone(input.getRml().blobAllocator());

            break :seq try Rml.Obj(Rml.Array).wrap(rml, origin, .{ .allocator = input.getRml().blobAllocator(), .native_array = items });
        };

        return Rml.Obj(Pattern).wrap(rml, origin, .{.sequence = seq});
    }
};

const NOT_A_BLOCK = struct {
    fn recursive(comptime name: []const u8) *const fn (?*?Rml.Diagnostic, Rml.Object, []const Rml.Object, *usize) (Rml.OOM || Rml.SyntaxError)! Rml.Obj(Pattern) {
        return &struct {
            pub fn fun(diag: ?*?Rml.Diagnostic, obj: Rml.Object, objects: []const Rml.Object, offset: *usize) (Rml.OOM || Rml.SyntaxError)! Rml.Obj(Pattern) {
                Rml.log.match.debug("recursive-{s} `{}` {any} {}", .{name, obj, objects, offset.*});
                const rml = obj.getRml();

                if (offset.* != 1)
                    try abortParse(diag, obj.getOrigin(), error.UnexpectedInput, "{s}-syntax should be at start of expression", .{name});

                if (offset.* >= objects.len)
                    try abortParse(diag, obj.getOrigin(), error.UnexpectedInput, "expected a pattern for {s}-syntax", .{name});

                const array = array: {
                    const seq = try parseSequence(rml, diag, objects, offset);

                    break :array try Rml.Obj(Rml.Array).wrap(rml, obj.getOrigin(), try .create(rml.blobAllocator(), @ptrCast(seq)));
                };

                const sub = switch (array.data.length()) {
                    0 => unreachable,
                    1 => one: {
                        const singleObj = array.data.get(0).?;
                        break :one Rml.object.castObj(Pattern, singleObj).?;
                    },
                    else => try Rml.Obj(Pattern).wrap(obj.getRml(), obj.getOrigin(), .{.sequence = array}),
                };

                return Rml.Obj(Pattern).wrap(obj.getRml(), obj.getOrigin(), @unionInit(Pattern, name, sub.typeErase()));
            }
        }.fun;
    }

    pub const @"?" = recursive("optional");
    pub const @"*" = recursive("zero_or_more");
    pub const @"+" = recursive("one_or_more");

    pub fn @"|"(diag: ?*?Rml.Diagnostic, input: Rml.Object, objects: []const Rml.Object, offset: *usize) (Rml.OOM || Rml.SyntaxError)! Rml.Obj(Pattern) {
        if (offset.* != 1)
            try abortParse(diag, input.getOrigin(), error.UnexpectedInput, "alternation-syntax should be at start of expression", .{});

        if (offset.* >= objects.len)
            try abortParse(diag, input.getOrigin(), error.UnexpectedInput, "expected a block to follow `|`", .{});

        const rml = input.getRml();
        const origin = input.getOrigin();

        const array = array: {
            const seq = try parseSequence(rml, diag, objects, offset);

            break :array try Rml.Obj(Rml.Array).wrap(rml, origin, try .create(rml.blobAllocator(), @ptrCast(seq)));
        };

        return Rml.Obj(Pattern).wrap(rml, origin, .{.alternation = array});
    }
};
