const std = @import("std");
const log = std.log.scoped(.syntactic_analysis);
const analysis = @import("../analysis.zig");
const pl = @import("platform");
const common = @import("common");
const utils = @import("utils");

/// Errors that can occur in the parser.
pub const SyntaxError = error {
    /// The parser encountered an unexpected token.
    UnexpectedToken,
} || analysis.LexicalError;



/// A concrete syntax tree node yielded by the meta language parser.
pub const SyntaxTree = extern struct {
    /// The source location where the expression began.
    location: analysis.Location,
    /// The type of the expression.
    type: common.Id.of(SyntaxTree),
    /// The token that generated this expression.
    token: analysis.Token,
    /// Subexpressions of this expression, if any.
    operands: common.Id.Buffer(SyntaxTree, .constant),

    /// Deinitialize the sub-tree of this expression and free all memory allocated for it.
    pub fn deinit(self: *SyntaxTree, allocator: std.mem.Allocator) void {
        const xs = @constCast(self.operands.asSlice());
        for (xs) |*x| x.deinit(allocator);
        if (xs.len != 0) {
            // empty buffer != empty slice
            allocator.free(xs);
        }
    }

    /// `std.fmt` impl
    pub fn format(self: *const SyntaxTree, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.operands.len == 0) {
            try writer.print("﴾{}, {}﴿", .{@intFromEnum(self.type), self.token});
        } else {
            try writer.print("﴾{}, {}, {any}﴿", .{@intFromEnum(self.type), self.token, self.operands.asSlice()});
        }
    }
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
        none_of: []const P,
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
                .none_of => try writer.print("none({any})", .{self.none_of}),
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

            log.debug("process result: {s}", .{if (result) "accept" else "reject"});

            return result;
        }
    };
}

pub const TokenPattern = union(analysis.TokenType) {
    pub const QueryType = *const analysis.Token;
    sequence: PatternModifier(common.Id.Buffer(u8, .constant)),
    linebreak: PatternModifier(u32),
    indentation: PatternModifier(analysis.IndentationDelta),
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
            .indentation => try writer.print("i⟨{}⟩", .{self.indentation}),
            .special => try writer.print("p⟨{}⟩", .{self.special}),
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

        return @Type(std.builtin.Type {
            .@"fn" = .{
                .calling_convention = calling_conv,
                .return_type = Ret,
                .is_generic = false,
                .is_var_args = false,
                .params = &params
            },
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
                return @call(.auto, @as(*const FunctionType(@TypeOf(closure_args), ParserSignal, .C), @ptrCast(self.callback)), closure_args);
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
                        return a.binding_power < b.binding_power;
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
    nuds: PatternSet(NudCallbackMarker) = .empty,
    /// Led patterns for known token types.
    leds: PatternSet(LedCallbackMarker) = .empty,
    juxt: ?Juxt = null,

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

    pub fn bindJuxt(
        self: *Syntax,
        juxt: Juxt,
    ) ?Juxt {
        const old = self.juxt;
        self.juxt = juxt;
        return old;
    }

    /// Find the nuds matching a given token, if any.
    pub fn findNuds(self: *const Syntax, token: *const analysis.Token) error{OutOfMemory}![]const PatternSet(NudCallbackMarker).QueryResult {
        return self.nuds.findPatterns(self.allocator, token);
    }

    /// Find the leds matching a given token, if any.
    pub fn findLeds(self: *const Syntax, token: *const analysis.Token) error{OutOfMemory}![]const PatternSet(LedCallbackMarker).QueryResult {
        return self.leds.findPatterns(self.allocator, token);
    }

    /// Parse a source string using this syntax.
    pub fn createParser(
        self: *const Syntax,
        allocator: std.mem.Allocator,
        lexer_settings: analysis.LexerSettings,
        source: []const u8,
    ) SyntaxError!Parser {
        const lexer = try analysis.Lexer0.init(lexer_settings, source);
        return Parser.init(allocator, self, lexer);
    }
};

const NudCallbackMarker = fn () callconv(.C) void;

const LedCallbackMarker = fn () callconv(.C) void;

const JuxtCallbackMarker = fn () callconv(.C) void;
// pub const JuxtCallback = fn (
//     userdata: ?*anyopaque,
//     parser: *Parser,
//     lhs: SyntaxTree, rhs: SyntaxTree,
//     err: *SyntaxError, out: *SyntaxTree,
// ) callconv(.C) ParserSignal;

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

pub const Juxt = struct {
    /// The name to refer to this pattern by in debug messages.
    name: []const u8,
    /// Optional user data to pass to the callback.
    userdata: ?*anyopaque,
    /// The callback to invoke when this pattern is matched.
    callback: *const JuxtCallbackMarker,

    pub fn invoke(
        self: *const Juxt,
        args: anytype,
    ) ParserSignal {
        const closure_args = .{self.userdata} ++ args;
        return @call(.auto, @as(*const FunctionType(@TypeOf(closure_args), ParserSignal, .C), @ptrCast(self.callback)), closure_args);
    }
};

pub fn createJuxt(name: []const u8, userdata: anytype, callback: anytype) Juxt {
    const Userdata = comptime @TypeOf(userdata);
    const uInfo = comptime @typeInfo(Userdata);
    return Juxt {
        .name = name,
        .userdata = if (comptime uInfo == .null) null else @ptrCast(userdata),
        .callback = wrapJuxtCallback(if (comptime uInfo == .null) void else Userdata, callback),
    };
}

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
        .callback = wrapNudCallback(if (comptime uInfo == .null) void else Userdata, callback),
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
        .callback = wrapLedCallback(if (comptime uInfo == .null) void else Userdata, callback),
    };
}

pub fn wrapJuxtCallback(comptime Userdata: type, callback: anytype) *const JuxtCallbackMarker {
    return @ptrCast(&struct {
        pub fn juxt_callback_wrapper(
            userdata: ?*anyopaque,
            parser: *Parser,
            lhs: SyntaxTree,
            rhs: SyntaxTree,
            err: *SyntaxError,
            out_tree: *SyntaxTree,
            out_bp: *?i16,
        ) callconv(.c) ParserSignal {
            const result = invoke: {
                if (comptime Userdata != void) {
                    log.debug("invoking juxt callback with userdata", .{});
                    break :invoke @call(.auto, callback, .{userdata, parser, lhs, rhs});
                } else {
                    log.debug("invoking juxt callback without userdata", .{});
                    break :invoke @call(.auto, callback, .{parser, lhs, rhs});
                }
            };

            const maybe = result catch |e| {
                err.* = e;
                return .panic;
            };

            const tree, const bp = maybe orelse {
                return .reject;
            };

            out_tree.* = tree;
            out_bp.* = bp;

            return .okay;
        }
    }.juxt_callback_wrapper);
}

/// Expected inputs:
/// * `void, fn (*Parser, i16, Token) SyntaxError!?Expr`
/// * `T, fn (*T, *Parser, i16, Token) SyntaxError!?Expr`
/// * `_, *const fn ..`
pub fn wrapNudCallback(comptime Userdata: type, callback: anytype) *const NudCallbackMarker {
    return @ptrCast(&struct {
        pub fn nud_callback_wrapper(
            userdata: ?*anyopaque,
            parser: *Parser,
            bp: i16,
            token: analysis.Token,
            out: *SyntaxTree,
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
    }.nud_callback_wrapper);
}

/// Expected inputs:
/// * `void, fn (*Parser, Expr, i16, Token) SyntaxError!?Expr`
/// * `T, fn (*T, *Parser, Expr, i16, Token) SyntaxError!?Expr`
/// * `_, *const fn ..`
pub fn wrapLedCallback(comptime Userdata: type, callback: anytype) *const LedCallbackMarker {
    return @ptrCast(&struct {
        pub fn led_callback_wrapper(
            userdata: ?*anyopaque,
            parser: *Parser,
            lhs: SyntaxTree,
            bp: i16,
            token: analysis.Token,
            out: *SyntaxTree,
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
    }.led_callback_wrapper);
}

/// Pratt parser.
pub const Parser = struct {
    /// The allocator to store parsed expressions in.
    allocator: std.mem.Allocator,
    /// The syntax used by this parser.
    syntax: *const Syntax,
    /// Token stream being parsed.
    lexer: analysis.Lexer0,

    /// Alias for `SyntaxError`.
    pub const Error = SyntaxError;

    /// Create a new parser.
    pub fn init(
        allocator: std.mem.Allocator,
        syntax: *const Syntax,
        lexer: analysis.Lexer0,
    ) Parser {
        return Parser{
            .allocator = allocator,
            .syntax = syntax,
            .lexer = lexer,
        };
    }

    pub fn isEof(self: *Parser) bool {
        return self.lexer.isEof();
    }

    pub fn parseNud(self: *Parser, binding_power: i16, token: analysis.Token) Error!?SyntaxTree {
        const nuds = try self.syntax.findNuds(&token);

        log.debug("pratt: found {} nuds", .{nuds.len});

        if (nuds.len == 0) {
            log.debug("pratt: unexpected token {}, no valid nuds found", .{token});
            return null;
        }

        var out: SyntaxTree = undefined;
        var err: SyntaxError = undefined;
        const lexer_save_state = self.lexer;

        nuds: for (nuds) |nud| {
            if (nud.binding_power < binding_power) {
                log.debug("pratt: rejecting nud {s} of lesser binding power ({}) than current ({})", .{nud.name, nud.binding_power, binding_power});
                self.lexer = lexer_save_state;
                continue :nuds;
            }

            switch (nud.invoke(.{self, nud.binding_power, token, &out, &err})) {
                .okay => {
                    log.debug("pratt: nud {s} accepted input", .{nud.name});
                    return out;
                },
                .panic => {
                    self.lexer = lexer_save_state;
                    log.debug("pratt: nud {s} for {} panicked", .{nud.name, token});
                    return err;
                },
                .reject => {
                    self.lexer = lexer_save_state;
                    log.debug("pratt: nud {s} for {} rejected", .{nud.name, token});
                    continue :nuds;
                },
            }
        } else {
            log.debug("pratt: all nuds rejected token {}", .{token});
            return null;
        }
    }

    pub fn parseLed(self: *Parser, binding_power: i16, token: analysis.Token, lhs: SyntaxTree) Error!?SyntaxTree {
        const leds = try self.syntax.findLeds(&token);

        log.debug("pratt: found {} leds", .{leds.len});

        if (leds.len == 0) {
            log.debug("pratt: unexpected token {}, no valid leds found", .{token});
            return null;
        }

        var out: SyntaxTree = undefined;
        var err: SyntaxError = undefined;

        const lexer_save_state = self.lexer;

        leds: for (leds) |led| {
            if (led.binding_power < binding_power) {
                log.debug("pratt: rejecting led {s} of lesser binding power ({}) than current ({})", .{led.name, led.binding_power, binding_power});
                continue :leds;
            }

            switch (led.invoke(.{self, lhs, led.binding_power, token, &out, &err})) {
                .okay => {
                    log.debug("pratt: led {s} accepted input", .{led.name});
                    return out;
                },
                .panic => {
                    self.lexer = lexer_save_state;
                    log.debug("pratt: led {s} for {} panicked", .{led.name, token});
                    return err;
                },
                .reject => {
                    self.lexer = lexer_save_state;
                    log.debug("pratt: led {s} for {} rejected", .{led.name, token});
                    continue :leds;
                },
            }
        } else {
            log.debug("pratt: all leds rejected token {}", .{token});
            return null;
        }
    }

    pub fn parseJuxt(
        self: *Parser,
        lhs: SyntaxTree,
        rhs: SyntaxTree,
    ) Error!?struct { SyntaxTree, ?i16 } {
        const juxt = self.syntax.juxt orelse {
            log.debug("pratt: unexpected juxtaposition ({} {}), no juxt pattern bound", .{lhs, rhs});
            return null;
        };

        var out_tree: SyntaxTree = undefined;
        var out_bp: ?i16 = null;
        var err: SyntaxError = undefined;
        const lexer_save_state = self.lexer;

        switch (juxt.invoke(.{self, lhs, rhs, &err, &out_tree, &out_bp})) {
            .okay => {
                return .{ out_tree, out_bp };
            },
            .panic => {
                self.lexer = lexer_save_state;
                return err;
            },
            .reject => {
                self.lexer = lexer_save_state;
                return null;
            },
        }
    }

    /// Run the pratt algorithm at the current offset in the lexer stream.
    pub fn pratt(
        self: *Parser,
        binding_power: i16,
    ) Error!?SyntaxTree {
        var current_bp = binding_power;
        const first_token = try self.lexer.next() orelse return null;
        log.debug("pratt: first token {}; bp: {}", .{first_token, current_bp});

        var save_state = self.lexer;

        var lhs = try self.parseNud(current_bp, first_token) orelse {
            self.lexer = save_state;
            return null;
        };
        errdefer lhs.deinit(self.allocator);

        save_state = self.lexer;

        while (try self.lexer.next()) |curr_token| {
            log.debug("pratt: infix token {}", .{curr_token});

            if (try self.parseLed(current_bp, curr_token, lhs)) |new_lhs| {
                log.debug("pratt: infix token {} accepted", .{curr_token});
                save_state = self.lexer;
                lhs = new_lhs;
            } else {
                log.debug("pratt: token {} rejected as infix; trying nud juxtaposition", .{curr_token});

                const rhs = try self.parseNud(current_bp, curr_token) orelse {
                    log.debug("pratt: token {} rejected as infix and nud; ending loop with lhs {}", .{curr_token, lhs});
                    self.lexer = save_state;
                    return lhs;
                };

                const new_lhs, const maybe_new_bp = try self.parseJuxt(lhs, rhs) orelse {
                    log.debug("pratt: token {} rejected as infix and nud; ending loop with lhs {}", .{curr_token, lhs});
                    self.lexer = save_state;
                    return lhs;
                };

                lhs = new_lhs;
                if (maybe_new_bp) |bp| {
                    log.debug("pratt: juxtaposition accepted as {}; with new bp {}", .{new_lhs, current_bp});
                    current_bp = bp;
                } else {
                    log.debug("pratt: juxtaposition accepted as {}; with null bp", .{lhs});
                }

                save_state = self.lexer;
            }
        } else {
            log.debug("pratt: end of input", .{});
        }

        log.debug("pratt: exit", .{});

        return lhs;
    }
};
