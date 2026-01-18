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

        /// `std.fmt` impl
        pub fn format(self: *const Aliased, writer: *std.io.Writer) !void {
            try self.import.format(writer);
            if (self.alias) |alias| {
                try writer.print(" as {s}", .{alias});
            }
        }
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

        /// `std.fmt` impl
        pub fn format(self: *const Extension, writer: *std.io.Writer) !void {
            try self.import.format(writer);
            try writer.print(".{s}", .{self.name});
        }
    };

    /// `std.fmt` impl
    pub fn format(self: *const Import, writer: *std.io.Writer) !void {
        if (self.package) |pkg| {
            try writer.print("{s}.{s}", .{ pkg, self.module });
        } else {
            try writer.writeAll(self.module);
        }
    }
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
        try writer.writeAll("        ");
        try imp.format(writer);
        try writer.writeAll("\n");
    }

    try writer.print("    extensions =\n", .{});
    for (self.extensions) |ext| {
        try writer.writeAll("        ");
        try ext.format(writer);
        try writer.writeAll("\n");
    }
}

const RenderFmtData = struct {
    allocator: std.mem.Allocator,
    options: common.PrettyPrinter.RenderOptions,
    rmod: *const RMod,
    pub fn format(self: *const RenderFmtData, writer: *std.io.Writer) !void {
        var pp = common.PrettyPrinter.init(self.allocator);
        defer pp.deinit();

        const doc = self.rmod.render(&pp);

        pp.render(doc, writer, self.options) catch |err| {
            log.debug("Pretty printer render error: {s}", .{@errorName(err)});
            return error.WriteFailed;
        };
    }
};

/// Helper to get a pretty printer formatted string inside a regular format call
pub fn rendered(self: *const RMod, allocator: std.mem.Allocator, options: common.PrettyPrinter.RenderOptions) RenderFmtData {
    return RenderFmtData{
        .allocator = allocator,
        .options = options,
        .rmod = self,
    };
}

/// Pretty printer formatter
pub fn render(self: *const RMod, pp: *common.PrettyPrinter) *const common.PrettyPrinter.Doc {
    return pp.concat(&.{
        pp.text("module"),
        if (self.name.len != 0) pp.print(" {s}", .{self.name}) else pp.nil(),
        pp.print(" ({x})", .{self.guid}),
        pp.text("."),
        pp.nest(1, pp.concat(&.{
            pp.line(),
            pp.text("visibility ="),
            pp.hang(1, pp.text(@tagName(self.visibility))),
            pp.line(),
            pp.text("inputs ="),
            inputs: {
                if (self.inputs.len == 0) {
                    break :inputs pp.text(" ()");
                } else if (self.inputs.len == 1) {
                    break :inputs pp.hang(1, pp.print("\"{s}\"", .{self.inputs[0]}));
                } else {
                    var items = pp.gpa.alloc(*const common.PrettyPrinter.Doc, self.inputs.len + 1) catch return pp.fail();
                    defer pp.gpa.free(items);
                    items[0] = pp.line();
                    for (self.inputs, 0..) |input, i| {
                        items[i + 1] = pp.concat(&.{
                            pp.print("\"{s}\"", .{input}),
                            if (i < self.inputs.len - 1) pp.line() else pp.nil(),
                        });
                    }
                    break :inputs pp.nest(1, pp.concat(items));
                }
            },
            pp.line(),
            pp.text("imports ="),
            imports: {
                if (self.imports.len == 0) {
                    break :imports pp.text(" ()");
                } else if (self.imports.len == 1) {
                    break :imports pp.hang(1, pp.print("{f}", .{self.imports[0]}));
                } else {
                    var items = pp.gpa.alloc(*const common.PrettyPrinter.Doc, self.imports.len + 1) catch return pp.fail();
                    defer pp.gpa.free(items);
                    items[0] = pp.line();
                    for (self.imports, 0..) |imp, i| {
                        items[i + 1] = pp.concat(&.{
                            pp.print("{f}", .{imp}),
                            if (i < self.imports.len - 1) pp.line() else pp.nil(),
                        });
                    }
                    break :imports pp.nest(1, pp.concat(items));
                }
            },
            pp.line(),
            pp.text("extensions ="),
            extensions: {
                if (self.extensions.len == 0) {
                    break :extensions pp.text(" ()");
                } else if (self.extensions.len == 1) {
                    break :extensions pp.hang(1, pp.print("{f}", .{self.extensions[0]}));
                } else {
                    var items = pp.gpa.alloc(*const common.PrettyPrinter.Doc, self.extensions.len + 1) catch return pp.fail();
                    defer pp.gpa.free(items);
                    items[0] = pp.line();
                    for (self.extensions, 0..) |ext, i| {
                        items[i + 1] = pp.concat(&.{
                            pp.print("{f}", .{ext}),
                            if (i < self.extensions.len - 1) pp.line() else pp.nil(),
                        });
                    }
                    break :extensions pp.nest(1, pp.concat(items));
                }
            },
        })),
    });
}

/// Parse a module definition language source string to an `RMod`.
/// * Returns null if the source is empty.
/// * Returns an error if we cannot parse the entire source.
pub fn parseSource(
    allocator: std.mem.Allocator,
    diag: *analysis.Diagnostic.Context,
    lexer_settings: analysis.Lexer.Settings,
    source_name: []const u8,
    src: []const u8,
) (analysis.Parser.Error || error{ InvalidString, InvalidEscape, InvalidModuleDefinition } || std.io.Writer.Error)!?RMod {
    var parser = try getRModParser(allocator, diag, lexer_settings, source_name, src);
    defer parser.deinit();

    var cst = try parser.parse() orelse return null;
    defer cst.deinit(allocator);

    return try parseCst(allocator, diag, src, &cst);
}

/// Parses a `.rmod` Concrete Syntax Tree into a `RMod` struct.
pub fn parseCst(allocator: std.mem.Allocator, diag: *analysis.Diagnostic.Context, source: []const u8, cst: *const analysis.SyntaxTree) !RMod {
    log.debug("parsing RMod CST:\n{f}", .{ml.Cst.treeFormatter(.{
        .source = source,
        .tree = cst,
    })});

    var def = RMod{
        .source = cst.source,
    };
    errdefer def.deinit(allocator);

    if (cst.type != types.Module) {
        log.err("Expected root of rmod CST to be a Module node, found {f}", .{cst.type});
        try diag.raise(
            .@"error",
            cst.source,
            "InvalidModuleDefinition",
            diag.text("Expected root of module definition to be a 'module' declaration."),
            &.{},
        );
        return error.InvalidModuleDefinition;
    }

    const module_operands = cst.operands.asSlice();
    if (module_operands.len != 1) {
        try diag.raise(
            .@"error",
            cst.source,
            "InvalidModuleDefinition",
            diag.text("Expected module to have exactly one operand. (A body block.)"),
            &.{},
        );
        return error.InvalidModuleDefinition;
    }
    // Parse module body (a sequence of assignments)
    const body_cst = &module_operands[0];
    const seq_cst = if (body_cst.type != types.Block or body_cst.operands.len != 1) recover: {
        log.debug("Expected module Body to be a Block containing a Seq, found {s}", .{types.getName(body_cst.type)});
        break :recover body_cst;
    } else &body_cst.operands.asSlice()[0];
    const elements = if (seq_cst.type != types.Seq) recover: {
        log.debug("Expected module Block to contain a Seq, found {s}", .{types.getName(seq_cst.type)});
        break :recover &.{seq_cst.*};
    } else seq_cst.operands.asSlice();

    for (elements) |*assignment_cst| {
        if (assignment_cst.type != types.Assign) {
            log.debug("Expected module body element to be an Assign node, found {s}", .{types.getName(assignment_cst.type)});
            try diag.raise(
                .@"error",
                assignment_cst.source,
                "InvalidModuleBodyElement",
                diag.print("Each module body element must be an assignment, but got {s}.", .{types.getName(assignment_cst.type)}),
                &.{},
            );
            return error.InvalidModuleDefinition;
        }

        const key_cst = &assignment_cst.operands.asSlice()[0];
        const value_cst = &assignment_cst.operands.asSlice()[1];

        if (key_cst.type != types.Identifier) {
            log.debug("Expected assignment key to be an Identifier node, found {s}", .{types.getName(key_cst.type)});
            try diag.raise(
                .@"error",
                key_cst.source,
                "InvalidModuleKey",
                diag.print("Module field keys must be identifiers, but got {s}.", .{types.getName(key_cst.type)}),
                &.{},
            );
            return error.InvalidModuleDefinition;
        }
        const key = key_cst.token.data.sequence.asSlice();

        if (std.mem.eql(u8, key, "inputs")) {
            var acc = common.ArrayList([]const u8).empty;
            defer acc.deinit(allocator);

            try parseInputList(allocator, diag, source, value_cst, &acc);

            def.inputs = try allocator.dupe([]const u8, acc.items);
        } else if (std.mem.eql(u8, key, "imports")) {
            var acc = common.ArrayList(Import.Aliased).empty;
            defer acc.deinit(allocator);

            try parseImportList(allocator, diag, value_cst, &acc);

            def.imports = try allocator.dupe(Import.Aliased, acc.items);
        } else if (std.mem.eql(u8, key, "extensions")) {
            var acc = common.ArrayList(Import.Extension).empty;
            defer acc.deinit(allocator);

            try parseExtensionList(allocator, diag, value_cst, &acc);

            def.extensions = try allocator.dupe(Import.Extension, acc.items);
        } else {
            log.debug("Unknown key in .rmod file: {s}", .{key});
            try diag.raise(
                .warning,
                key_cst.source,
                "UnknownModuleKey",
                diag.print("Unknown key '{s}' in module definition.", .{key}),
                &.{},
            );
        }
    }

    return def;
}

fn parseInputList(allocator: std.mem.Allocator, diag: *analysis.Diagnostic.Context, source: []const u8, value_cst: *const analysis.SyntaxTree, list: *common.ArrayList([]const u8)) !void {
    // Expects Block -> Seq
    const seq_cst = if (value_cst.type != types.Block or value_cst.operands.len != 1) recover: {
        log.debug("Expected inputs value to be a Block containing a Seq, found {s}", .{types.getName(value_cst.type)});
        break :recover value_cst;
    } else &value_cst.operands.asSlice()[0];
    const elements = if (seq_cst.type != types.Seq) recover: {
        log.debug("Expected inputs Block to contain a Seq, found {s}", .{types.getName(seq_cst.type)});
        break :recover &.{seq_cst.*};
    } else seq_cst.operands.asSlice();

    for (elements) |item_cst| {
        if (item_cst.type != types.String) {
            log.debug("Expected input item to be a String node, found {s}", .{types.getName(item_cst.type)});
            try diag.raise(
                .@"error",
                item_cst.source,
                "InvalidModuleInput",
                diag.text("Expected module input to be a string literal."),
                &.{},
            );
            return error.InvalidModuleDefinition;
        }
        var buf = std.io.Writer.Allocating.init(allocator);
        defer buf.deinit();
        try ml.Cst.assembleString(&buf.writer, source, &item_cst);
        try list.append(allocator, try buf.toOwnedSlice());
    }
}

fn parseImportList(allocator: std.mem.Allocator, diag: *analysis.Diagnostic.Context, value_cst: *const analysis.SyntaxTree, list: *common.ArrayList(Import.Aliased)) !void {
    // Expects Block -> Seq
    const seq_cst = if (value_cst.type != types.Block or value_cst.operands.len != 1) recover: {
        log.debug("Expected imports value to be a Block containing a Seq, found {s}", .{types.getName(value_cst.type)});
        break :recover value_cst;
    } else &value_cst.operands.asSlice()[0];
    const elements = if (seq_cst.type != types.Seq) recover: {
        log.debug("Expected imports Block to contain a Seq, found {s}", .{types.getName(seq_cst.type)});
        break :recover &.{seq_cst.*};
    } else seq_cst.operands.asSlice();

    for (elements) |item_cst| {
        if (item_cst.type != types.Identifier and item_cst.type != types.Apply and item_cst.type != types.MemberAccess) {
            log.debug("Expected import item to be an Identifier, Apply, or MemberAccess node, found {s}", .{types.getName(item_cst.type)});
            try diag.raise(
                .@"error",
                item_cst.source,
                "InvalidModuleImport",
                diag.text("Expected module import to be an identifier, member access, or aliased import."),
                &.{},
            );
            return error.InvalidModuleDefinition;
        }

        var import: Import = .{ .module = undefined };
        var alias: ?[]const u8 = null;

        if (item_cst.type == types.Identifier or item_cst.type == types.MemberAccess) {
            // import without alias
            parseImportBase(allocator, diag, &item_cst, &import) catch |err| {
                log.debug("Failed to parse import base: {s}", .{@errorName(err)});
                return error.InvalidModuleDefinition;
            };
        } else {
            // import with alias
            if (item_cst.operands.len != 3 or item_cst.operands.asSlice()[1].type != types.Identifier or !std.mem.eql(u8, item_cst.operands.asSlice()[1].token.data.sequence.asSlice(), "as")) {
                log.debug("Expected aliased import to be of the form (import as alias), found invalid structure", .{});
                return error.InvalidModuleDefinition;
            }
            const target_cst = &item_cst.operands.asSlice()[0];
            const alias_cst = &item_cst.operands.asSlice()[2];

            parseImportBase(allocator, diag, target_cst, &import) catch |err| {
                log.debug("Failed to parse import base: {s}", .{@errorName(err)});
                return error.InvalidModuleDefinition;
            };

            if (alias_cst.type != types.Identifier) {
                log.debug("Expected alias in aliased import to be an Identifier node, found {s}", .{types.getName(alias_cst.type)});

                try diag.raise(
                    .@"error",
                    item_cst.source,
                    "InvalidModuleImportAlias",
                    diag.print("Expected alias in aliased import to be an identifier, found {s}.", .{types.getName(alias_cst.type)}),
                    &.{},
                );
                return error.InvalidModuleDefinition;
            }
            alias = try allocator.dupe(u8, alias_cst.token.data.sequence.asSlice());
        }

        try list.append(allocator, Import.Aliased{
            .import = import,
            .alias = alias,
        });
    }
}

fn parseImportBase(allocator: std.mem.Allocator, diag: *analysis.Diagnostic.Context, item_cst: *const analysis.SyntaxTree, import: *Import) !void {
    if (item_cst.type == types.Identifier) {
        // Identifier: local import
        import.module = try allocator.dupe(u8, item_cst.token.data.sequence.asSlice());
    } else if (item_cst.type == types.MemberAccess) {
        // MemberAccess: import from package
        if (item_cst.operands.len != 2 or item_cst.operands.asSlice()[0].type != types.Identifier or item_cst.operands.asSlice()[1].type != types.Identifier) {
            try diag.raise(
                .@"error",
                item_cst.source,
                "InvalidModuleImport",
                diag.text("Expected module import to be of the form 'module' or 'package.module'."),
                &.{},
            );
            return error.InvalidModuleDefinition;
        }
        import.package = try allocator.dupe(u8, item_cst.operands.asSlice()[0].token.data.sequence.asSlice());
        import.module = try allocator.dupe(u8, item_cst.operands.asSlice()[1].token.data.sequence.asSlice());
    } else {
        try diag.raise(
            .@"error",
            item_cst.source,
            "InvalidModuleImport",
            diag.print("Expected module import to be an identifier or member access, found {s}.", .{types.getName(item_cst.type)}),
            &.{},
        );
        return error.InvalidModuleDefinition;
    }
}

fn parseExtensionList(allocator: std.mem.Allocator, diag: *analysis.Diagnostic.Context, value_cst: *const analysis.SyntaxTree, list: *common.ArrayList(Import.Extension)) !void {
    // Expects Block -> Seq
    const seq_cst = if (value_cst.type != types.Block or value_cst.operands.len != 1) recover: {
        log.debug("Expected extensions value to be a Block containing a Seq, found {s}", .{types.getName(value_cst.type)});
        break :recover value_cst;
    } else &value_cst.operands.asSlice()[0];
    const elements = if (seq_cst.type != types.Seq) recover: {
        log.debug("Expected extensions Block to contain a Seq, found {s}", .{types.getName(seq_cst.type)});
        break :recover &.{seq_cst.*};
    } else seq_cst.operands.asSlice();

    for (elements) |item_cst| {
        var import: Import = .{ .module = undefined };
        var name: []const u8 = undefined;

        if (item_cst.type != types.MemberAccess) {
            log.debug("Expected extension item to be a MemberAccess node, found {s}", .{types.getName(item_cst.type)});
            try diag.raise(
                .@"error",
                item_cst.source,
                "InvalidModuleExtension",
                diag.print("Expected module extension to be a member access expression (ie. mod.foo or pkg.mod.foo), found {s}", .{types.getName(item_cst.type)}),
                &.{},
            );
            return error.InvalidModuleDefinition;
        }

        if (item_cst.operands.asSlice()[1].type != types.Identifier) {
            log.debug("Expected extension name to be an Identifier node, found {s}", .{types.getName(item_cst.operands.asSlice()[1].type)});
            try diag.raise(
                .@"error",
                item_cst.source,
                "InvalidModuleExtensionName",
                diag.print("Expected module extension name to be an identifier, found {s}.", .{types.getName(item_cst.operands.asSlice()[1].type)}),
                &.{},
            );
            return error.InvalidModuleDefinition;
        }

        if (item_cst.operands.asSlice()[0].type == types.MemberAccess) {
            // package.module.extension
            const pkg_mod_cst = &item_cst.operands.asSlice()[0];
            if (pkg_mod_cst.operands.len != 2 or pkg_mod_cst.operands.asSlice()[0].type != types.Identifier or pkg_mod_cst.operands.asSlice()[1].type != types.Identifier) {
                log.debug("Expected extension import to be of the form 'package.module.extension', found invalid structure", .{});
                try diag.raise(
                    .@"error",
                    item_cst.source,
                    "InvalidModuleExtension",
                    diag.text("Expected module extension base to be of the form 'package.module'."),
                    &.{},
                );
                return error.InvalidModuleDefinition;
            }
            import.package = try allocator.dupe(u8, pkg_mod_cst.operands.asSlice()[0].token.data.sequence.asSlice());
            import.module = try allocator.dupe(u8, pkg_mod_cst.operands.asSlice()[1].token.data.sequence.asSlice());
        } else if (item_cst.operands.asSlice()[0].type == types.Identifier) {
            // module.extension
            import.module = try allocator.dupe(u8, item_cst.operands.asSlice()[0].token.data.sequence.asSlice());
        } else {
            log.debug("Expected extension import to be an Identifier or MemberAccess node, found {s}", .{types.getName(item_cst.operands.asSlice()[0].type)});
            try diag.raise(
                .@"error",
                item_cst.source,
                "InvalidModuleExtensionImport",
                diag.print("Expected module extension import base to be an identifier or member access, (ie. pkg.mod or mod) found {s}.", .{types.getName(item_cst.operands.asSlice()[0].type)}),
                &.{},
            );
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
    diag: *analysis.Diagnostic.Context,
    lexer_settings: analysis.Lexer.Settings,
    source_name: []const u8,
    src: []const u8,
) analysis.Parser.Error!analysis.Parser {
    const ml_syntax = getRModSyntax();
    return ml_syntax.createParser(allocator, diag, lexer_settings, src, .{
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
        .Float = ml.Cst.types.Float,
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
                                var inner = try parser.pratt(std.math.minInt(i16) + 1) orelse {
                                    log.debug("module: no inner expression found; panic", .{});
                                    try parser.report(
                                        .@"error",
                                        next_tok.location,
                                        "InvalidModuleDeclaration",
                                        parser.diag.text("Expected module body block after 'module.'"),
                                        &.{},
                                    );
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
                                try parser.report(
                                    .@"error",
                                    next_tok.location,
                                    "InvalidModuleDeclaration",
                                    parser.diag.text("Expected a dot token after module keyword"),
                                    &.{},
                                );
                                return error.UnexpectedInput;
                            }
                        } else {
                            log.debug("module: no dot token found; panic", .{});
                            try parser.report(
                                .@"error",
                                token.location,
                                "InvalidModuleDeclaration",
                                parser.diag.text("Expected a dot token after module keyword"),
                                &.{},
                            );
                            return error.UnexpectedEof;
                        }
                    }
                }.module,
            );
        }
    };
};
