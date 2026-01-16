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
