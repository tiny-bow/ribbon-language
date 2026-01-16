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
name: []const u8 = "",
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
    allocator.free(self.name);

    for (self.imports) |imp| {
        if (imp.import.package) |pkg| {
            allocator.free(pkg);
        }

        allocator.free(imp.import.module);

        if (imp.alias) |alias| {
            allocator.free(alias);
        }
    }
    allocator.free(self.imports);

    for (self.extensions) |ext| {
        if (ext.import.package) |pkg| {
            allocator.free(pkg);
        }

        allocator.free(ext.import.module);
        allocator.free(ext.name);
    }
    allocator.free(self.extensions);

    for (self.inputs) |input| {
        allocator.free(input);
    }
    allocator.free(self.inputs);
}

/// `std.fmt` impl
pub fn format(self: *const RMod, writer: *std.io.Writer) !void {
    try writer.print("{f}: ", .{self.source});

    try writer.writeAll("module");
    if (self.name.len != 0) {
        try writer.writeAll(" ");
        try writer.writeAll(self.name);
    }

    try writer.print(" {x}.\n", .{self.guid});

    try writer.print("    visibility = {s}\n", .{@tagName(self.visibility)});

    try writer.print("    inputs =\n", .{});
    for (self.inputs) |input| {
        try writer.print("        {s}\n", .{input});
    }

    try writer.print("    imports =\n", .{});
    for (self.imports) |imp| {
        if (imp.alias) |alias| {
            if (imp.import.package) |pkg| {
                try writer.print("        {s}.{s} as {s}\n", .{ pkg, imp.import.module, alias });
            } else {
                try writer.print("        {s} as {s}\n", .{ imp.import.module, alias });
            }
        } else {
            if (imp.import.package) |pkg| {
                try writer.print("        {s}.{s}\n", .{ pkg, imp.import.module });
            } else {
                try writer.print("        {s}\n", .{imp.import.module});
            }
        }
    }

    try writer.print("    extensions =\n", .{});
    for (self.extensions) |ext| {
        if (ext.import.package) |pkg| {
            try writer.print("        {s}.{s}.{s}\n", .{ pkg, ext.import.module, ext.name });
        } else {
            try writer.print("        {s}.{s}\n", .{ ext.import.module, ext.name });
        }
    }
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
    defer parser.deinit();

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
    if (module_operands.len != 1) return error.InvalidModuleDefinition;

    // Parse module body (a sequence of assignments)
    const body_cst = module_operands[0];
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
            var acc = common.ArrayList([]const u8).empty;
            defer acc.deinit(allocator);

            try parseInputList(allocator, source, value_cst, &acc);

            def.inputs = try allocator.dupe([]const u8, acc.items);
        } else if (std.mem.eql(u8, key, "imports")) {
            var acc = common.ArrayList(Import.Aliased).empty;
            defer acc.deinit(allocator);

            try parseImportList(allocator, source, value_cst, &acc);

            def.imports = try allocator.dupe(Import.Aliased, acc.items);
        } else if (std.mem.eql(u8, key, "extensions")) {
            var acc = common.ArrayList(Import.Extension).empty;
            defer acc.deinit(allocator);

            try parseExtensionList(allocator, source, value_cst, &acc);

            def.extensions = try allocator.dupe(Import.Extension, acc.items);
        } else {
            log.warn("Unknown key in .rmod file: {s}", .{key});
        }
    }

    return def;
}

fn parseInputList(allocator: std.mem.Allocator, source: []const u8, value_cst: *const analysis.SyntaxTree, list: *common.ArrayList([]const u8)) !void {
    // Expects Block -> List
    const list_cst = if (value_cst.type != types.Block or value_cst.operands.len != 1) recover: {
        log.debug("Expected inputs value to be a Block containing a List, found {s}", .{types.getName(value_cst.type)});
        break :recover value_cst;
    } else &value_cst.operands.asSlice()[0];
    const elements = if (list_cst.type != types.List) recover: {
        log.debug("Expected inputs Block to contain a List, found {s}", .{types.getName(list_cst.type)});
        break :recover &.{list_cst.*};
    } else list_cst.operands.asSlice();

    for (elements) |item_cst| {
        if (item_cst.type != types.String) {
            log.debug("Expected input item to be a String node, found {s}", .{types.getName(item_cst.type)});
            return error.InvalidModuleDefinition;
        }
        var buf = std.io.Writer.Allocating.init(allocator);
        defer buf.deinit();
        try ml.Cst.assembleString(&buf.writer, source, &item_cst);
        try list.append(allocator, try buf.toOwnedSlice());
    }
}

fn parseImportList(allocator: std.mem.Allocator, _: []const u8, value_cst: *const analysis.SyntaxTree, list: *common.ArrayList(Import.Aliased)) !void {
    // Expects Block -> List
    const list_cst = if (value_cst.type != types.Block or value_cst.operands.len != 1) recover: {
        log.debug("Expected imports value to be a Block containing a List, found {s}", .{types.getName(value_cst.type)});
        break :recover value_cst;
    } else &value_cst.operands.asSlice()[0];
    const elements = if (list_cst.type != types.List) recover: {
        log.debug("Expected imports Block to contain a List, found {s}", .{types.getName(list_cst.type)});
        break :recover &.{list_cst.*};
    } else list_cst.operands.asSlice();

    for (elements) |item_cst| {
        if (item_cst.type != types.Identifier and item_cst.type != types.Apply and item_cst.type != types.MemberAccess) return error.InvalidModuleDefinition;

        var import: Import = .{ .module = undefined };
        var alias: ?[]const u8 = null;

        if (item_cst.type == types.Identifier or item_cst.type == types.MemberAccess) {
            // import without alias
            parseImportBase(allocator, &item_cst, &import) catch |err| {
                log.err("Failed to parse import base: {s}", .{@errorName(err)});
                return error.InvalidModuleDefinition;
            };
        } else {
            // import with alias
            if (item_cst.operands.len != 3 or item_cst.operands.asSlice()[1].type != types.Identifier or !std.mem.eql(u8, item_cst.operands.asSlice()[1].token.data.sequence.asSlice(), "as")) {
                return error.InvalidModuleDefinition;
            }
            const target_cst = &item_cst.operands.asSlice()[0];
            const alias_cst = &item_cst.operands.asSlice()[2];

            parseImportBase(allocator, target_cst, &import) catch |err| {
                log.err("Failed to parse import base: {s}", .{@errorName(err)});
                return error.InvalidModuleDefinition;
            };

            if (alias_cst.type != types.Identifier) return error.InvalidModuleDefinition;
            alias = try allocator.dupe(u8, alias_cst.token.data.sequence.asSlice());
        }

        try list.append(allocator, Import.Aliased{
            .import = import,
            .alias = alias,
        });
    }
}

fn parseImportBase(allocator: std.mem.Allocator, item_cst: *const analysis.SyntaxTree, import: *Import) !void {
    if (item_cst.type == types.Identifier) {
        // Identifier: local import
        import.module = try allocator.dupe(u8, item_cst.token.data.sequence.asSlice());
    } else if (item_cst.type == types.MemberAccess) {
        // MemberAccess: import from package
        if (item_cst.operands.len != 2 or item_cst.operands.asSlice()[0].type != types.Identifier or item_cst.operands.asSlice()[1].type != types.Identifier) return error.InvalidModuleDefinition;
        import.package = try allocator.dupe(u8, item_cst.operands.asSlice()[0].token.data.sequence.asSlice());
        import.module = try allocator.dupe(u8, item_cst.operands.asSlice()[1].token.data.sequence.asSlice());
    } else {
        return error.InvalidModuleDefinition;
    }
}

fn parseExtensionList(allocator: std.mem.Allocator, _: []const u8, value_cst: *const analysis.SyntaxTree, list: *common.ArrayList(Import.Extension)) !void {
    // Expects Block -> List
    const list_cst = if (value_cst.type != types.Block or value_cst.operands.len != 1) recover: {
        log.debug("Expected extensions value to be a Block containing a List, found {s}", .{types.getName(value_cst.type)});
        break :recover value_cst;
    } else &value_cst.operands.asSlice()[0];
    const elements = if (list_cst.type != types.List) recover: {
        log.debug("Expected extensions Block to contain a List, found {s}", .{types.getName(list_cst.type)});
        break :recover &.{list_cst.*};
    } else list_cst.operands.asSlice();

    for (elements) |item_cst| {
        var import: Import = .{ .module = undefined };
        var name: []const u8 = undefined;

        if (item_cst.type != types.MemberAccess) return error.InvalidModuleDefinition;

        if (item_cst.operands.asSlice()[0].type == types.MemberAccess) {
            // package.module.extension
            const pkg_mod_cst = &item_cst.operands.asSlice()[0];
            if (pkg_mod_cst.operands.len != 2 or pkg_mod_cst.operands.asSlice()[0].type != types.Identifier or pkg_mod_cst.operands.asSlice()[1].type != types.Identifier) {
                return error.InvalidModuleDefinition;
            }
            import.package = try allocator.dupe(u8, pkg_mod_cst.operands.asSlice()[0].token.data.sequence.asSlice());
            import.module = try allocator.dupe(u8, pkg_mod_cst.operands.asSlice()[1].token.data.sequence.asSlice());
        } else if (item_cst.operands.asSlice()[0].type == types.Identifier) {
            // module.extension
            import.module = try allocator.dupe(u8, item_cst.operands.asSlice()[0].token.data.sequence.asSlice());
        } else {
            return error.InvalidModuleDefinition;
        }

        name = try allocator.dupe(u8, item_cst.operands.asSlice()[1].token.data.sequence.asSlice());

        try list.append(allocator, Import.Extension{
            .import = import,
            .name = name,
        });
    }
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

    static.syntax = analysis.Parser.Syntax.init(std.heap.page_allocator);

    bindRModSyntax(&static.syntax.?) catch |err| {
        std.debug.panic("Cannot getRModSyntax: {s}", .{@errorName(err)});
    };

    return &static.syntax.?;
}

pub fn bindRModSyntax(out: *analysis.Parser.Syntax) !void {
    try ml.Cst.bindRmlSyntax(out);

    try out.bindNud(syntax_defs.nud.module());
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
        .MemberAccess = ml.Cst.types.MemberAccess,
        .Module = fresh.next(),
        .fresh = fresh,
        .getName = struct {
            pub fn RModTypeName(t: analysis.SyntaxTree.Type) []const u8 {
                return switch (t) {
                    types.Module => "Module",
                    else => return ml.Cst.types.getName(t),
                };
            }
        }.RModTypeName,
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
                                const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 1);
                                buff[0] = inner;
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
