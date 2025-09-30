//! Language agnostic pratt parser implementation.
const Parser = @This();

const std = @import("std");
const log = std.log.scoped(.parser);

const common = @import("common");

const analysis = @import("../analysis.zig");

test {
    // std.debug.print("semantic analysis for Parser\n", .{});
    std.testing.refAllDeclsRecursive(@This());
}

/// Errors that can occur in the parser.
pub const Error = error{
    /// The parser encountered an unexpected token.
    UnexpectedToken,
} || analysis.Lexer.Error;

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
        none_of: []const P,
        one_of: []const P,
        any_of: []const P,
        all_of: []const P,

        const Q = if (common.hasDecl(P, .QueryType)) P.QueryType else P;

        pub fn format(self: *const Self, writer: *std.io.Writer) !void {
            switch (self.*) {
                .none => try writer.print("none", .{}),
                .any => try writer.print("any", .{}),
                .standard => try writer.print("{any}", .{self.standard}),
                .inverted => try writer.print("inv({any})", .{self.inverted}),
                .none_of => try writer.print("none({any})", .{self.none_of}),
                .one_of => try writer.print("one({any})", .{self.one_of}),
                .any_of => try writer.print("any({any})", .{self.any_of}),
                .all_of => try writer.print("all({any})", .{self.all_of}),
            }
        }

        fn processCallback(self: *const Self, q: Q, comptime callback: fn (P, Q) bool) bool {
            // log.debug("processing {} with {}", .{q, self});
            switch (self.*) {
                .none => return false,
                .any => return true,
                .standard => |my_p| return callback(my_p, q),
                .inverted => |my_p| return !callback(my_p, q),
                .none_of => |my_ps| {
                    for (my_ps) |my_p| {
                        if (callback(my_p, q)) {
                            return false;
                        }
                    }

                    return true;
                },
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
                common.Buffer.short(u8, .constant) => struct {
                    pub fn callback(a: P, b: Q) bool {
                        return std.mem.eql(u8, a.asSlice(), b.asSlice());
                    }
                },
                TokenPattern => struct {
                    pub fn callback(a: P, b: Q) bool {
                        if (@as(analysis.Token.Type, a) != b.tag) return false;

                        return switch (a) {
                            .sequence => |p| p.process(b.data.sequence),
                            .linebreak => true,
                            .indentation => |p| p.process(b.data.indentation),
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

            // log.debug("process result: {s}", .{if (result) "accept" else "reject"});

            return result;
        }
    };
}

pub const TokenPattern = union(analysis.Token.Type) {
    pub const QueryType = *const analysis.Token;
    sequence: PatternModifier(common.Buffer.short(u8, .constant)),
    linebreak,
    indentation: PatternModifier(analysis.Token.IndentationDelta),
    special: PatternModifier(struct {
        const Self = @This();
        pub const QueryType = @FieldType(analysis.Token.Data, "special");
        escaped: PatternModifier(bool),
        punctuation: PatternModifier(analysis.Token.Punctuation),

        pub fn format(self: *const Self, writer: *std.io.Writer) !void {
            try writer.print("{f}, {f}", .{ self.escaped, self.punctuation });
        }
    }),

    pub fn format(self: *const TokenPattern, writer: *std.io.Writer) !void {
        switch (self.*) {
            .sequence => try writer.print("s⟨{f}⟩", .{self.sequence}),
            .linebreak => try writer.print("b⟨~⟩", .{}),
            .indentation => try writer.print("i⟨{f}⟩", .{self.indentation}),
            .special => try writer.print("p⟨{f}⟩", .{self.special}),
        }
    }
};

fn FunctionType(comptime Args: type, comptime Ret: type, comptime calling_conv: std.builtin.CallingConvention) type {
    comptime {
        const args = std.meta.fields(Args);

        var params = [1]std.builtin.Type.Fn.Param{.{
            .type = undefined,
            .is_generic = false,
            .is_noalias = false,
        }} ** args.len;

        for (args, 0..) |arg, i| {
            params[i].type = arg.type;
        }

        return @Type(std.builtin.Type{
            .@"fn" = .{ .calling_convention = calling_conv, .return_type = Ret, .is_generic = false, .is_var_args = false, .params = &params },
        });
    }
}

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
                const closure_args = .{self.userdata} ++ args;
                return @call(.auto, @as(*const FunctionType(@TypeOf(closure_args), ParserSignal, .c), @ptrCast(self.callback)), closure_args);
            }
        };

        entries: std.MultiArrayList(Pattern(T)) = .empty,
        query_cache: common.ArrayList(QueryResult) = .empty,

        pub const empty = Self{ .entries = .empty };

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
        }

        pub fn bindPattern(
            self: *Self,
            allocator: std.mem.Allocator,
            pattern: Pattern(T),
        ) error{OutOfMemory}!void {
            try self.entries.append(allocator, pattern);
        }

        /// Find the patterns matching a given token, if any.
        pub fn findPatterns(
            self: *const PatternSet(T),
            allocator: std.mem.Allocator,
            binding_power: i16,
            token: *const analysis.Token,
        ) error{OutOfMemory}![]const QueryResult {
            const patterns = self.entries.items(.token);
            const bps = self.entries.items(.binding_power);
            const userdata = self.entries.items(.userdata);
            const callbacks = self.entries.items(.callback);
            const names = self.entries.items(.name);

            @constCast(self).query_cache.clearRetainingCapacity();

            for (patterns, 0..) |*pattern, index| {
                if (bps[index] < binding_power) {
                    // log.debug("rejecting pattern {s} of lesser binding power ({}) than current ({})", .{names[index], bps[index], binding_power});
                    continue;
                }

                if (!pattern.process(token)) {
                    // log.debug("pattern {s} rejected token {}", .{names[index], token});
                    continue;
                }

                try @constCast(self).query_cache.append(allocator, .{ .name = names[index], .binding_power = bps[index], .userdata = userdata[index], .callback = callbacks[index] });
            }

            std.mem.sort(QueryResult, self.query_cache.items, {}, struct {
                pub fn query_result_sort(_: void, a: QueryResult, b: QueryResult) bool {
                    return a.binding_power < b.binding_power;
                }
            }.query_result_sort);

            return self.query_cache.items;
        }
    };
}

/// Defines the possible syntax accepted by a Parser.
pub const Syntax = struct {
    /// Allocator providing all Syntax memory.
    allocator: std.mem.Allocator,

    /// Nud patterns for known token types.
    nuds: PatternSet(NudCallbackMarker) = .empty,
    /// Led patterns for known token types.
    leds: PatternSet(LedCallbackMarker) = .empty,

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
    pub fn findNuds(self: *const Syntax, bp: i16, token: *const analysis.Token) error{OutOfMemory}![]const PatternSet(NudCallbackMarker).QueryResult {
        return self.nuds.findPatterns(self.allocator, bp, token);
    }

    /// Find the leds matching a given token, if any.
    pub fn findLeds(self: *const Syntax, bp: i16, token: *const analysis.Token) error{OutOfMemory}![]const PatternSet(LedCallbackMarker).QueryResult {
        return self.leds.findPatterns(self.allocator, bp, token);
    }

    /// Parse a source string using this syntax.
    pub fn createParser(
        self: *const Syntax,
        allocator: std.mem.Allocator,
        lexer_settings: analysis.Lexer.Settings,
        src: []const u8,
        parser_settings: Parser.Settings,
    ) Error!Parser {
        const lexer = try analysis.Lexer.lexWithPeek(lexer_settings, src);
        return Parser.init(allocator, self, lexer, parser_settings);
    }
};

const NudCallbackMarker = fn () callconv(.c) void;

const LedCallbackMarker = fn () callconv(.c) void;

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
pub const Nud = Pattern(NudCallbackMarker);

/// A led is a function/closure that takes a parser and a token, as well as a left hand side expression,
/// and parses some subset of the source code as an infix or postfix expression.
pub const Led = Pattern(LedCallbackMarker);

/// Expected inputs:
/// * `..., null, fn (*Parser, i16, analysis.Token) Error!?Expr`
/// * `..., *T, fn (*T, *Parser, i16, analysis.Token) Error!?Expr`
/// * `..., _, *const fn ..`
pub fn createNud(name: []const u8, binding_power: i16, token: PatternModifier(TokenPattern), userdata: anytype, callback: anytype) Nud {
    const Userdata = comptime @TypeOf(userdata);
    const uInfo = comptime @typeInfo(Userdata);
    return Nud{
        .name = name,
        .token = token,
        .binding_power = binding_power,
        .userdata = if (comptime uInfo == .null) null else @ptrCast(userdata),
        .callback = wrapNudCallback(if (comptime uInfo == .null) void else Userdata, callback),
    };
}

/// Expected inputs:
/// * `..., null, fn (*Parser, Expr, i16, analysis.Token) Error!?Expr`
/// * `..., *T, fn (*T, *Parser, Expr, i16, analysis.Token) Error!?Expr`
/// * `..., _, *const fn ..`
pub fn createLed(name: []const u8, binding_power: i16, token: PatternModifier(TokenPattern), userdata: anytype, callback: anytype) Led {
    const Userdata = comptime @TypeOf(userdata);
    const uInfo = comptime @typeInfo(Userdata);
    return Led{
        .name = name,
        .token = token,
        .binding_power = binding_power,
        .userdata = if (comptime uInfo == .null) null else @ptrCast(userdata),
        .callback = wrapLedCallback(if (comptime uInfo == .null) void else Userdata, callback),
    };
}

/// Expected inputs:
/// * `void, fn (*Parser, i16, analysis.Token) Error!?Expr`
/// * `T, fn (*T, *Parser, i16, analysis.Token) Error!?Expr`
/// * `_, *const fn ..`
pub fn wrapNudCallback(comptime Userdata: type, callback: anytype) *const NudCallbackMarker {
    return @ptrCast(&struct {
        pub fn nud_callback_wrapper(
            userdata: ?*anyopaque,
            parser: *Parser,
            bp: i16,
            token: *analysis.Token,
            out: *analysis.SyntaxTree,
            err: *Error,
        ) callconv(.c) ParserSignal {
            const result =
                if (comptime Userdata != void)
                    @call(.auto, callback, .{userdata} ++ .{ parser, bp, token.* })
                else
                    @call(.auto, callback, .{ parser, bp, token.* });

            const maybe = result catch |e| {
                err.* = e;
                return .panic;
            };

            out.* = maybe orelse {
                return .reject;
            };

            return .okay;
        }
    }.nud_callback_wrapper);
}

/// Expected inputs:
/// * `void, fn (*Parser, Expr, i16, analysis.Token) Error!?Expr`
/// * `T, fn (*T, *Parser, Expr, i16, analysis.Token) Error!?Expr`
/// * `_, *const fn ..`
pub fn wrapLedCallback(comptime Userdata: type, callback: anytype) *const LedCallbackMarker {
    return @ptrCast(&struct {
        pub fn led_callback_wrapper(
            userdata: ?*anyopaque,
            parser: *Parser,
            lhs: *analysis.SyntaxTree,
            bp: i16,
            token: *analysis.Token,
            out: *analysis.SyntaxTree,
            err: *Error,
        ) callconv(.c) ParserSignal {
            const result =
                if (comptime Userdata != void)
                    @call(.auto, callback, .{userdata} ++ .{ parser, lhs.*, bp, token.* })
                else
                    @call(.auto, callback, .{ parser, lhs.*, bp, token.* });

            const maybe = result catch |e| {
                err.* = e;
                return .panic;
            };

            out.* = maybe orelse {
                return .reject;
            };

            return .okay;
        }
    }.led_callback_wrapper);
}

/// The allocator to store parsed expressions in.
allocator: std.mem.Allocator,
/// The syntax used by this parser.
syntax: *const Syntax,
/// analysis.Token stream being parsed.
lexer: analysis.Lexer.Peekable,
/// Settings for this parser.
settings: Settings,

pub const Settings = struct {
    /// Whether to ignore whitespace tokens when parsing; Default: false.
    ignore_space: bool = false,
    /// The name of the source file being parsed.
    source_name: []const u8 = "anonymous",
};

/// Create a new parser.
pub fn init(
    allocator: std.mem.Allocator,
    syntax: *const Syntax,
    lexer: analysis.Lexer.Peekable,
    settings: Settings,
) Parser {
    return Parser{
        .allocator = allocator,
        .syntax = syntax,
        .lexer = lexer,
        .settings = settings,
    };
}

pub fn isEof(self: *Parser) bool {
    return self.lexer.isEof();
}

pub fn parseNud(self: *Parser, binding_power: i16, token: analysis.Token) Error!?analysis.SyntaxTree {
    const nuds = try self.syntax.findNuds(binding_power, &token);

    log.debug("pratt: found {} nuds", .{nuds.len});

    if (nuds.len == 0) {
        log.debug("pratt: unexpected token {f}, no valid nuds found", .{token});
        return null;
    }

    var out: analysis.SyntaxTree = undefined;
    var err: Error = undefined;
    const save_state = self.lexer;

    nuds: for (nuds) |nud| {
        switch (nud.invoke(.{ self, nud.binding_power, &token, &out, &err })) {
            .okay => {
                log.debug("pratt: nud {s} accepted input", .{nud.name});
                return out;
            },
            .panic => {
                log.debug("pratt: nud {s} for {f} panicked", .{ nud.name, token });
                return err;
            },
            .reject => {
                log.debug("restoring saved state", .{});
                self.lexer = save_state;
                log.debug("pratt: nud {s} for {f} rejected", .{ nud.name, token });
                continue :nuds;
            },
        }
    } else {
        log.debug("pratt: all nuds rejected token {f}", .{token});
        return null;
    }
}

pub fn parseLed(self: *Parser, binding_power: i16, token: analysis.Token, lhs: analysis.SyntaxTree) Error!?analysis.SyntaxTree {
    const leds = try self.syntax.findLeds(binding_power, &token);

    log.debug("pratt: found {} leds", .{leds.len});

    if (leds.len == 0) {
        log.debug("pratt: unexpected token {f}, no valid leds found", .{token});
        return null;
    }

    var out: analysis.SyntaxTree = undefined;
    var err: Error = undefined;

    const save_state = self.lexer;

    leds: for (leds) |led| {
        switch (led.invoke(.{ self, &lhs, led.binding_power, &token, &out, &err })) {
            .okay => {
                log.debug("pratt: led {s} accepted input", .{led.name});
                return out;
            },
            .panic => {
                log.debug("pratt: led {s} for {f} panicked", .{ led.name, token });
                return err;
            },
            .reject => {
                log.debug("restoring saved state", .{});
                self.lexer = save_state;
                log.debug("pratt: led {s} for {f} rejected", .{ led.name, token });
                continue :leds;
            },
        }
    } else {
        log.debug("pratt: all leds rejected {f}", .{token});
        return null;
    }
}

/// Run the pratt algorithm and attempt to parse the entire source bound in the lexer.
///
/// * Returns null if the source is empty.
/// * Returns an error if we cannot parse the entire source.
pub fn parse(self: *Parser) Error!?analysis.SyntaxTree {
    const out = self.pratt(std.math.minInt(i16));

    if (std.debug.runtime_safety) {
        log.debug("getCst: parser result: {!?f}", .{out});

        if (std.meta.isError(out) or (try out) == null or !self.isEof()) {
            log.debug("getCst: parser result was null or error, or did not consume input {any} {any} {any}", .{ std.meta.isError(out), if (!std.meta.isError(out)) (try out) == null else false, !self.isEof() });

            if (self.lexer.peek()) |maybe_cached_token| {
                if (maybe_cached_token) |cached_token| {
                    log.debug("getCst: unused token in lexer cache {f}: `{f}`", .{ self.lexer.inner.location, cached_token });
                }
            } else |err| {
                log.debug("syntax error: {s}", .{@errorName(err)});
            }

            const rem = self.lexer.inner.source[self.lexer.inner.location.buffer..];

            if (self.lexer.inner.iterator.peek_cache) |cached_char| {
                log.debug("getCst: unused character in lexer cache {f}: `{u}` ({x})", .{ self.lexer.inner.location, cached_char, cached_char });
            } else if (rem.len > 0) {
                log.debug("getCst: unexpected input after parsing {f}: `{s}` ({x})", .{ self.lexer.inner.location, rem, rem });
            }
        }
    }

    return try out;
}

/// Run the pratt algorithm at the current offset in the lexer stream.
pub fn pratt(
    self: *Parser,
    binding_power: i16,
) Error!?analysis.SyntaxTree {
    var save_state = self.lexer;
    const first_token = try self.lexer.peek() orelse return null;

    if (self.settings.ignore_space) {
        while (first_token.tag == .linebreak or first_token.tag == .indentation) {
            if (self.settings.ignore_space) {
                log.debug("pratt: ignoring whitespace {f}", .{first_token});
                try self.lexer.advance();
                _ = try self.lexer.peek() orelse {
                    log.debug("pratt: input is all whitespace, returning null", .{});
                    return null;
                };
            } else {
                break;
            }
        }
    }

    log.debug("pratt: first token {f}; bp: {d}", .{ first_token, binding_power });

    var lhs = lhs: while (try self.lexer.peek()) |nth_first_token| {
        const x = try self.parseNud(binding_power, nth_first_token) orelse {
            log.debug("restoring saved state", .{});
            self.lexer = save_state;
            log.debug("pratt: reached end of recognized input while consuming (possibly ignored) nud(s)", .{});
            return null;
        };

        if (x.type == .null) {
            log.debug("pratt: nud returned null, reiterating loop (assumes nud function advanced)", .{});
            std.debug.assert(x.operands.len == 0);

            continue :lhs;
        } else {
            break :lhs x;
        }
    } else {
        log.debug("restoring saved state", .{});
        self.lexer = save_state;
        log.debug("pratt: reached end of recognized input while consuming (possibly ignored) nud(s)", .{});
        return null;
    };
    errdefer lhs.deinit(self.allocator);

    save_state = self.lexer;

    while (try self.lexer.peek()) |x| {
        var curr_token = x;

        if (self.settings.ignore_space) {
            while (curr_token.tag == .linebreak or curr_token.tag == .indentation) {
                if (self.settings.ignore_space) {
                    log.debug("pratt: ignoring whitespace token {f}", .{curr_token});
                    try self.lexer.advance();
                    curr_token = try self.lexer.peek() orelse {
                        log.debug("pratt: remaining input is all whitespace, returning lhs", .{});
                        return lhs;
                    };
                } else {
                    break;
                }
            }
        }

        log.debug("pratt: infix {f}", .{curr_token});

        if (try self.parseLed(binding_power, curr_token, lhs)) |new_lhs| {
            log.debug("pratt: infix {f} accepted", .{curr_token});
            save_state = self.lexer;
            lhs = new_lhs;
        } else {
            log.debug("restoring saved state", .{});
            self.lexer = save_state;
            log.debug("pratt: {f} rejected as infix", .{curr_token});
            break;
        }
    } else {
        log.debug("pratt: end of input", .{});
    }

    log.debug("pratt: exit", .{});

    return lhs;
}
