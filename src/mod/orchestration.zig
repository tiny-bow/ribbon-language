//! This module implements build orchestration for Ribbon projects.
//!
//! The orchestration service is responsible for loading and parsing Ribbon's meta files,
//! ie the .rmod and .rpkg formats.
//!
//! The orchestrator is agnostic to the backend service being used,
//! in order to support both compilation and LSP services.
//!
//! The orchestration service depends on the frontend service to perform semantic analysis and IR generation.
//!
//! Communication between frontend and backend is done exclusively through the orchestrator,
//! using Ribbon IR's Serializable Module Artifact (SMA) format.
//!
/// Canonical paths for module GUIDs are generated from:
/// * the relative path from the package source_path to the module source_path
/// * git url of the dependency package + module relative path within that package
/// * a full absolute path when using machine-specific modules (discouraged)
const orchestration = @This();

const std = @import("std");
const log = std.log.scoped(.orchestration);

const common = @import("common");
const core = @import("core");
const ir = @import("ir");
const analysis = @import("analysis");
const meta_language = @import("meta_language");
const frontend = @import("frontend");
const backend = @import("backend");

test {
    //std.debug.print("semantic analysis for orchestration\n", .{});
    std.testing.refAllDecls(@This());
}

/// Defines a Ribbon package. This is the root structure parsed from a .rpkg file.
pub const Package = struct {
    /// The package's canonical name.
    name: []const u8,
    /// The .rpkg file's canonical source path; may be absolute or relative to the compiler's working directory.
    source_path: []const u8,
    /// The package's version specifier.
    version: common.SemVer,
    /// The package's dependencies.
    dependencies: []const Dependency,
    /// The Ribbon modules defined within this package.
    modules: []const Module,
};

/// Defines a dependency package request for a higher-level Ribbon package.
pub const Dependency = struct {
    /// The dependency's canonical name within the root package.
    name: []const u8,
    /// The source code location within the .rpkg file where this dependency was defined.
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
        /// The orchestrator will look for a .rpkg file at the FetchOrigin.
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

/// Defines a Ribbon module. This is the root structure parsed from a .rmod file, or inline within a .rpkg file.
pub const Module = struct {
    /// The module's canonical name.
    name: []const u8,
    /// The module definition's (.rmod or inline) source tracking location; may be absolute or relative depending on context.
    source: analysis.Source,
    /// The module's globally unique identifier, generated canonically from its dependency and source path.
    guid: ir.Module.GUID,
    /// Whether this module is directly accessible to other modules outside its package.
    visibility: Visibility,
    /// Modules imported by this module.
    imports: []const Import.Aliased,
    /// Language extensions used by this module, which must be compiled prior to this module.
    extensions: []const Import.Extension,
    /// All source files that are part of this module. Paths may be absolute or relative depending on context.
    /// Source files are unordered and all contribute to a single module context.
    inputs: []const []const u8,
};

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
    package: ?[]const u8,
    /// The module's canonical name as exported from its package.
    module: []const u8,

    /// An imported module, optionally with an alias.
    pub const Aliased = struct {
        /// The imported module.
        import: Import,
        /// An optional alias for the imported module to be referred to by, within the importing module.
        alias: ?[]const u8,
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
