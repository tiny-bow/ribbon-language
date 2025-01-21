const std = @import("std");

pub fn build(b: *std.Build) !void {
    const defaultTarget = b.standardTargetOptions(.{});
    const defaultOptimize = b.standardOptimizeOption(.{});

    const Utils = b.dependency("Utils", .{
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });

    const ISA = b.dependency("ISA", .{
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });

    const Rbc = b.dependency("Rbc", .{
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });

    const Rir = b.addModule("Rir", .{
        .root_source_file = b.path("src/mod/Rir.zig"),
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });
    Rir.addImport("Utils", Utils.module("Utils"));
    Rir.addImport("ISA", ISA.module("ISA"));
    Rir.addImport("Rbc:Core", Rbc.module("Core"));
    Rir.addImport("Rbc:Builder", Rbc.module("Builder"));

    const RbcGenerator = b.addModule("RbcGenerator", .{
        .root_source_file = b.path("src/mod/RbcGenerator.zig"),
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });
    RbcGenerator.addImport("Utils", Utils.module("Utils"));
    RbcGenerator.addImport("Rbc:Core", Rbc.module("Core"));
    RbcGenerator.addImport("Rbc:Builder", Rbc.module("Builder"));
    RbcGenerator.addImport("Rir", Rir);

    const main = b.addExecutable(.{
        .name = "main",
        .root_source_file = b.path("src/bin/main.zig"),
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });
    main.root_module.addImport("Utils", Utils.module("Utils"));
    main.root_module.addImport("Rir", Rir);
    main.root_module.addImport("RbcGenerator", RbcGenerator);

    const testRir = b.addTest(.{
        .root_source_file = b.path("src/mod/Rir.zig"),
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });
    testRir.root_module.addImport("Utils", Utils.module("Utils"));
    testRir.root_module.addImport("ISA", ISA.module("ISA"));
    testRir.root_module.addImport("Rbc:Core", Rbc.module("Core"));
    testRir.root_module.addImport("Rbc:Builder", Rbc.module("Builder"));

    const testRbcGenerator = b.addTest(.{
        .root_source_file = b.path("src/mod/RbcGenerator.zig"),
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });
    testRbcGenerator.root_module.addImport("Utils", Utils.module("Utils"));
    testRbcGenerator.root_module.addImport("Rbc:Core", Rbc.module("Core"));
    testRbcGenerator.root_module.addImport("Rbc:Builder", Rbc.module("Builder"));
    testRbcGenerator.root_module.addImport("Rir", Rir);

    const runTest = b.addRunArtifact(main);
    runTest.expectExitCode(0);

    const installStep = b.default_step;
    installStep.dependOn(&b.addInstallArtifact(main, .{}).step);

    const checkStep = b.step("check", "Run semantic analysis");
    checkStep.dependOn(&testRir.step);
    checkStep.dependOn(&testRbcGenerator.step);
    checkStep.dependOn(&main.step);

    const testStep = b.step("test", "Run unit tests");
    testStep.dependOn(&b.addRunArtifact(testRir).step);
    testStep.dependOn(&b.addRunArtifact(testRbcGenerator).step);
    testStep.dependOn(&runTest.step);

    const runStep = b.step("run", "Run the program");
    runStep.dependOn(&b.addRunArtifact(main).step);
}
