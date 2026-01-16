//! Defines a Ribbon package. This is the root structure parsed from a .rpkg file.
//! In-memory representation of a parsed package definition, and the cst parser to construct it.

const RPkg = @This();

const std = @import("std");
const log = std.log.scoped(.package_def);

const common = @import("common");
const analysis = @import("analysis");
const ir = @import("ir");

const ml = @import("../meta_language.zig");
const RMod = ml.RMod;

test {
    // std.debug.print("semantic analysis for RPkg\n", .{});
    std.testing.refAllDecls(@This());
}

/// The package's canonical name.
name: []const u8 = "",
/// The package definition's source path; may be absolute or relative to the compiler's working directory.
source_path: []const u8 = "",
/// The package's version specifier.
version: common.SemVer = .{},
/// The package's dependencies.
dependencies: []const Dependency = &.{},
/// The Ribbon modules defined within this package.
modules: []const MaybeModule = &.{},

/// Defines a Ribbon package module, or a path to a module definition file yet to be parsed.
pub const MaybeModule = union(enum) {
    /// The module definition was defined inline within the package definition,
    /// or has now been parsed from an external file.
    definition: ml.RMod,
    /// The module definition is located at the given file path, but has not yet been parsed.
    deferred: DeferredModule,

    pub const DeferredModule = struct {
        name: []const u8,
        visibility: ml.RMod.Visibility,
        file_path: []const u8,
    };
};

/// Defines a dependency package request for a higher-level Ribbon package.
pub const Dependency = struct {
    /// The dependency's canonical name within the root package.
    name: []const u8 = "",
    /// The source code location within the package definition where this dependency was defined.
    source: analysis.Source = .anonymous,
    /// The kind of dependency; either a package or arbitrary files.
    kind: Dependency.Kind = .other,
    /// Where and how to fetch the dependency's data.
    fetch_origin: FetchOrigin = .{
        .kind = .{ .source = .absolute },
        .value = "",
    },
    /// The version specifier for the dependency.
    version: ?common.SemVer = null,

    /// Defines the kind of a package dependency.
    pub const Kind = enum {
        /// The dependency is a Ribbon package.
        /// The orchestrator will look for a package definition file at the FetchOrigin.
        package,
        /// The dependency is an arbitrary set of files.
        /// The orchestrator will not attempt to parse Ribbon modules from this dependency.
        /// TODO: how to access these in source files?
        other,
    };
};

/// Defines where and how to fetch a Dependency's source code.
pub const FetchOrigin = struct {
    /// How to interpret the `value`.
    kind: FetchOrigin.Kind,
    /// A URL or a local or absolute path, depending on the Kind.
    value: []const u8,

    /// Defines how to interpret the `value` field of a FetchOrigin.
    pub const Kind = union(enum) {
        /// Fetch from a remote Git repository. The `value` is the Git URL.
        git,
        /// Fetch from a local archive file. The `value` is the unique name, path to the archive, or its remote URL;
        /// the ArchiveLocation defines whether it is a url, a unique name in a package registry, or a local or absolute path.
        archive: ArchiveLocation,
        /// Fetch from a local source directory. The `value` is the path to the directory;
        /// the SourceLocation defines whether it is a local or absolute path.
        source: SourceLocation,
    };

    /// Defines how to interpret the `value` field of a FetchOrigin when the Kind is `archive`.
    pub const ArchiveLocation = enum {
        /// The `value` is a remote web address.
        url,
        /// The `value` is a path relative to the current working directory.
        local,
        /// The `value` is an absolute path in the filesystem.
        /// The orchestrator should issue a warning unless suppressed.
        absolute,
        /// The `value` is a unique name on a package registry.
        /// The orchestrator may error if it is not provided with a registry service.
        registry,
    };

    /// Defines how to interpret the `value` field of a FetchOrigin when the Kind is `source`.
    pub const SourceLocation = enum {
        /// The `value` is a remote web address.
        url,
        /// The `value` is a path relative to the current working directory.
        local,
        /// The `value` is an absolute path in the filesystem.
        /// The orchestrator should issue a warning unless suppressed.
        absolute,
    };
};

/// `std.fmt` impl
pub fn format(self: *const RPkg, writer: *std.io.Writer) !void {
    try writer.print("package {s}.\n", .{self.name});
    try writer.print("    version = {f}\n", .{self.version});
    try writer.print("    dependencies =\n", .{});
    for (self.dependencies) |dep| {
        try writer.print("        {s} = {s} {s}", .{ dep.name, @tagName(dep.fetch_origin.kind), dep.fetch_origin.value });
        if (dep.version) |ver| {
            try writer.print(" @ {f}", .{ver});
        }
        try writer.writeAll("\n");
    }
    try writer.print("    modules =\n", .{});
    for (self.modules) |*mod| {
        switch (mod.*) {
            .definition => |*def| {
                try writer.print("        {s} {f}", .{ @tagName(def.visibility), def });
            },
            .deferred => |def| {
                try writer.print("        unresolved {s} {s} = {s}\n", .{ def.name, @tagName(def.visibility), def.file_path });
            },
        }
    }
}

pub fn deinit(self: *RPkg, allocator: std.mem.Allocator) void {
    allocator.free(self.name);

    for (self.dependencies) |*dep| {
        allocator.free(dep.name);
        allocator.free(dep.fetch_origin.value);
    }
    allocator.free(self.dependencies);

    for (@as([]MaybeModule, @constCast(self.modules))) |*mod| {
        switch (mod.*) {
            .definition => |*def| def.deinit(allocator),
            .deferred => |_| {
                allocator.free(mod.deferred.name);
                allocator.free(mod.deferred.file_path);
            },
        }
    }
    allocator.free(self.modules);
}

/// Parse a package definition language source string to an `RPkg`.
/// * Returns null if the source is empty.
/// * Returns an error if we cannot parse the entire source.
pub fn parseSource(
    allocator: std.mem.Allocator,
    lexer_settings: analysis.Lexer.Settings,
    source_name: []const u8,
    src: []const u8,
) (analysis.Parser.Error || error{ InvalidString, InvalidEscape, InvalidPackageDefinition, InvalidModuleDefinition } || std.io.Writer.Error)!?RPkg {
    var parser = try getRPkgParser(allocator, lexer_settings, source_name, src);
    defer parser.deinit();

    var cst = try parser.parse() orelse return null;
    defer cst.deinit(allocator);

    return try parseCst(allocator, src, &cst);
}

/// Parses a `.rpkg` Concrete Syntax Tree into a `RPkg` struct.
pub fn parseCst(allocator: std.mem.Allocator, source: []const u8, cst: *const analysis.SyntaxTree) !RPkg {
    log.debug("parsing package CST:\n{f}", .{ml.Cst.treeFormatter(.{
        .source = source,
        .tree = cst,
    })});

    var def = RPkg{};
    errdefer def.deinit(allocator);

    if (cst.type != types.Package) {
        log.err("Expected root of rpkg CST to be a Package node, found {f}", .{cst.type});
        return error.InvalidPackageDefinition;
    }

    const module_operands = cst.operands.asSlice();
    if (module_operands.len != 2) return error.InvalidPackageDefinition;

    // Parse module name
    const name_cst = module_operands[0];
    if (name_cst.type != types.Identifier) return error.InvalidPackageDefinition;
    def.name = try allocator.dupe(u8, name_cst.token.data.sequence.asSlice());

    // Parse module body (a sequence of assignments)
    const body_cst = module_operands[1];
    // Body is a Block -> Seq
    if (body_cst.type != types.Block or body_cst.operands.len != 1) return error.InvalidPackageDefinition;
    const seq_cst = body_cst.operands.asSlice()[0];
    if (seq_cst.type != types.Seq) return error.InvalidPackageDefinition;

    for (seq_cst.operands.asSlice()) |*assignment_cst| {
        if (assignment_cst.type != types.Assign) return error.InvalidPackageDefinition;
        if (assignment_cst.operands.len != 2) return error.InvalidPackageDefinition;

        const key_cst = &assignment_cst.operands.asSlice()[0];
        const value_cst = &assignment_cst.operands.asSlice()[1];

        if (key_cst.type != types.Identifier) return error.InvalidPackageDefinition;
        const key = key_cst.token.data.sequence.asSlice();

        if (std.mem.eql(u8, key, "version")) {
            try parseVersion(&def.version, value_cst);
        } else if (std.mem.eql(u8, key, "dependencies")) {
            var acc = common.ArrayList(Dependency).empty;
            defer acc.deinit(allocator);

            try parseDependencies(allocator, source, value_cst, &acc);

            def.dependencies = try allocator.dupe(Dependency, acc.items);
        } else if (std.mem.eql(u8, key, "modules")) {
            var acc = common.ArrayList(MaybeModule).empty;
            defer acc.deinit(allocator);

            try parseModules(allocator, source, value_cst, &acc);

            def.modules = try allocator.dupe(MaybeModule, acc.items);
        } else {
            log.err("Unknown RPkg field {s}", .{key});
            return error.InvalidPackageDefinition;
        }
    }

    return def;
}

fn parseVersion(
    out: *common.SemVer,
    value_cst: *const analysis.SyntaxTree,
) !void {
    // TODO: support pre-release and build tag
    switch (value_cst.type) {
        types.Float => {
            // major.minor
            try parseMajorMinorVersion(out, value_cst);
        },
        types.MemberAccess => {
            // must be of the form major.minor.patch
            const major_minor = &value_cst.operands.asSlice()[0];
            const patch = &value_cst.operands.asSlice()[1];
            if (major_minor.type != types.Float or patch.type != types.Int) return error.InvalidPackageDefinition;
            try parseMajorMinorVersion(out, major_minor);
            const patch_text = patch.token.data.sequence.asSlice();
            out.patch = std.fmt.parseInt(u32, patch_text, 10) catch return error.BadEncoding;
        },
        else => {
            log.debug("Unsupported version CST type {s}", .{types.getName(value_cst.type)});
            return error.InvalidPackageDefinition;
        },
    }
}

fn parseMajorMinorVersion(
    out: *common.SemVer,
    value_cst: *const analysis.SyntaxTree,
) !void {
    const major_text = value_cst.operands.asSlice()[0].token.data.sequence.asSlice();
    const minor_text = value_cst.operands.asSlice()[1].token.data.sequence.asSlice();
    out.major = std.fmt.parseInt(u32, major_text, 10) catch return error.BadEncoding;
    out.minor = std.fmt.parseInt(u32, minor_text, 10) catch return error.BadEncoding;
}

fn parseDependencies(allocator: std.mem.Allocator, source: []const u8, value_cst: *const analysis.SyntaxTree, deps: *common.ArrayList(Dependency)) !void {
    // Expects Block -> Seq
    const seq_cst = if (value_cst.type != types.Block or value_cst.operands.len != 1) recover: {
        log.debug("Expected inputs value to be a Block containing a Seq, found {s}", .{types.getName(value_cst.type)});
        break :recover value_cst;
    } else &value_cst.operands.asSlice()[0];
    const elements = if (seq_cst.type != types.Seq) recover: {
        log.debug("Expected inputs Block to contain a Seq, found {s}", .{types.getName(seq_cst.type)});
        break :recover &.{seq_cst.*};
    } else seq_cst.operands.asSlice();

    for (elements) |*item_cst| {
        if (item_cst.type != RPkg.types.Assign or item_cst.operands.len != 2) return error.InvalidPackageDefinition;

        const alias_cst = item_cst.operands.asSlice()[0];
        const spec_cst = item_cst.operands.asSlice()[1];

        if (alias_cst.type != RPkg.types.Identifier) return error.InvalidPackageDefinition;
        if (spec_cst.type != RPkg.types.Apply or spec_cst.operands.len != 2) return error.InvalidPackageDefinition;

        const alias = try allocator.dupe(u8, alias_cst.token.data.sequence.asSlice());

        const spec_type_cst = spec_cst.operands.asSlice()[0];
        const spec_val_cst = spec_cst.operands.asSlice()[1];

        if (spec_type_cst.type != RPkg.types.Identifier) return error.InvalidPackageDefinition;
        if (spec_val_cst.type != RPkg.types.String) return error.InvalidPackageDefinition;

        const spec_type = spec_type_cst.token.data.sequence.asSlice();

        var buf: [1024]u8 = undefined;
        var writer = std.io.Writer.fixed(&buf);

        try ml.Cst.assembleString(&writer, source, &spec_val_cst);
        const spec_val = writer.buffered();

        var dep = Dependency{
            .name = alias,
            .source = item_cst.source,
            .kind = .package, // TODO: support .other
        };

        if (std.mem.eql(u8, spec_type, "pkg")) {
            const split_index = std.mem.indexOf(u8, spec_val, "@") orelse return error.InvalidPackageDefinition;
            const name = try allocator.dupe(u8, spec_val[0..split_index]);
            const version_str = spec_val[split_index + 1 ..];
            const version = common.SemVer.parse(version_str) catch {
                log.debug("Failed to parse version string {s}", .{version_str});
                return error.InvalidPackageDefinition;
            };

            dep.fetch_origin = FetchOrigin{
                .kind = .{ .archive = .registry },
                .value = name,
            };
            dep.version = version;
        } else if (std.mem.eql(u8, spec_type, "src")) {
            const locality: FetchOrigin.SourceLocation =
                if (std.mem.startsWith(u8, spec_val, "http://") or std.mem.startsWith(u8, spec_val, "https://"))
                    .url
                else if (std.mem.startsWith(u8, spec_val, "/"))
                    .absolute
                else
                    .local;
            dep.fetch_origin = FetchOrigin{
                .kind = .{ .source = locality },
                .value = try allocator.dupe(u8, spec_val),
            };
        } else if (std.mem.eql(u8, spec_type, "git")) {
            dep.fetch_origin = FetchOrigin{
                .kind = .git,
                .value = try allocator.dupe(u8, spec_val),
            };
        } else if (std.mem.eql(u8, spec_type, "arc")) {
            const locality: FetchOrigin.ArchiveLocation =
                if (std.mem.startsWith(u8, spec_val, "http://") or std.mem.startsWith(u8, spec_val, "https://"))
                    .url
                else if (std.mem.startsWith(u8, spec_val, "/"))
                    .absolute
                else
                    .local;
            dep.fetch_origin = FetchOrigin{
                .kind = .{ .archive = locality },
                .value = try allocator.dupe(u8, spec_val),
            };
        } else {
            return error.InvalidPackageDefinition;
        }

        try deps.append(allocator, dep);
    }
}

fn parseModules(allocator: std.mem.Allocator, source: []const u8, value_cst: *const analysis.SyntaxTree, mods: *common.ArrayList(MaybeModule)) !void {
    // Expects Block -> Seq
    const seq_cst = if (value_cst.type != types.Block or value_cst.operands.len != 1) recover: {
        log.debug("Expected modules value to be a Block containing a Seq, found {s}", .{types.getName(value_cst.type)});
        break :recover value_cst;
    } else &value_cst.operands.asSlice()[0];
    const elements = if (seq_cst.type != types.Seq) recover: {
        log.debug("Expected modules Block to contain a Seq, found {s}", .{types.getName(seq_cst.type)});
        break :recover &.{seq_cst.*};
    } else seq_cst.operands.asSlice();

    for (elements) |*item_cst| {
        if (item_cst.type != types.Assign) {
            log.debug("Expected module item to be an Assign, found {s}", .{types.getName(item_cst.type)});
            return error.InvalidPackageDefinition;
        }

        var name = item_cst.operands.asSlice()[0];
        const body_cst = &item_cst.operands.asSlice()[1];
        var visibility = ml.RMod.Visibility.internal;
        if (name.type == types.Apply) {
            if (name.operands.len != 2 or name.operands.asSlice()[0].type != types.Identifier or !std.mem.eql(u8, name.operands.asSlice()[0].token.data.sequence.asSlice(), "export")) return error.InvalidPackageDefinition;
            visibility = .exported;
            name = name.operands.asSlice()[1];
        }
        if (name.type != types.Identifier) {
            log.debug("Expected module name to be an Identifier, found {s}", .{types.getName(name.type)});
            return error.InvalidPackageDefinition;
        }

        if (body_cst.type == types.Module) {
            var module = try ml.RMod.parseCst(allocator, source, body_cst);
            module.name = try allocator.dupe(u8, name.token.data.sequence.asSlice());
            module.visibility = visibility;
            try mods.append(allocator, .{ .definition = module });
        } else {
            if (body_cst.type != types.String) {
                log.debug("Expected module body to be a String (file path), found {s}", .{types.getName(body_cst.type)});
                return error.InvalidPackageDefinition;
            }

            var buf: [1024]u8 = undefined;
            var writer = std.io.Writer.fixed(&buf);

            try ml.Cst.assembleString(&writer, source, body_cst);
            const path = writer.buffered();

            try mods.append(allocator, .{
                .deferred = .{
                    .name = try allocator.dupe(u8, name.token.data.sequence.asSlice()),
                    .visibility = visibility,
                    .file_path = try allocator.dupe(u8, path),
                },
            });
        }
    }
}

/// Get a parser for the package definition language.
pub fn getRPkgParser(
    allocator: std.mem.Allocator,
    lexer_settings: analysis.Lexer.Settings,
    source_name: []const u8,
    src: []const u8,
) analysis.Parser.Error!analysis.Parser {
    const ml_syntax = getRPkgSyntax();
    return ml_syntax.createParser(allocator, lexer_settings, src, .{
        .ignore_space = false,
        .source_name = source_name,
    });
}

/// Get the syntax for the package definition language.
pub fn getRPkgSyntax() *const analysis.Parser.Syntax {
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

    bindRPkgSyntax(&static.syntax.?) catch |err| {
        std.debug.panic("Cannot getRPkgSyntax: {s}", .{@errorName(err)});
    };

    return &static.syntax.?;
}

pub fn bindRPkgSyntax(out: *analysis.Parser.Syntax) !void {
    try ml.RMod.bindRModSyntax(out);

    try out.bindNud(syntax_defs.nud.package());
}

pub const types = make_types: {
    var fresh = ml.RMod.types.fresh;

    break :make_types .{
        .Int = ml.RMod.types.Int,
        .Float = ml.RMod.types.Float,
        .String = ml.RMod.types.String,
        .StringElement = ml.RMod.types.StringElement,
        .StringSentinel = ml.RMod.types.StringSentinel,
        .Identifier = ml.RMod.types.Identifier,
        .Block = ml.RMod.types.Block,
        .Seq = ml.RMod.types.Seq,
        .List = ml.RMod.types.List,
        .Apply = ml.RMod.types.Apply,
        .Binary = ml.RMod.types.Binary,
        .Prefix = ml.RMod.types.Prefix,
        .Decl = ml.RMod.types.Decl,
        .Assign = ml.RMod.types.Assign,
        .Lambda = ml.RMod.types.Lambda,
        .Symbol = ml.RMod.types.Symbol,
        .MemberAccess = ml.RMod.types.MemberAccess,
        .Module = ml.RMod.types.Module,
        .Package = fresh.next(),
        .fresh = fresh,
        .getName = struct {
            pub fn RPkgTypeName(t: analysis.SyntaxTree.Type) []const u8 {
                return switch (t) {
                    types.Package => "Package",
                    else => return ml.RMod.types.getName(t),
                };
            }
        }.RPkgTypeName,
    };
};

pub const syntax_defs = struct {
    pub const nud = struct {
        pub fn package() analysis.Parser.Nud {
            return analysis.Parser.createNud(
                "rpkg_package",
                std.math.maxInt(i16),
                .{ .standard = .{ .sequence = .{ .standard = .fromSlice("package") } } },
                null,
                struct {
                    pub fn package(
                        parser: *analysis.Parser,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("package: parsing token {f}", .{token});
                        try parser.lexer.advance(); // discard package token
                        var name = try parser.pratt(std.math.minInt(i16)) orelse {
                            log.debug("package: no name found; panic", .{});
                            return error.UnexpectedInput;
                        };
                        errdefer name.deinit(parser.allocator);

                        if (try parser.lexer.peek()) |next_tok| {
                            if (next_tok.tag == .special and next_tok.data.special.escaped == false and next_tok.data.special.punctuation == .dot) {
                                log.debug("package: found dot token {f}", .{next_tok});
                                try parser.lexer.advance(); // discard dot
                                var inner = try parser.pratt(std.math.minInt(i16) + 1) orelse {
                                    log.debug("package: no inner expression found; panic", .{});
                                    return error.UnexpectedEof;
                                };
                                errdefer inner.deinit(parser.allocator);
                                log.debug("package: got inner expression {f}", .{inner});
                                const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                                buff[0] = name;
                                buff[1] = inner;
                                return analysis.SyntaxTree{
                                    .source = .{ .name = parser.settings.source_name, .location = token.location },
                                    .precedence = bp,
                                    .type = types.Package,
                                    .token = token,
                                    .operands = .fromSlice(buff),
                                };
                            } else {
                                log.debug("package: expected dot token, found {f}; panic", .{next_tok});
                                return error.UnexpectedInput;
                            }
                        } else {
                            log.debug("package: no dot token found; panic", .{});
                            return error.UnexpectedEof;
                        }
                    }
                }.package,
            );
        }
    };
};
