const std = @import("std");
const Build = std.Build;
const Builder = @import("Utils").Module.Build.Module;
const Manifest = Builder.Manifest;
const TypeUtils = @import("Utils").Module.Type;

const log = std.log.scoped(.build);

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const manifest = try Manifest.readFile(b.allocator, "./build.zig.zon");

    const config = b.addOptions();
    config.addOption(std.SemanticVersion, "version", manifest.version);

    const Rir = b.dependency("Rir", .{
        .target = target,
        .optimize = optimize,
    });

    const Utils = b.dependency("Utils", .{
        .target = target,
        .optimize = optimize,
    });

    const Config = b.createModule(.{
        .root_source_file = b.path("src/Config.zig"),
        .target = target,
        .optimize = optimize,
    });

    const Rml = b.addModule("Rml", .{
        .root_source_file = b.path("src/mod/Rml.zig"),
        .target = target,
        .optimize = optimize,
    });

    const testRml = b.addTest(.{
        .name = "test-rml",
        .root_source_file = b.path("src/mod/Rml.zig"),
        .target = target,
        .optimize = optimize,
    });

    const rmlExe = b.addExecutable(.{
        .name = "rml",
        .root_source_file = b.path("src/bin/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const testExe = b.addTest(.{
        .name = "test-exe",
        .root_source_file = b.path("src/bin/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    Config.addOptions("config", config);

    Rml.addImport("Config", Config);
    Rml.addImport("Utils", Utils.module("Utils"));

    testRml.root_module.addImport("Config", Config);
    testRml.root_module.addImport("Utils", Utils.module("Utils"));

    rmlExe.root_module.addImport("Rml", Rml);
    rmlExe.root_module.addImport("Config", Config);
    rmlExe.root_module.addImport("Utils", Utils.module("Utils"));

    testExe.root_module.addImport("Rml", &testRml.root_module);
    testExe.root_module.addImport("Config", Config);
    testExe.root_module.addImport("Utils", Utils.module("Utils"));

    const installStep = b.default_step;
    const runStep = b.step("run", "Run the exe");
    const unitTestsStep = b.step("unit-tests", "Run the unit tests");
    const checkStep = b.step("check", "Semantic analysis");
    const cliTestsStep = b.step("cli-tests", "Run the CLI tests");
    const testStep = b.step("test", "Run all tests");

    const runRml = b.addRunArtifact(rmlExe);
    if (b.args) |args| runRml.addArgs(args);

    installStep.dependOn(&b.addInstallArtifact(rmlExe, .{}).step);
    runStep.dependOn(&runRml.step);
    unitTestsStep.dependOn(&b.addRunArtifact(testExe).step);
    unitTestsStep.dependOn(&b.addRunArtifact(testRml).step);
    testStep.dependOn(unitTestsStep);
    testStep.dependOn(cliTestsStep);
    checkStep.dependOn(&testExe.step);
    checkStep.dependOn(&testRml.step);
}
