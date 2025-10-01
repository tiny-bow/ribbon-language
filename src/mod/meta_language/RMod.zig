//! In-memory representation of a parsed `.rmod` module definition file, and the cst parser to construct it.

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

/// Represents a dependency specifier, e.g., `package "core@0.1.0"`.
pub const DependencySpecifier = union(enum) {
    package: []const u8,
    github: []const u8,
    path: []const u8,

    pub fn deinit(self: *DependencySpecifier, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .package => |s| allocator.free(s),
            .github => |s| allocator.free(s),
            .path => |s| allocator.free(s),
        }
    }
};

/// The canonical name of the module.
name: []const u8 = "unknown",
/// The source origin of the module definition.
origin: analysis.Source = .anonymous,
/// A list of source files and directories for the module.
sources: common.ArrayList([]const u8) = .empty,
/// A map of local dependency aliases to their full specifiers.
dependencies: common.StringMap(DependencySpecifier) = .empty,
/// A list of language extensions to activate for this module.
extensions: common.ArrayList([]const u8) = .empty,

/// Deinitializes the RMod, freeing all associated memory.
pub fn deinit(self: *RMod, allocator: std.mem.Allocator) void {
    allocator.free(self.name);

    for (self.sources.items) |s| allocator.free(s);
    self.sources.deinit(allocator);

    var dep_it = self.dependencies.iterator();
    while (dep_it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    self.dependencies.deinit(allocator);

    for (self.extensions.items) |s| allocator.free(s);
    self.extensions.deinit(allocator);
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
    var parser = try ml.Cst.getRModParser(allocator, lexer_settings, source_name, src);
    var cst = try parser.parse() orelse return null;
    defer cst.deinit(allocator);

    return try parseCst(allocator, src, &cst);
}

/// Parses a `.rmod` Concrete Syntax Tree into a `RMod` struct.
pub fn parseCst(allocator: std.mem.Allocator, source: []const u8, cst: *const analysis.SyntaxTree) !RMod {
    var def = RMod{
        .origin = cst.source,
    };
    errdefer def.deinit(allocator);

    if (cst.type != ml.Cst.types.Module) {
        log.err("Expected root of .rmod CST to be a Module node, found {f}", .{cst.type});
        return error.InvalidModuleDefinition;
    }

    const module_operands = cst.operands.asSlice();
    if (module_operands.len != 2) return error.InvalidModuleDefinition;

    // 1. Parse module name
    const name_cst = module_operands[0];
    if (name_cst.type != ml.Cst.types.Identifier) return error.InvalidModuleDefinition;
    def.name = try allocator.dupe(u8, name_cst.token.data.sequence.asSlice());

    // 2. Parse module body (a sequence of assignments)
    const body_cst = module_operands[1];
    // Body is a Block -> Seq
    if (body_cst.type != ml.Cst.types.Block or body_cst.operands.len != 1) return error.InvalidModuleDefinition;
    const seq_cst = body_cst.operands.asSlice()[0];
    if (seq_cst.type != ml.Cst.types.Seq) return error.InvalidModuleDefinition;

    for (seq_cst.operands.asSlice()) |*assignment_cst| {
        if (assignment_cst.type != ml.Cst.types.Set) return error.InvalidModuleDefinition;
        if (assignment_cst.operands.len != 2) return error.InvalidModuleDefinition;

        const key_cst = &assignment_cst.operands.asSlice()[0];
        const value_cst = &assignment_cst.operands.asSlice()[1];

        if (key_cst.type != ml.Cst.types.Identifier) return error.InvalidModuleDefinition;
        const key = key_cst.token.data.sequence.asSlice();

        if (std.mem.eql(u8, key, "sources")) {
            try parseSourceList(allocator, source, value_cst, &def.sources);
        } else if (std.mem.eql(u8, key, "dependencies")) {
            try parseDependencies(allocator, source, value_cst, &def.dependencies);
        } else if (std.mem.eql(u8, key, "extensions")) {
            try parseExtensionList(allocator, source, value_cst, &def.extensions);
        } else {
            log.warn("Unknown key in .rmod file: {s}", .{key});
        }
    }

    return def;
}

fn parseSourceList(allocator: std.mem.Allocator, source: []const u8, value_cst: *const analysis.SyntaxTree, list: *common.ArrayList([]const u8)) !void {
    // Expects Block -> List
    if (value_cst.type != ml.Cst.types.Block or value_cst.operands.len != 1) return error.InvalidModuleDefinition;
    const list_cst = value_cst.operands.asSlice()[0];
    if (list_cst.type != ml.Cst.types.List) return error.InvalidModuleDefinition;

    for (list_cst.operands.asSlice()) |item_cst| {
        if (item_cst.type != ml.Cst.types.String) return error.InvalidModuleDefinition;
        var buf = std.io.Writer.Allocating.init(allocator);
        defer buf.deinit();
        try ml.Cst.assembleString(&buf.writer, source, &item_cst);
        try list.append(allocator, try buf.toOwnedSlice());
    }
}

fn parseExtensionList(allocator: std.mem.Allocator, source: []const u8, value_cst: *const analysis.SyntaxTree, list: *common.ArrayList([]const u8)) !void {
    // Expects Block -> List
    if (value_cst.type != ml.Cst.types.Block or value_cst.operands.len != 1) return error.InvalidModuleDefinition;
    const list_cst = value_cst.operands.asSlice()[0];
    if (list_cst.type != ml.Cst.types.List) return error.InvalidModuleDefinition;

    for (list_cst.operands.asSlice()) |item_cst| {
        if (item_cst.type != ml.Cst.types.Identifier) return error.InvalidModuleDefinition;
        try list.append(allocator, try allocator.dupe(u8, item_cst.token.data.sequence.asSlice()));
    }
    _ = source;
}

fn parseDependencies(allocator: std.mem.Allocator, source: []const u8, value_cst: *const analysis.SyntaxTree, map: *common.StringMap(DependencySpecifier)) !void {
    // Expects Block -> Seq
    if (value_cst.type != ml.Cst.types.Block or value_cst.operands.len != 1) return error.InvalidModuleDefinition;
    const seq_cst = value_cst.operands.asSlice()[0];
    if (seq_cst.type != ml.Cst.types.Seq) return error.InvalidModuleDefinition;

    for (seq_cst.operands.asSlice()) |item_cst| {
        if (item_cst.type != ml.Cst.types.Set or item_cst.operands.len != 2) return error.InvalidModuleDefinition;

        const alias_cst = item_cst.operands.asSlice()[0];
        const spec_cst = item_cst.operands.asSlice()[1];

        if (alias_cst.type != ml.Cst.types.Identifier) return error.InvalidModuleDefinition;
        if (spec_cst.type != ml.Cst.types.Apply or spec_cst.operands.len != 2) return error.InvalidModuleDefinition;

        const alias = try allocator.dupe(u8, alias_cst.token.data.sequence.asSlice());

        const spec_type_cst = spec_cst.operands.asSlice()[0];
        const spec_val_cst = spec_cst.operands.asSlice()[1];

        if (spec_type_cst.type != ml.Cst.types.Identifier) return error.InvalidModuleDefinition;
        if (spec_val_cst.type != ml.Cst.types.String) return error.InvalidModuleDefinition;

        const spec_type = spec_type_cst.token.data.sequence.asSlice();

        var buf = std.io.Writer.Allocating.init(allocator);
        try ml.Cst.assembleString(&buf.writer, source, &spec_val_cst);
        const spec_val = try buf.toOwnedSlice();

        const specifier: DependencySpecifier = if (std.mem.eql(u8, spec_type, "package"))
            .{ .package = spec_val }
        else if (std.mem.eql(u8, spec_type, "github"))
            .{ .github = spec_val }
        else if (std.mem.eql(u8, spec_type, "path"))
            .{ .path = spec_val }
        else
            return error.InvalidModuleDefinition;

        try map.put(allocator, alias, specifier);
    }
}
