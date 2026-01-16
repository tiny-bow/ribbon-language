//! Defines a Ribbon module. This is the root structure parsed from a .rmod file, or inline within a .rpkg file.
//! In-memory representation of a parsed module definition, and the cst parser to construct it.

const RMod = @This();

const std = @import("std");
const log = std.log.scoped(.module_def);

const common = @import("common");
const analysis = @import("analysis");
const ir = @import("ir");

const ml = @import("../meta_language.zig");

test {
    // std.debug.print("semantic analysis for RMod\n", .{});
    std.testing.refAllDecls(@This());
}

/// The module's canonical name.
name: []const u8 = "untitled",
/// The module definition's (.rmod or inline) source tracking location; may be absolute or relative depending on context.
source: analysis.Source = .anonymous,
/// The module's globally unique identifier, generated canonically from its dependency and source path.
guid: ir.Module.GUID = .invalid,
/// Whether this module is directly accessible to other modules outside its package.
visibility: Visibility = .internal,
/// Modules imported by this module.
imports: []const Import.Aliased = &.{},
/// Language extensions used by this module, which must be compiled prior to this module.
extensions: []const Import.Extension = &.{},
/// All source files that are part of this module. Paths may be absolute or relative depending on context.
/// Source files are unordered and all contribute to a single module context.
inputs: []const []const u8 = &.{},

/// Defines whether a module is internal to its package or exported for use by other packages.
pub const Visibility = enum {
    /// The module is only directly accessible within its own package.
    internal,
    /// The module is directly accessible to other packages that depend on its package.
    exported,
};

/// References another module for import into a module definition.
pub const Import = struct {
    /// The package name containing the module, or null for the root package.
    package: ?[]const u8 = null,
    /// The module's canonical name as exported from its package.
    module: []const u8,

    /// An imported module, optionally with an alias.
    pub const Aliased = struct {
        /// The imported module.
        import: Import,
        /// An optional alias for the imported module to be referred to by, within the importing module.
        alias: ?[]const u8 = null,
    };

    /// An imported language extension used by a module.
    ///
    /// Extensions are different from regular imports in a few ways:
    /// 1. They must be compiled prior to the module that uses them, because they may be run at compile time.
    /// 2. They may not define cyclic dependencies with other extensions or modules.
    /// 3. They contain both the module import information and the name of the extension within that module.
    pub const Extension = struct {
        /// The imported module containing the extension.
        import: Import,
        /// The name of the extension within the imported module.
        name: []const u8,
    };
};

pub fn deinit(self: *RMod, allocator: std.mem.Allocator) void {
    common.todo(noreturn, .{ self, allocator });
}

/// Parse a module definition language source string to an `RMod`.
/// * Returns null if the source is empty.
/// * Returns an error if we cannot parse the entire source.
pub fn parseSource(
    allocator: std.mem.Allocator,
    lexer_settings: analysis.Lexer.Settings,
    source_name: []const u8,
    src: []const u8,
) (analysis.Parser.Error || error{ InvalidString, InvalidEscape, InvalidModuleDefinition } || std.io.Writer.Error)!?RMod {
    var parser = try getRModParser(allocator, lexer_settings, source_name, src);
    var cst = try parser.parse() orelse return null;
    defer cst.deinit(allocator);

    return try parseCst(allocator, src, &cst);
}

/// Parses a `.rmod` Concrete Syntax Tree into a `RMod` struct.
pub fn parseCst(allocator: std.mem.Allocator, source: []const u8, cst: *const analysis.SyntaxTree) !RMod {
    var def = RMod{
        .source = cst.source,
    };
    errdefer def.deinit(allocator);

    if (cst.type != types.Module) {
        log.err("Expected root of rmod CST to be a Module node, found {f}", .{cst.type});
        return error.InvalidModuleDefinition;
    }

    const module_operands = cst.operands.asSlice();
    if (module_operands.len != 2) return error.InvalidModuleDefinition;

    // 1. Parse module name
    const name_cst = module_operands[0];
    if (name_cst.type != types.Identifier) return error.InvalidModuleDefinition;
    def.name = try allocator.dupe(u8, name_cst.token.data.sequence.asSlice());

    // 2. Parse module body (a sequence of assignments)
    const body_cst = module_operands[1];
    // Body is a Block -> Seq
    if (body_cst.type != types.Block or body_cst.operands.len != 1) return error.InvalidModuleDefinition;
    const seq_cst = body_cst.operands.asSlice()[0];
    if (seq_cst.type != types.Seq) return error.InvalidModuleDefinition;

    for (seq_cst.operands.asSlice()) |*assignment_cst| {
        if (assignment_cst.type != types.Assign) return error.InvalidModuleDefinition;
        if (assignment_cst.operands.len != 2) return error.InvalidModuleDefinition;

        const key_cst = &assignment_cst.operands.asSlice()[0];
        const value_cst = &assignment_cst.operands.asSlice()[1];

        if (key_cst.type != types.Identifier) return error.InvalidModuleDefinition;
        const key = key_cst.token.data.sequence.asSlice();

        if (std.mem.eql(u8, key, "inputs")) {
            try parseSourceList(allocator, source, value_cst, &def.inputs);
        } else if (std.mem.eql(u8, key, "imports")) {
            try parseImportList(allocator, source, value_cst, &def.imports);
        } else if (std.mem.eql(u8, key, "extensions")) {
            try parseExtensionList(allocator, source, value_cst, &def.extensions);
        } else {
            log.warn("Unknown key in .rmod file: {s}", .{key});
        }
    }

    return def;
}

fn parseSourceList(allocator: std.mem.Allocator, source: []const u8, value_cst: *const analysis.SyntaxTree, list: *[]const []const u8) !void {
    // Expects Block -> List
    if (value_cst.type != types.Block or value_cst.operands.len != 1) return error.InvalidModuleDefinition;
    const list_cst = value_cst.operands.asSlice()[0];
    if (list_cst.type != types.List) return error.InvalidModuleDefinition;

    for (list_cst.operands.asSlice()) |item_cst| {
        if (item_cst.type != types.String) return error.InvalidModuleDefinition;
        var buf = std.io.Writer.Allocating.init(allocator);
        defer buf.deinit();
        try ml.Cst.assembleString(&buf.writer, source, &item_cst);
        try list.append(allocator, try buf.toOwnedSlice());
    }
}

fn parseImportList(allocator: std.mem.Allocator, source: []const u8, value_cst: *const analysis.SyntaxTree, list: *[]const Import.Aliased) !void {
    common.todo(noreturn, .{ allocator, source, value_cst, list });
}

fn parseExtensionList(allocator: std.mem.Allocator, source: []const u8, value_cst: *const analysis.SyntaxTree, list: *[]const Import.Extension) !void {
    // Expects Block -> List
    if (value_cst.type != types.Block or value_cst.operands.len != 1) return error.InvalidModuleDefinition;
    const list_cst = value_cst.operands.asSlice()[0];
    if (list_cst.type != types.List) return error.InvalidModuleDefinition;

    for (list_cst.operands.asSlice()) |item_cst| {
        if (item_cst.type != types.Identifier) return error.InvalidModuleDefinition;
        try list.append(allocator, try allocator.dupe(u8, item_cst.token.data.sequence.asSlice()));
    }
    _ = source;
}

/// Get a parser for the module definition language.
pub fn getRModParser(
    allocator: std.mem.Allocator,
    lexer_settings: analysis.Lexer.Settings,
    source_name: []const u8,
    src: []const u8,
) analysis.Parser.Error!analysis.Parser {
    const ml_syntax = getRModSyntax();
    return ml_syntax.createParser(allocator, lexer_settings, src, .{
        .ignore_space = false,
        .source_name = source_name,
    });
}

/// Get the syntax for the module definition language.
pub fn getRModSyntax() *const analysis.Parser.Syntax {
    const static = struct {
        pub var syntax_mutex = std.Thread.Mutex{};
        pub var syntax: ?analysis.Parser.Syntax = null;
    };

    static.syntax_mutex.lock();
    defer static.syntax_mutex.unlock();

    if (static.syntax) |*s| {
        return s;
    }

    var out = analysis.Parser.Syntax.init(std.heap.page_allocator);

    inline for (.{
        ml.Cst.builtin_syntax.nud.leaf(),
        syntax_defs.nud.module(),
        ml.Cst.builtin_syntax.nud.leading_br(),
        ml.Cst.builtin_syntax.nud.indent(),
        ml.Cst.builtin_syntax.nud.double_quote(),
    }) |nud| {
        out.bindNud(nud) catch unreachable;
    }

    inline for (.{
        ml.Cst.builtin_syntax.leds.assign(),
        ml.Cst.builtin_syntax.leds.list(),
        ml.Cst.builtin_syntax.leds.seq(),
        ml.Cst.builtin_syntax.leds.apply(),
    }) |led| {
        out.bindLed(led) catch unreachable;
    }

    static.syntax = out;

    return &static.syntax.?;
}

pub const types = make_types: {
    var fresh = ml.Cst.types.fresh;

    break :make_types .{
        .Int = ml.Cst.types.Int,
        .String = ml.Cst.types.String,
        .StringElement = ml.Cst.types.StringElement,
        .StringSentinel = ml.Cst.types.StringSentinel,
        .Identifier = ml.Cst.types.Identifier,
        .Block = ml.Cst.types.Block,
        .Seq = ml.Cst.types.Seq,
        .List = ml.Cst.types.List,
        .Apply = ml.Cst.types.Apply,
        .Binary = ml.Cst.types.Binary,
        .Prefix = ml.Cst.types.Prefix,
        .Decl = ml.Cst.types.Decl,
        .Assign = ml.Cst.types.Assign,
        .Lambda = ml.Cst.types.Lambda,
        .Symbol = ml.Cst.types.Symbol,
        .Module = fresh.next(),
        .fresh = fresh,
    };
};

pub const syntax_defs = struct {
    pub const nud = struct {
        pub fn module() analysis.Parser.Nud {
            return analysis.Parser.createNud(
                "rmod_module",
                std.math.maxInt(i16),
                .{ .standard = .{ .sequence = .{ .standard = .fromSlice("module") } } },
                null,
                struct {
                    pub fn module(
                        parser: *analysis.Parser,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("module: parsing token {f}", .{token});
                        try parser.lexer.advance(); // discard module token
                        var name = try parser.pratt(std.math.minInt(i16)) orelse {
                            log.debug("module: no name found; panic", .{});
                            return error.UnexpectedInput;
                        };
                        errdefer name.deinit(parser.allocator);

                        if (try parser.lexer.peek()) |next_tok| {
                            if (next_tok.tag == .special and next_tok.data.special.escaped == false and next_tok.data.special.punctuation == .dot) {
                                log.debug("module: found dot token {f}", .{next_tok});
                                try parser.lexer.advance(); // discard dot
                                var inner = try parser.pratt(std.math.minInt(i16)) orelse {
                                    log.debug("module: no inner expression found; panic", .{});
                                    return error.UnexpectedEof;
                                };
                                errdefer inner.deinit(parser.allocator);
                                log.debug("module: got inner expression {f}", .{inner});
                                const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                                buff[0] = name;
                                buff[1] = inner;
                                return analysis.SyntaxTree{
                                    .source = .{ .name = parser.settings.source_name, .location = token.location },
                                    .precedence = bp,
                                    .type = types.Module,
                                    .token = token,
                                    .operands = .fromSlice(buff),
                                };
                            } else {
                                log.debug("module: expected dot token, found {f}; panic", .{next_tok});
                                return error.UnexpectedInput;
                            }
                        } else {
                            log.debug("module: no dot token found; panic", .{});
                            return error.UnexpectedEof;
                        }
                    }
                }.module,
            );
        }
    };
};
