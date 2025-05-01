const std = @import("std");
const log = std.log.scoped(.syntactic_analysis);
const analysis = @import("../basic_analysis.zig");
const pl = @import("platform");
const common = @import("common");
const utils = @import("utils");

/// Errors that can occur in the parser.
pub const SyntaxError = error {
    /// The parser encountered an unexpected token.
    UnexpectedToken,
} || analysis.LexicalError;



/// A concrete syntax tree node yielded by the meta language parser.
pub const Expr = extern struct {
    /// The source location where the expression began.
    location: analysis.Location,
    /// The type of the expression.
    type: common.Id.of(Expr),
    /// The token that generated this expression.
    token: analysis.Token,
    /// Subexpressions of this expression, if any.
    operands: common.Id.Buffer(Expr, .constant),

    /// Deinitialize the sub-tree of this expression and free all memory allocated for it.
    pub fn deinit(self: *Expr, allocator: std.mem.Allocator) void {
        const xs = @constCast(self.operands.asSlice());
        for (xs) |*x| x.deinit(allocator);
        if (xs.len != 0) {
            // empty buffer != empty slice
            allocator.free(xs);
        }
    }

    /// `std.fmt` impl
    pub fn format(self: *const Expr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.type) {
            ExprTypes.Int => {
                try writer.print("Int({s})", .{self.token.data.sequence.asSlice()});
            },
            ExprTypes.Identifier => {
                try writer.print("Identifier({s})", .{self.token.data.sequence.asSlice()});
            },
            ExprTypes.IndentedBlock => {
                try writer.print("IndentedBlock({any})", .{self.operands.asSlice()});
            },
            ExprTypes.Stmts => {
                try writer.print("Stmts({any})", .{self.operands.asSlice()});
            },
            ExprTypes.Qed => {
                try writer.print("Qed", .{});
            },
            else => {
                try writer.print("[{}]({}, {any})", .{@intFromEnum(self.type), self.token, self.operands.asSlice()});
            }
        }
    }
};

/// Builtin types of expressions.
pub var ExprTypes = gen: {
    var fresh = common.Id.of(Expr).fromInt(1);

    break :gen .{
        .Int = fresh.next(),
        .Identifier = fresh.next(),
        .IndentedBlock = fresh.next(),
        .Stmts = fresh.next(),
        .Qed = fresh.next(),
        .fresh_id = fresh,
    };
};

/// Extern signal for parser callbacks.
pub const ParserSignal = enum(i8) {
    /// Continue parsing with the result of this pattern.
    okay = 0,
    /// Continue parsing with a different pattern, this one did not match.
    reject = 1,
    /// Stop parsing.
    panic = -1,
};

pub fn PatternModifier(comptime P: type) type {
    return union(enum) {
        const Self = @This();

        none: void,
        any: void,
        standard: P,
        inverted: P,
        one_of: []const P,
        any_of: []const P,
        all_of: []const P,

        const Q = if (pl.hasDecl(P, .QueryType)) P.QueryType else P;

        pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            switch (self.*) {
                .none => try writer.print("none", .{}),
                .any => try writer.print("any", .{}),
                .standard => try writer.print("{}", .{self.standard}),
                .inverted => try writer.print("inv({})", .{self.inverted}),
                .one_of => try writer.print("one({any})", .{self.one_of}),
                .any_of => try writer.print("any({any})", .{self.any_of}),
                .all_of => try writer.print("all({any})", .{self.all_of}),
            }
        }

        fn processCallback(self: *const Self, q: Q, comptime callback: fn (P, Q) bool) bool {
            log.debug("processing {} with {}", .{q, self});
            switch (self.*) {
                .none => return false,
                .any => return true,
                .standard => |my_p| return callback(my_p, q),
                .inverted => |my_p| return !callback(my_p, q),
                .one_of => |my_ps| {
                    for (my_ps) |my_p| {
                        if (callback(my_p, q)) {
                            return true;
                        }
                    }

                    return false;
                },
                .any_of => |my_ps| {
                    for (my_ps) |my_p| {
                        if (callback(my_p, q)) {
                            return true;
                        }
                    }

                    return false;
                },
                .all_of => |my_ps| {
                    for (my_ps) |my_p| {
                        if (!callback(my_p, q)) {
                            return false;
                        }
                    }

                    return true;
                },
            }
        }

        pub fn process(self: *const Self, q: Q) bool {
            const result = self.processCallback(q, switch (P) {
                common.Id.Buffer(u8, .constant) => struct {
                    pub fn callback(a: P, b: Q) bool {
                        return std.mem.eql(u8, a.asSlice(), b.asSlice());
                    }
                },
                TokenPattern => struct {
                    pub fn callback(a: P, b: Q) bool {
                        if (@as(analysis.TokenType, a) != b.tag) return false;

                        return switch (a) {
                            .sequence => |p| p.process(b.data.sequence),
                            .linebreak => |p| p.process(b.data.linebreak),
                            .special => |p| p.process(b.data.special),
                        };
                    }
                },
                else => if (comptime std.meta.hasUniqueRepresentation(P)) struct {
                    pub fn callback(a: P, b: Q) bool {
                        return a == b;
                    }
                } else switch (@typeInfo(P)) {
                    .bool => struct { // TODO: why is this necessary? bool doesnt have unique representation??
                        pub fn callback(a: P, b: Q) bool {
                            return a == b;
                        }
                    },
                    .@"struct" => |info| struct {
                        pub fn callback(a: P, b: Q) bool {
                            inline for (info.fields) |field| {
                                if (!@field(a, field.name).process(@field(b, field.name))) return false;
                            }

                            return true;
                        }
                    },
                    else => @compileError("PatternModifier: unsupported type " ++ @typeName(P)),
                },
            }.callback);

            log.debug("process result: {s}", .{if (result) "accept" else "reject"});

            return result;
        }
    };
}

pub const TokenPattern = union(analysis.TokenType) {
    pub const QueryType = *const analysis.Token;
    sequence: PatternModifier(common.Id.Buffer(u8, .constant)),
    linebreak: PatternModifier(struct {
        const Self = @This();
        pub const QueryType = @FieldType(analysis.TokenData, "linebreak");
        n: PatternModifier(u32),
        i: PatternModifier(analysis.IndentDelta),

        pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("⇓{}, {}", .{ self.n, self.i });
        }
    }),
    special: PatternModifier(struct {
        const Self = @This();
        pub const QueryType = @FieldType(analysis.TokenData, "special");
        escaped: PatternModifier(bool),
        punctuation: PatternModifier(analysis.Punctuation),

        pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{}, {}", .{self.escaped, self.punctuation});
        }
    }),

    pub fn format(self: *const TokenPattern, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.*) {
            .sequence => try writer.print("s⟨{}⟩", .{self.sequence}),
            .linebreak => try writer.print("b⟨{}⟩", .{self.linebreak}),
            .special => try writer.print("p⟨{}⟩", .{self.special}),
        }
    }
};

pub fn PatternSet(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const QueryResult = struct {
            name: []const u8,
            binding_power: i16,
            userdata: ?*anyopaque,
            callback: *const T,

            pub fn invoke(
                self: *const QueryResult,
                args: anytype,
            ) ParserSignal {
                return @call(.auto, self.callback, .{self.userdata} ++ args);
            }
        };

        entries: std.MultiArrayList(Pattern(T)) = .empty,
        query_cache: pl.ArrayList(QueryResult) = .empty,

        pub const empty = Self { .entries = .empty };

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
        }

        pub fn bindPattern(
            self: *Self, allocator: std.mem.Allocator,
            pattern: Pattern(T),
        ) error{OutOfMemory}!void {
            try self.entries.append(allocator, pattern);
        }

        /// Find the patterns matching a given token, if any.
        pub fn findPatterns(
            self: *const PatternSet(T), allocator: std.mem.Allocator,
            token: *const analysis.Token,
        ) error{OutOfMemory}![]const QueryResult {
            const patterns = self.entries.items(.token);
            const bps = self.entries.items(.binding_power);
            const userdata = self.entries.items(.userdata);
            const callbacks = self.entries.items(.callback);
            const names = self.entries.items(.name);

            @constCast(self).query_cache.clearRetainingCapacity();

            for (patterns, 0..) |*pattern, index| {
                if (!pattern.process(token)) continue;

                try @constCast(self).query_cache.append(allocator, .{.name = names[index], .binding_power = bps[index], .userdata = userdata[index], .callback = callbacks[index]});
            }

            std.mem.sort(
                QueryResult,
                self.query_cache.items,
                {},
                struct {
                    pub fn query_result_sort(_: void, a: QueryResult, b: QueryResult) bool {
                        return a.binding_power > b.binding_power;
                    }
                }.query_result_sort
            );

            return self.query_cache.items;
        }
    };
}


/// Defines the possible syntax accepted by a Parser.
pub const Syntax = struct {
    /// Allocator providing all Syntax memory.
    allocator: std.mem.Allocator,

    /// Nud patterns for known token types.
    nuds: PatternSet(NudCallback) = .empty,
    /// Led patterns for known token types.
    leds: PatternSet(LedCallback) = .empty,

    /// Initialize a new, empty syntax.
    pub fn init(
        allocator: std.mem.Allocator,
    ) Syntax {
        return Syntax{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Syntax) void {
        self.nuds.deinit(self.allocator);
        self.leds.deinit(self.allocator);
    }

    pub fn bindNud(
        self: *Syntax,
        nud: Nud,
    ) error{OutOfMemory}!void {
        return self.nuds.bindPattern(self.allocator, nud);
    }

    pub fn bindLed(
        self: *Syntax,
        led: Led,
    ) error{OutOfMemory}!void {
        return self.leds.bindPattern(self.allocator, led);
    }

    /// Find the nuds matching a given token, if any.
    pub fn findNuds(self: *const Syntax, token: *const analysis.Token) error{OutOfMemory}![]const PatternSet(NudCallback).QueryResult {
        return self.nuds.findPatterns(self.allocator, token);
    }

    /// Find the leds matching a given token, if any.
    pub fn findLeds(self: *const Syntax, token: *const analysis.Token) error{OutOfMemory}![]const PatternSet(LedCallback).QueryResult {
        return self.leds.findPatterns(self.allocator, token);
    }
};

pub const NudCallback = fn (userdata: ?*anyopaque, parser: *Parser, bp: i16, token: analysis.Token, out: *Expr, err: *SyntaxError) callconv(.C) ParserSignal;

pub const LedCallback = fn (userdata: ?*anyopaque, parser: *Parser, lhs: Expr, bp: i16, token: analysis.Token, out: *Expr, err: *SyntaxError) callconv(.C) ParserSignal;

pub fn Pattern(comptime T: type) type {
    return struct {
        /// The name to refer to this pattern by in debug messages.
        name: []const u8,
        /// The token pattern to match
        token: PatternModifier(TokenPattern),
        /// The binding power of this pattern.
        binding_power: i16,
        /// Optional user data to pass to the callback.
        userdata: ?*anyopaque,
        /// The callback to invoke when this pattern is matched.
        callback: *const T,
    };
}

/// A nud is a function/closure that takes a parser and a token,
/// and parses some subset of the source code as a prefix expression.
pub const Nud = Pattern(NudCallback);

/// A led is a function/closure that takes a parser and a token, as well as a left hand side expression,
/// and parses some subset of the source code as an infix or postfix expression.
pub const Led = Pattern(LedCallback);

/// Expected inputs:
/// * `..., null, fn (*Parser, i16, Token) SyntaxError!?Expr`
/// * `..., *T, fn (*T, *Parser, i16, Token) SyntaxError!?Expr`
/// * `..., _, *const fn ..`
pub fn createNud(name: []const u8, binding_power: i16, token: PatternModifier(TokenPattern), userdata: anytype, callback: anytype) Nud {
    const Userdata = comptime @TypeOf(userdata);
    const uInfo = comptime @typeInfo(Userdata);
    return Nud {
        .name = name,
        .token = token,
        .binding_power = binding_power,
        .userdata = if (comptime uInfo == .null) null else @ptrCast(userdata),
        .callback = wrapNativeNudCallback(if (comptime uInfo == .null) void else Userdata, callback),
    };
}

/// Expected inputs:
/// * `..., null, fn (*Parser, Expr, i16, Token) SyntaxError!?Expr`
/// * `..., *T, fn (*T, *Parser, Expr, i16, Token) SyntaxError!?Expr`
/// * `..., _, *const fn ..`
pub fn createLed(name: []const u8, binding_power: i16, token: PatternModifier(TokenPattern), userdata: anytype, callback: anytype) Led {
    const Userdata = comptime @TypeOf(userdata);
    const uInfo = comptime @typeInfo(Userdata);
    return Led {
        .name = name,
        .token = token,
        .binding_power = binding_power,
        .userdata = if (comptime uInfo == .null) null else @ptrCast(userdata),
        .callback = wrapNativeLedCallback(if (comptime uInfo == .null) void else Userdata, callback),
    };
}

/// Expected inputs:
/// * `void, fn (*Parser, i16, Token) SyntaxError!?Expr`
/// * `T, fn (*T, *Parser, i16, Token) SyntaxError!?Expr`
/// * `_, *const fn ..`
pub fn wrapNativeNudCallback(comptime Userdata: type, callback: anytype) NudCallback {
    return struct {
        pub fn nud_callback_wrapper(
            userdata: ?*anyopaque,
            parser: *Parser,
            bp: i16,
            token: analysis.Token,
            out: *Expr,
            err: *SyntaxError,
        ) callconv(.c) ParserSignal {
            const result =
                if (comptime Userdata != void)
                    @call(.auto, callback, .{userdata} ++ .{parser, bp, token})
                else
                    @call(.auto, callback, .{parser, bp, token});

            const maybe = result catch |e| {
                err.* = e;
                return .panic;
            };

            out.* = maybe orelse {
                return .reject;
            };

            return .okay;
        }
    }.nud_callback_wrapper;
}

/// Expected inputs:
/// * `void, fn (*Parser, Expr, i16, Token) SyntaxError!?Expr`
/// * `T, fn (*T, *Parser, Expr, i16, Token) SyntaxError!?Expr`
/// * `_, *const fn ..`
pub fn wrapNativeLedCallback(comptime Userdata: type, callback: anytype) LedCallback {
    return struct {
        pub fn led_callback_wrapper(
            userdata: ?*anyopaque,
            parser: *Parser,
            lhs: Expr,
            bp: i16,
            token: analysis.Token,
            out: *Expr,
            err: *SyntaxError,
        ) callconv(.c) ParserSignal {
            const result =
                if (comptime Userdata != void)
                    @call(.auto, callback, .{userdata} ++ .{parser, lhs, bp, token})
                else
                    @call(.auto, callback, .{parser, lhs, bp, token});

            const maybe = result catch |e| {
                err.* = e;
                return .panic;
            };

            out.* = maybe orelse {
                return .reject;
            };

            return .okay;
        }
    }.led_callback_wrapper;
}

/// Pratt parser.
pub const Parser = struct {
    /// The allocator to store parsed expressions in.
    allocator: std.mem.Allocator,
    /// The syntax used by this parser.
    syntax: *Syntax,
    /// Token stream being parsed.
    lexer: analysis.Lexer0,

    /// Alias for `SyntaxError`.
    pub const Error = SyntaxError;

    /// Create a new parser.
    pub fn init(
        allocator: std.mem.Allocator,
        syntax: *Syntax,
        lexer: analysis.Lexer0,
    ) Parser {
        return Parser{
            .allocator = allocator,
            .syntax = syntax,
            .lexer = lexer,
        };
    }


    /// Run the pratt algorithm at the current offset in the lexer stream.
    pub fn pratt(
        self: *Parser,
        binding_power: i64,
    ) Error!?Expr {
        var out: Expr = undefined;
        var err: SyntaxError = undefined;

        var lexer_save_state = self.lexer;

        const first_token = try self.lexer.next() orelse return null;
        log.debug("pratt: first token {}", .{first_token});

        const nuds = try self.syntax.findNuds(&first_token);

        if (nuds.len == 0) {
            log.debug("pratt: unexpected token {}, no valid nuds found", .{first_token});
            self.lexer = lexer_save_state;
            return error.UnexpectedToken;
        }

        var lhs = nuds: for (nuds) |nud| {
            if (nud.binding_power > binding_power) {
                log.debug("pratt: rejecting nud {s} of greater binding power than current", .{nud.name});
                self.lexer = lexer_save_state;
                continue :nuds;
            }

            const lexer_save_state_2 = self.lexer;

            switch (nud.invoke(.{self, nud.binding_power, first_token, &out, &err})) {
                .okay => {
                    log.debug("pratt: nud {s} accepted input", .{nud.name});
                    break :nuds out;
                },
                .panic => {
                    self.lexer = lexer_save_state;
                    log.debug("pratt: nud {s} for {} panicked", .{nud.name, first_token});
                    return err;
                },
                .reject => {
                    self.lexer = lexer_save_state_2;
                    log.debug("pratt: nud {s} for {} rejected", .{nud.name, first_token});
                    continue :nuds;
                },
            }
        } else {
            self.lexer = lexer_save_state;
            log.debug("pratt: unexpected token {}, no accepting nud found", .{first_token});
            return error.UnexpectedToken;
        };

        lexer_save_state = self.lexer;

        while (try self.lexer.next()) |curr_token| {
            log.debug("infix token {}", .{curr_token});

            const leds = try self.syntax.findLeds(&curr_token);

            if (leds.len == 0) {
                log.debug("pratt: unexpected token {}, no valid leds found", .{curr_token});
                self.lexer = lexer_save_state;
                return lhs;
            }

            leds: for (leds) |led|{
                if (led.binding_power > binding_power) {
                    log.debug("pratt: rejecting led {s} of greater binding power than current", .{led.name});
                    continue :leds;
                }

                const lexer_save_state_2 = self.lexer;
                switch (led.invoke(.{self, lhs, led.binding_power, curr_token, &out, &err})) {
                    .okay => {
                        log.debug("pratt: led {s} accepted input", .{led.name});
                        lhs = out;
                        break :leds;
                    },
                    .panic => {
                        self.lexer = lexer_save_state;
                        log.debug("pratt: led {s} for {} panicked", .{led.name, curr_token});
                        return err;
                    },
                    .reject => {
                        self.lexer = lexer_save_state_2;
                        log.debug("pratt: led {s} for {} rejected", .{led.name, curr_token});
                        continue :leds;
                    },
                }
            } else {
                self.lexer = lexer_save_state;
                log.debug("pratt: unexpected token {}, no accepting led found", .{curr_token});
                return lhs;
            }

            lexer_save_state = self.lexer;
        } else {
            log.debug("pratt: end of input", .{});
        }

        log.debug("pratt: exit", .{});

        return lhs;
    }
};

pub const basic_leaf_node_nud = createNud(
    "builtin_leaf",
    std.math.minInt(i16),
    .{ .standard = .{ .sequence = .any } },
    null, struct {
        pub fn basic_leaf_node_callback(
            _: *Parser,
            _: i16,
            token: analysis.Token,
        ) SyntaxError!?Expr {
            const s = token.data.sequence.asSlice();

            const first_char = utils.text.nthCodepoint(0, s) catch unreachable orelse unreachable;

            if (utils.text.isDecimal(first_char) and utils.text.isHexDigitStr(s)) {
                return Expr{
                    .location = token.location,
                    .type = ExprTypes.Int,
                    .token = token,
                    .operands = .empty,
                };
            } else if (utils.text.isAlphanumericStr(s)) {
                return Expr{
                    .location = token.location,
                    .type = ExprTypes.Identifier,
                    .token = token,
                    .operands = .empty,
                };
            } else {
                return null;
            }
        }
    }.basic_leaf_node_callback,
);

pub const whitespace_significance_led = createLed(
    "builtin_space_sig",
    std.math.maxInt(i16),
    .{ .standard = .{ .linebreak = .any } },
    null, struct {
        pub fn whitespace_significance_callback(
            parser: *Parser,
            first_stmt: Expr,
            bp: i16,
            token: analysis.Token,
        ) SyntaxError!?Expr {
            var buff: pl.ArrayList(Expr) = .empty;
            defer buff.deinit(parser.allocator);

            try buff.append(parser.allocator, first_stmt);

            switch (token.data.linebreak.i) {
                .none => {
                    log.debug("linebreak no indent", .{});
                },
                .indent => {
                    log.debug("linebreak indent accepted by indentation parser", .{});

                    const buffer = try parser.allocator.alloc(Expr, 1);

                    buffer[0] = try parser.pratt(bp) orelse {
                        log.err("linebreak indent block expected expression, got nothing", .{});
                        return error.UnexpectedToken;
                    };

                    const unindent = try parser.lexer.next() orelse {
                        log.err("linebreak indent block end expected unindent, got nothing", .{});
                        return error.UnexpectedEof;
                    };

                    if (unindent.tag != .linebreak) {
                        log.err("linebreak indent block end expected unindent, got: {}", .{unindent.tag});
                        return error.UnexpectedToken;
                    }

                    if (unindent.data.linebreak.i != .unindent) {
                        log.err("linebreak indent block end expected unindent, got: {}", .{unindent.data.linebreak.i});
                        return error.UnexpectedToken;
                    }

                    log.debug("linebreak indent block successfully parsed by indentation parser: {any}", .{buffer});

                    try buff.append(parser.allocator, Expr{
                        .location = token.location,
                        .type = ExprTypes.IndentedBlock,
                        .token = token,
                        .operands = common.Id.Buffer(Expr, .constant).fromSlice(buffer),
                    });
                },
                .unindent => {
                    log.debug("linebreak unindent rejected by indentation parser; this is a sentinel", .{});
                    return null;
                },
            }

            if (try parser.pratt(bp)) |second_stmt| {
                try buff.append(parser.allocator, second_stmt);
            }

            return Expr{
                .location = first_stmt.location,
                .type = ExprTypes.Stmts,
                .token = token,
                .operands = common.Id.Buffer(Expr, .constant).fromSlice(try buff.toOwnedSlice(parser.allocator)),
            };
        }
    }.whitespace_significance_callback,
);

test "parser_basic_integration" {
    const input =
        \\test
        \\    foo
        \\      1
        \\      2
        \\    bar
        \\
        \\
        ;
    const expected_output = "Stmts({ Identifier(test), IndentedBlock({ Stmts({ Identifier(foo), IndentedBlock({ Stmts({ Int(1), Int(2) }) }), Identifier(bar) }) }) })";

    var gpa = std.heap.DebugAllocator(.{}).init;
    const allocator = gpa.allocator();

    var syntax = Syntax.init(allocator);
    defer syntax.deinit();

    try syntax.bindNud(basic_leaf_node_nud);
    try syntax.bindLed(whitespace_significance_led);

    var parser = Parser.init(allocator, &syntax, try analysis.Lexer0.init(.{}, input));
    var expr = parser.pratt(std.math.maxInt(i16)) catch |err| {
        log.err("syntax error: {s}", .{@errorName(err)});
        return err;
    } orelse {
        log.err("expected a single expression, got nothing", .{});
        return error.UnexpectedEof;
    };
    defer expr.deinit(allocator);

    const output = try std.fmt.allocPrint(allocator, "{}", .{expr});
    defer allocator.free(output);

    try std.testing.expectEqualStrings(expected_output, output);
}
