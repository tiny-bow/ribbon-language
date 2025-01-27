const std = @import("std");
const Build = std.Build;

const log = std.log.scoped(.build);


const MOD_PATH = "src/mod";
const BIN_PATH = "src/bin";

const PACKAGES: []const [:0]const u8 = &.{
    "zg",
};

const MODULES: []const Module = &.{
    .{
        .name = "utils",
        .dependencies = &.{
            .external("zg", "GenCatData"),
            .external("zg", "PropsData"),
            .external("zg", "CaseData"),
            .external("zg", "CaseFold"),
            .external("zg", "DisplayWidth"),
        },
    },
    .{
        .name = "Rml",
        .dependencies = &.{
            .internal("utils"),
        },
    },
    .{
        .name = "Rvm",
        .dependencies = &.{
            .internal("utils"),
            .internal("Rbc"),
        },
    },
    .{
        .name = "Rir",
        .dependencies = &.{
            .internal("utils"),
            .internal("Rbc"),
            .internal("Isa"),
        },
    },
    .{
        .name = "Rbc",
        .dependencies = &.{
            .internal("utils"),
            .internal("Isa"),
        },
    },
    .{
        .name = "RbcGenerator",
        .dependencies = &.{
            .internal("utils"),
            .internal("Rir"),
            .internal("Rbc"),
            .internal("RbcBuilder"),
        },
    },
    .{
        .name = "RbcBuilder",
        .dependencies = &.{
            .internal("utils"),
            .internal("Rbc"),
        },
    },
    .{
        .name = "Isa",
        .dependencies = &.{
            .internal("utils"),
        },
    },
};

const BINARIES: []const Binary = &.{
    .{
        .name = "rml",
        .dependencies = &.{
            .internal("Rml"),
        },
    },
    .{
        .name = "rir",
        .dependencies = &.{
            .internal("Rir"),
            .internal("RbcGenerator"),
        },
    },
    .{
        .name = "rvm",
        .dependencies = &.{
            .internal("utils"),
            .internal("Rvm"),
            .internal("RbcBuilder"),
        },
    },
};

pub fn build(zigBuild: *Build) !void {
    var b = Builder.init(zigBuild);

    const installStep = b.build.default_step;
    const checkStep = b.build.step("check", "Run semantic analysis");
    // const testStep = b.build.step("test", "Run unit tests");

    for (PACKAGES) |packageName| {
        const ext = b.build.dependency(packageName, .{.target = b.target, .optimize = b.optimize});

        try b.package_map.put(packageName, ext);
    }

    for (MODULES) |mod| {
        const modPathStr = b.fmt("{s}/{s}.zig", .{MOD_PATH, mod.name});
        const modPath = b.path(modPathStr);

        const moduleStandard = b.build.createModule(.{
            .root_source_file = modPath,
            .target = b.target,
            .optimize = b.optimize,
        });

        const moduleTest = b.build.addTest(.{
            .name = b.fmt("{s}-test", .{mod.name}),
            .root_source_file = modPath,
            .target = b.target,
            .optimize = b.optimize,
        });

        if (mod.exported) {
            try b.build.modules.put(mod.name, moduleStandard);
        }

        try b.module_map.put(mod.name, moduleStandard);
        try b.test_map.put(mod.name, &moduleTest.root_module);

        // const runTest = b.build.addRunArtifact(moduleTest);
        // const unitTestStep = b.build.step(b.fmt("test-{s}", .{mod.name}), b.fmt("Run unit tests for the {s} module", .{mod.name}));
        const unitCheckStep = b.build.step(b.fmt("check-{s}", .{mod.name}), b.fmt("Run semantic analysis for the {s} module", .{mod.name}));

        checkStep.dependOn(&moduleTest.step);
        unitCheckStep.dependOn(&moduleTest.step);
        // testStep.dependOn(&runTest.step);
        // unitTestStep.dependOn(&runTest.step);
    }

    for (MODULES) |mod| {
        const moduleStandard = b.module_map.get(mod.name).?;
        b.addDependencies(.standard, moduleStandard, mod.dependencies);

        const moduleTest = b.test_map.get(mod.name).?;
        b.addDependencies(.testing, moduleTest, mod.dependencies);
    }

    for (BINARIES) |bin| {
        const binPathStr = b.fmt("{s}/{s}.zig", .{BIN_PATH, bin.name});
        const binPath = b.path(binPathStr);

        const binaryStandard = b.build.addExecutable(.{
            .name = bin.name,
            .root_source_file = binPath,
            .target = b.target,
            .optimize = b.optimize,
        });

        const binaryTest = b.build.addTest(.{
            .name = b.fmt("{s}-test", .{bin.name}),
            .root_source_file = binPath,
            .target = b.target,
            .optimize = b.optimize,
        });

        b.addDependencies(.standard, &binaryStandard.root_module, bin.dependencies);
        b.addDependencies(.testing, &binaryTest.root_module, bin.dependencies);

        const run = b.build.addRunArtifact(binaryStandard);
        const installBinary = b.build.addInstallArtifact(binaryStandard, .{});


        const runStep = b.build.step(b.fmt("run-{s}", .{bin.name}), b.fmt("Build & run the {s} executable", .{bin.name}));
        const unitInstallStep = b.build.step(bin.name, b.fmt("Build the {s} executable", .{bin.name}));
        const unitCheckStep = b.build.step(b.fmt("check-{s}", .{bin.name}), b.fmt("Run semantic analysis for the {s} executable", .{bin.name}));
        // const unitTestStep = b.build.step(b.fmt("test-{s}", .{bin.name}), b.fmt("Run unit tests for the {s} executable", .{bin.name}));

        // const runTest = b.build.addRunArtifact(binaryTest);

        installStep.dependOn(&installBinary.step);
        unitInstallStep.dependOn(&installBinary.step);

        runStep.dependOn(&run.step);

        checkStep.dependOn(&binaryTest.step);
        unitCheckStep.dependOn(&binaryTest.step);

        // testStep.dependOn(&runTest.step);
        // unitTestStep.dependOn(&runTest.step);
    }
}


const Module = struct {
    name: [:0]const u8,
    exported: bool = true,
    dependencies: []const Dependency = &.{},
};

const Binary = struct {
    name: [:0]const u8,
    dependencies: []const Dependency = &.{},
};

const Dependency = union(enum) {
    external_module: struct { package_name: [:0]const u8, module_name: [:0]const u8 },
    internal_module: struct { module_name: [:0]const u8 },

    fn external(pkgName: [:0]const u8, modName: [:0]const u8) Dependency {
        return .{ .external_module = .{ .package_name = pkgName, .module_name = modName } };
    }

    fn internal(modName: [:0]const u8) Dependency {
        return .{ .internal_module = .{ .module_name = modName } };
    }
};

const Builder = struct {
    build: *Build,

    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    package_map: std.StringHashMap(*Build.Dependency),
    module_map: std.StringHashMap(*Build.Module),
    test_map: std.StringHashMap(*Build.Module),

    fn init(b: *Build) Builder {
        return Builder {
            .build = b,

            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),

            .package_map = std.StringHashMap(*Build.Dependency).init(b.allocator),
            .module_map = std.StringHashMap(*Build.Module).init(b.allocator),
            .test_map = std.StringHashMap(*Build.Module).init(b.allocator),
        };
    }

    fn addDependencies(self: *Builder, mode: enum { standard, testing }, module: *Build.Module, dependencies: []const Dependency) void {
        const internals = switch (mode) {
            .standard => &self.module_map,
            .testing => &self.test_map,
        };

        for (dependencies) |depUnion| {
            switch (depUnion) {
                .external_module => |dep| {
                    const package = self.package_map.get(dep.package_name)
                        orelse @panic(self.fmt("package not found: {s}", .{dep.package_name}));
                    const dependencyName = self.build.fmt("{s}/{s}", .{dep.package_name, dep.module_name});

                    module.addImport(dependencyName, package.module(dep.module_name));
                },
                .internal_module => |dep| {
                    const dependency = internals.get(dep.module_name)
                        orelse @panic(self.fmt("module not found: {s}", .{dep.module_name}));

                    module.addImport(dep.module_name, dependency);
                },
            }
        }
    }

    fn fmt(self: *Builder, comptime f: []const u8, as: anytype) []u8 {
        return self.build.fmt(f, as);
    }

    fn path(self: *Builder, p: []const u8) Build.LazyPath {
        return self.build.path(p);
    }
};
