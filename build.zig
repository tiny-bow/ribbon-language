const std = @import("std");

const SUPPORTED_ARCH = [_]std.Target.Cpu.Arch{ .x86_64, .aarch64 };
const ARCH_PATHS = [_][]const u8{ x64_path, aarch64_path };
const ARCH_MODULES = [_][]const ModuleDef{ &x64_arch_modules, &aarch64_arch_modules };
const SUPPORTED_OS = [_]std.Target.Os.Tag{ .windows, .linux };

const ModuleDef = struct {
    name: []const u8,
    imports: []const []const u8 = &.{},
};

const src_path = "src/";

const module_path = src_path ++ "mod/";
const test_path = src_path ++ "test/";
const bin_path = src_path ++ "bin/";

const tool_path = bin_path ++ "tools/";

const modules = [_]ModuleDef{
    .{
        .name = "backend",
        .imports = &.{ "ir", "core", "bytecode", "common" },
    },
    .{
        .name = "binary",
        .imports = &.{ "core", "common" },
    },
    .{
        .name = "bytecode",
        .imports = &.{ "common", "core", "binary", "Instruction" },
    },
    .{ .name = "common" },
    .{
        .name = "core",
        .imports = &.{ "common", "build_info" },
    },
    .{
        .name = "interpreter",
        .imports = &.{ "core", "common", "Instruction" },
    },
    .{
        .name = "ir",
        .imports = &.{ "core", "common", "analysis", "bytecode" },
    },
    .{
        .name = "meta_language",
        .imports = &.{ "rg", "common", "analysis", "core", "ir", "backend" },
    },
    .{
        .name = "orchestration",
        .imports = &.{
            "core",
            "common",
            "ir",
            "frontend",
        },
    },
    .{
        .name = "frontend",
        .imports = &.{
            "common",
            "core",
            "ir",
            "analysis",
            "bytecode",
            "orchestration",
            "meta_language",
        },
    },
    .{
        .name = "analysis",
        .imports = &.{ "rg", "common" },
    },
};

const x64_path = module_path ++ "arch/x64/";
const x64_arch_modules = [_]ModuleDef{
    .{
        .name = "abi",
        .imports = &.{ "core", "assembler" },
    },
    .{
        .name = "machine",
        .imports = &.{ "abi", "common", "core", "assembler" },
    },
};

const aarch64_path = module_path ++ "arch/aarch64/";
const aarch64_arch_modules = [_]ModuleDef{
    // TODO: add "assembler" when we have an aarch64 assembler
    .{
        .name = "abi",
        .imports = &.{"core"},
    },
    .{
        .name = "machine",
        .imports = &.{ "abi", "common", "core" },
    },
};

const tests = [_][]const u8{
    "bc_integration",
    "bc_interp",
    "binary_integration",
    "ir_integration",
    "ml_integration",
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const arch_path, const arch_modules, const assembler_mod = validateTarget(b, target, optimize);

    // parse the zon to extract version for build_info //
    const zon = parseZon(b, struct { version: []const u8 });

    const version = std.SemanticVersion.parse(zon.version) catch {
        std.debug.panic("Cannot parse `{s}` as a semantic version string", .{zon.version});
    };

    // create build_info options //
    const build_info_opts = b.addOptions();
    build_info_opts.addOption(std.SemanticVersion, "version", version);

    // create steps //
    const gen_step = b.step("gen", "CLI access for the isa code generator");
    const check_step = b.step("check", "Run semantic source");
    const test_step = b.step("unit-test", "Run all unit tests");
    const docs_step = b.step("docs", "Generate documentation");
    const isa_step = b.step("isa", "Generate ISA documentation");
    const run_step = b.step("run", "Run the ribbon driver");
    const install_step = b.default_step;

    // dependency modules //
    const rg_mod = b.dependency("rg", .{
        .target = target,
        .optimize = optimize,
    }).module("rg");

    const repl_mod = b.dependency("repl", .{
        .target = target,
        .optimize = optimize,
    }).module("repl");

    // special modules //
    const Instruction_mod = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });

    const build_info_mod = build_info_opts.createModule();

    const isa_mod = b.createModule(.{
        .root_source_file = b.path("src/gen-base/zig/isa.zig"),
        .target = target,
        .optimize = optimize,
    });

    // binary mods //
    const gen_mod = b.createModule(.{
        .root_source_file = b.path(tool_path ++ "gen.zig"),
        .target = target,
        .optimize = optimize,
    });

    const main_mod = b.createModule(.{
        .root_source_file = b.path(bin_path ++ "main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // the exported ribbon module //
    const ribbon_mod = b.addModule("ribbon_language", .{
        .root_source_file = b.path(module_path ++ "root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // initialize module map with special modules //
    var module_map = std.StringHashMap(*std.Build.Module).init(b.allocator);

    module_map.put("rg", rg_mod) catch @panic("OOM");
    module_map.put("repl", repl_mod) catch @panic("OOM");
    module_map.put("isa", isa_mod) catch @panic("OOM");
    module_map.put("Instruction", Instruction_mod) catch @panic("OOM");
    module_map.put("build_info", build_info_mod) catch @panic("OOM");

    // create x64-specific modules //
    if (assembler_mod) |asmm| {
        module_map.put("assembler", asmm) catch @panic("OOM");
    }

    for (arch_modules) |mod_def| {
        const mod = b.createModule(.{
            .root_source_file = arch_path.path(b, b.fmt("{s}.zig", .{mod_def.name})),
            .target = target,
            .optimize = optimize,
        });

        module_map.put(mod_def.name, mod) catch @panic("OOM");
    }

    // create all standard modules //
    for (modules) |mod_def| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}{s}.zig", .{ module_path, mod_def.name })),
            .target = target,
            .optimize = optimize,
        });

        module_map.put(mod_def.name, mod) catch @panic("OOM");
    }

    // link all standard and arch modules //
    for (modules) |mod_def| linkModule(&module_map, mod_def);
    for (arch_modules) |mod_def| linkModule(&module_map, mod_def);

    // link all modules into root //
    {
        var it = module_map.iterator();
        while (it.next()) |entry| {
            ribbon_mod.addImport(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    // link main module //
    main_mod.addImport("ribbon_language", ribbon_mod);
    main_mod.addImport("repl", repl_mod);

    // link required modules into generator //
    gen_mod.addImport("isa", module_map.get("isa").?);
    gen_mod.addImport("abi", module_map.get("abi").?);

    if (assembler_mod) |asmm| {
        gen_mod.addImport("assembler", asmm);
    }
    gen_mod.addImport("core", module_map.get("core").?);
    gen_mod.addImport("common", module_map.get("common").?);
    gen_mod.addAnonymousImport("Isa_intro.md", .{
        .root_source_file = b.path("src/gen-base/markdown/Isa_intro.md"),
    });
    gen_mod.addAnonymousImport("Instruction_intro.zig", .{
        .root_source_file = b.path("src/gen-base/zig/Instruction_intro.zig"),
    });

    // link required modules into generated code //
    Instruction_mod.addImport("core", module_map.get("core").?);
    Instruction_mod.addImport("common", module_map.get("common").?);

    // add the export module to the map for test gen //
    module_map.put("ribbon_language", ribbon_mod) catch @panic("OOM");

    // generator tool //
    const gen_tool = b.addExecutable(.{
        .name = "gen",
        .root_module = gen_mod,
        .use_llvm = false,
        .use_lld = false,
    });

    // markdown generator call //
    const gen_app = b.addRunArtifact(gen_tool);
    if (b.args) |args| gen_app.addArgs(args);
    gen_step.dependOn(&gen_app.step);

    const gen_isa = b.addRunArtifact(gen_tool);

    gen_isa.addArg("markdown");

    const Isa_markdown = gen_isa.addOutputFileArg("Isa.md");
    const Isa_markdown_install = b.addInstallFile(Isa_markdown, "docs/Isa.md");

    // Instruction generator call //
    const gen_types = b.addRunArtifact(gen_tool);
    gen_types.addArg("types");

    const Instruction_src = gen_types.addOutputFileArg("Instruction.zig");
    const Instruction_src_install = b.addInstallFileWithDir(Instruction_src, .{ .custom = "tmp" }, "Instruction.zig");

    Instruction_mod.root_source_file = Instruction_src;

    // create module tests //
    var test_bins = std.StringHashMap(*std.Build.Step.Compile).init(b.allocator);

    // wrap standard modules with tests //
    {
        var it = module_map.iterator();
        it: while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            inline for (&.{ "rg", "repl", "build_info" }) |skip_name| {
                if (std.mem.eql(u8, key, skip_name)) continue :it;
            }

            const test_bin = b.addTest(.{ .root_module = value });
            test_bins.put(key, test_bin) catch @panic("OOM");

            check_step.dependOn(&test_bin.step);
            test_step.dependOn(&b.addRunArtifact(test_bin).step);
        }
    }

    // create integrated modules and tests //
    inline for (tests) |test_name| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(test_path ++ test_name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });

        test_mod.addImport("ribbon_language", ribbon_mod);

        const test_bin = b.addTest(.{ .root_module = test_mod });
        test_bins.put(test_name, test_bin) catch @panic("OOM");

        check_step.dependOn(&test_bin.step);
        test_step.dependOn(&b.addRunArtifact(test_bin).step);
    }

    // setup generation tasks //
    const dump_intermediates_step = b.step("dump-intermediates", "Dump intermediate files to zig-out");
    dump_intermediates_step.dependOn(&Instruction_src_install.step);
    dump_intermediates_step.dependOn(&b.addInstallFile(Isa_markdown, "tmp/Isa.md").step);

    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = test_bins.get("ribbon_language").?.getEmittedDocs(),
        .install_dir = .{ .custom = "docs" },
        .install_subdir = "api",
    }).step);
    docs_step.dependOn(&Isa_markdown_install.step);

    isa_step.dependOn(&Isa_markdown_install.step);

    // create driver //
    const main_bin = b.addExecutable(.{
        .name = "ribbon",
        .root_module = main_mod,
    });

    // install driver //
    const main_install = b.addInstallArtifact(main_bin, .{});
    install_step.dependOn(&main_install.step);

    // run driver //
    const run_main = b.addRunArtifact(main_bin);
    if (b.args) |args| {
        run_main.addArgs(args);
    }
    run_step.dependOn(&run_main.step);
}

fn linkModule(module_map: *std.StringHashMap(*std.Build.Module), mod_def: ModuleDef) void {
    const mod = module_map.get(mod_def.name).?;

    for (mod_def.imports) |import_name| {
        const import_mod = module_map.get(import_name) orelse
            std.debug.panic("Module `{s}` imports unknown module `{s}`", .{ mod_def.name, import_name });
        mod.addImport(import_name, import_mod);
    }
}

fn validateTarget(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) struct { std.Build.LazyPath, []const ModuleDef, ?*std.Build.Module } {
    const arch_idx = if (std.mem.indexOfScalar(std.Target.Cpu.Arch, &SUPPORTED_ARCH, target.result.cpu.arch)) |idx| idx else {
        if (target.result.cpu.arch.endian() == .big) {
            @panic(
                \\
                \\
                \\Ribbon does not build for big-endian architectures.
                \\
                \\
            );
        } else {
            std.debug.panic(
                \\
                \\
                \\Ribbon cannot yet build for {s} architectures;
                \\You can try checking current Issues/PRs for updates, or filing one yourself.
                \\We want this to work, but its a *lot* of work.
                \\
                \\
            ,
                .{@tagName(target.result.cpu.arch)},
            );
        }
    };

    if (std.mem.indexOfScalar(std.Target.Os.Tag, &SUPPORTED_OS, target.result.os.tag) == null) {
        std.debug.panic(
            \\
            \\
            \\Ribbon cannot yet build for {s} operating systems.
            \\You can try disabling this check in the `build.zig file`.
            \\If it happens to work let us know on GitHub!
            \\
            \\
        ,
            .{@tagName(target.result.os.tag)},
        );
    }

    return .{
        b.path(ARCH_PATHS[arch_idx]),
        ARCH_MODULES[arch_idx],
        switch (target.result.cpu.arch) {
            .x86_64 => b.lazyDependency("r64", .{
                .target = target,
                .optimize = optimize,
            }).?.module("r64"),
            else => null,
        },
    };
}

fn parseZon(b: *std.Build, comptime T: type) T {
    const zonText = std.fs.cwd().readFileAllocOptions(b.allocator, "build.zig.zon", std.math.maxInt(usize), 2048, .@"1", 0) catch @panic("Unable to read build.zig.zon");

    var parseStatus = std.zon.parse.Diagnostics{};

    return std.zon.parse.fromSlice(
        T,
        b.allocator,
        zonText,
        &parseStatus,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        std.debug.print("Error {s}:\n", .{@errorName(err)});

        var it = parseStatus.iterateErrors();

        while (it.next()) |parseErr| {
            const loc = parseErr.getLocation(&parseStatus);

            std.debug.print("[build.zig.zon:{}]: {f}\n", .{ loc.line + 1, parseErr.fmtMessage(&parseStatus) });
        }

        std.process.exit(1);
    };
}
