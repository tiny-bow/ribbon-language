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
name: []const u8,
/// The package definition's source path; may be absolute or relative to the compiler's working directory.
source_path: []const u8,
/// The package's version specifier.
version: common.SemVer,
/// The package's dependencies.
dependencies: []const Dependency,
/// The Ribbon modules defined within this package.
modules: []const ml.RMod,

/// Defines a dependency package request for a higher-level Ribbon package.
pub const Dependency = struct {
    /// The dependency's canonical name within the root package.
    name: []const u8,
    /// The source code location within the package definition where this dependency was defined.
    source: analysis.Source,
    /// The kind of dependency; either a package or arbitrary files.
    kind: Dependency.Kind,
    /// Where and how to fetch the dependency's data.
    fetch_origin: FetchOrigin,
    /// The version specifier for the dependency.
    version: common.SemVer,

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
        /// The `value` is a path relative to the current working directory.
        local,
        /// The `value` is an absolute path in the filesystem.
        /// The orchestrator should issue a warning unless suppressed.
        absolute,
    };
};

// fn parseDependencies(allocator: std.mem.Allocator, source: []const u8, value_cst: *const analysis.SyntaxTree, map: *common.StringMap(Dependency)) !void {
//     // Expects Block -> Seq
//     if (value_cst.type != RMod.types.Block or value_cst.operands.len != 1) return error.InvalidModuleDefinition;
//     const seq_cst = value_cst.operands.asSlice()[0];
//     if (seq_cst.type != RMod.types.Seq) return error.InvalidModuleDefinition;

//     for (seq_cst.operands.asSlice()) |item_cst| {
//         if (item_cst.type != RMod.types.Assign or item_cst.operands.len != 2) return error.InvalidModuleDefinition;

//         const alias_cst = item_cst.operands.asSlice()[0];
//         const spec_cst = item_cst.operands.asSlice()[1];

//         if (alias_cst.type != RMod.types.Identifier) return error.InvalidModuleDefinition;
//         if (spec_cst.type != RMod.types.Apply or spec_cst.operands.len != 2) return error.InvalidModuleDefinition;

//         const alias = try allocator.dupe(u8, alias_cst.token.data.sequence.asSlice());

//         const spec_type_cst = spec_cst.operands.asSlice()[0];
//         const spec_val_cst = spec_cst.operands.asSlice()[1];

//         if (spec_type_cst.type != RMod.types.Identifier) return error.InvalidModuleDefinition;
//         if (spec_val_cst.type != RMod.types.String) return error.InvalidModuleDefinition;

//         const spec_type = spec_type_cst.token.data.sequence.asSlice();

//         var buf = std.io.Writer.Allocating.init(allocator);
//         try ml.Cst.assembleString(&buf.writer, source, &spec_val_cst);
//         const spec_val = try buf.toOwnedSlice();

//         const specifier: Dependency = if (std.mem.eql(u8, spec_type, "package"))
//             .{ .package = spec_val }
//         else if (std.mem.eql(u8, spec_type, "git"))
//             .{ .git = spec_val }
//         else if (std.mem.eql(u8, spec_type, "path"))
//             .{ .path = spec_val }
//         else
//             return error.InvalidModuleDefinition;

//         try map.put(allocator, alias, specifier);
//     }
// }
