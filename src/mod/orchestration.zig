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

pub const RPkg = meta_language.RPkg;
pub const RMod = meta_language.RMod;

pub fn cleanupCache(cache_override: ?[]const u8) error{InvalidCachePath}!void {
    const cwd = std.fs.cwd(); // NOTE: Closing the Dir returned here is checked illegal behavior.
    cwd.deleteTree(cache_override orelse ".rcache") catch |err| {
        log.debug("Failed to cleanup cache directory: {s} / {s}", .{ cache_override orelse ".rcache", @errorName(err) });
        return error.InvalidCachePath;
    };
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    packages: common.StringMap(RPkg) = .empty,
    rwd_path: []const u8,
    root_rel: []const u8,
    rwd: std.fs.Dir,
    cache_path: []const u8,
    cache_dir: std.fs.Dir,

    pub fn init(allocator: std.mem.Allocator, root_pkg_def_path: []const u8, cache_override: ?[]const u8) error{ OutOfMemory, InvalidRootPkgPath, AmbiguousRootPkgPath, InvalidCachePath }!Context {
        const cwd = std.fs.cwd(); // NOTE: Closing the Dir returned here is checked illegal behavior.

        const ext = std.fs.path.extension(root_pkg_def_path);

        var self = if (!std.mem.eql(u8, ext, ".rpkg")) dir: {
            if (!std.mem.eql(u8, ext, "")) {
                log.debug("Root package path must be a .rpkg file or a directory; got: {s}", .{root_pkg_def_path});
                return error.InvalidRootPkgPath;
            }

            const rwd_path = cwd.realpathAlloc(allocator, root_pkg_def_path) catch |err| {
                log.debug("Failed to resolve root package directory realpath: {s} / {s}", .{ root_pkg_def_path, @errorName(err) });
                return error.InvalidRootPkgPath;
            };
            errdefer allocator.free(rwd_path);

            var rwd = cwd.openDir(rwd_path, .{ .iterate = true }) catch |err| {
                log.debug("Failed to open root package directory: {s} / {s}", .{ root_pkg_def_path, @errorName(err) });
                return error.InvalidRootPkgPath;
            };
            errdefer rwd.close();

            var it = rwd.iterate();
            var package_rel: ?[]const u8 = null;
            errdefer if (package_rel) |p| allocator.free(p);

            while (it.next() catch |err| {
                log.debug("Failed to iterate root package directory: {s} / {s}", .{ root_pkg_def_path, @errorName(err) });
                return error.InvalidRootPkgPath;
            }) |entry| {
                if (std.mem.eql(u8, std.fs.path.extension(entry.name), ".rpkg")) {
                    if (package_rel != null) {
                        log.debug("Multiple .rpkg files found in root package directory: {s}", .{root_pkg_def_path});
                        return error.AmbiguousRootPkgPath;
                    }
                    package_rel = try allocator.dupe(u8, entry.name);
                }
            }

            break :dir Context{
                .allocator = allocator,
                .rwd_path = rwd_path,
                .root_rel = package_rel orelse {
                    log.debug("No .rpkg file found in root package directory: {s}", .{root_pkg_def_path});
                    return error.InvalidRootPkgPath;
                },
                .rwd = rwd,
                .cache_path = "",
                .cache_dir = undefined,
            };
        } else file: {
            const realpath = cwd.realpathAlloc(allocator, root_pkg_def_path) catch |err| {
                log.debug("Failed to resolve root pkg file realpath: {s} / {s}", .{ root_pkg_def_path, @errorName(err) });
                return error.InvalidRootPkgPath;
            };
            defer allocator.free(realpath);

            const rwd_path = try allocator.dupe(u8, std.fs.path.dirname(realpath) orelse {
                log.debug("Failed to get dirname for root pkg path: {s}; Note that system root is not allowed.", .{realpath});
                return error.InvalidRootPkgPath;
            });

            var rwd = cwd.openDir(rwd_path, .{ .iterate = true }) catch |err| {
                log.debug("Failed to open root working directory: {s} / {s}", .{ rwd_path, @errorName(err) });
                return error.InvalidRootPkgPath;
            };
            errdefer rwd.close();

            const package_rel = try allocator.dupe(u8, std.fs.path.basename(realpath));
            errdefer allocator.free(package_rel);

            break :file Context{
                .allocator = allocator,
                .rwd_path = rwd_path,
                .root_rel = package_rel,
                .rwd = rwd,
                .cache_path = "",
                .cache_dir = undefined,
            };
        };
        errdefer self.deinit();

        var cache_dir = cwd.makeOpenPath(cache_override orelse ".rcache", .{}) catch |err| {
            log.debug("Failed to open cache directory: {s} / {s}", .{ cache_override orelse ".rcache", @errorName(err) });
            return error.InvalidCachePath;
        };
        errdefer cache_dir.close();

        self.cache_path = cwd.realpathAlloc(allocator, ".") catch |err| {
            log.debug("Failed to resolve cache path realpath: {s} / {s}", .{ cache_override orelse ".rcache", @errorName(err) });
            cache_dir.close();
            return error.InvalidCachePath;
        };
        self.cache_dir = cache_dir;

        return self;
    }

    pub fn deinit(self: *Context) void {
        self.packages.deinit(self.allocator);
        self.allocator.free(self.rwd_path);
        self.allocator.free(self.root_rel);
        self.rwd.close();
        if (self.cache_path.len != 0) {
            self.allocator.free(self.cache_path);
            self.cache_dir.close();
        }
    }
};
