const std = @import("std");

// const nasm = @import("nasm");

const SUPPORTED_ARCH = &.{.x86_64};
const SUPPORTED_OS = &.{ .windows, .linux };

pub fn build(b: *std.Build) !void {
    const zon = parseZon(b, struct { version: []const u8 });

    const version = std.SemanticVersion.parse(zon.version) catch {
        std.debug.panic("Cannot parse `{s}` as a semantic version string", .{zon.version});
    };

    const build_info_opts = b.addOptions();
    build_info_opts.addOption(std.SemanticVersion, "version", version);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // whitelisting doesnt really work the way we'd like here
    validateTarget(target.result);

    const rg_dep = b.dependency("rg", .{
        .target = target,
        .optimize = optimize,
    });

    const repl_dep = b.dependency("repl", .{
        .target = target,
        .optimize = optimize,
    });

    const rg_mod = rg_dep.module("rg");
    const repl_mod = repl_dep.module("repl");

    // create all modules //

    const common_mod = b.createModule(.{
        .root_source_file = b.path("src/mod/common.zig"),
        .target = target,
        .optimize = optimize,
    });

    const abi_mod = b.createModule(.{
        .root_source_file = b.path("src/mod/x64/abi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const assembler_mod = b.dependency("r64", .{
        .target = target,
        .optimize = optimize,
    }).module("r64");

    const binary_mod = b.createModule(.{
        .root_source_file = b.path("src/mod/binary.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bytecode_mod = b.createModule(.{
        .root_source_file = b.path("src/mod/bytecode.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/mod/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gen_mod = b.createModule(.{
        .root_source_file = b.path("src/bin/tools/gen.zig"),
        .target = target,
        .optimize = optimize,
    });

    const Instruction_mod = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });

    const interpreter_mod = b.createModule(.{
        .root_source_file = b.path("src/mod/interpreter.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ir_mod = b.createModule(.{
        .root_source_file = b.path("src/mod/ir.zig"),
        .target = target,
        .optimize = optimize,
    });

    const backend_mod = b.createModule(.{
        .root_source_file = b.path("src/mod/backend.zig"),
        .target = target,
        .optimize = optimize,
    });

    const isa_mod = b.createModule(.{
        .root_source_file = b.path("src/gen-base/zig/isa.zig"),
        .target = target,
        .optimize = optimize,
    });

    const machine_mod = b.createModule(.{
        .root_source_file = b.path("src/mod/x64/machine.zig"),
        .target = target,
        .optimize = optimize,
    });

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/bin/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const meta_language_mod = b.createModule(.{
        .root_source_file = b.path("src/mod/meta_language.zig"),
        .target = target,
        .optimize = optimize,
    });

    const source_mod = b.createModule(.{
        .root_source_file = b.path("src/mod/source.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ribbon_mod = b.addModule("ribbon_language", .{
        .root_source_file = b.path("src/mod/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bc_interp_mod = b.createModule(.{
        .root_source_file = b.path("src/test/bc_interp.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sma_mod = b.createModule(.{
        .root_source_file = b.path("src/mod/sma.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cbr_mod = b.createModule(.{
        .root_source_file = b.path("src/mod/cbr.zig"),
        .target = target,
        .optimize = optimize,
    });

    // setup tool calls //

    const gen_tool = b.addExecutable(.{
        .name = "gen",
        .root_module = gen_mod,
        .use_llvm = false,
        .use_lld = false,
    });

    const gen_step = b.step("gen", "CLI access for the isa code generator");
    const gen_app = b.addRunArtifact(gen_tool);
    if (b.args) |args| gen_app.addArgs(args);
    gen_step.dependOn(&gen_app.step);

    const gen_isa = b.addRunArtifact(gen_tool);

    gen_isa.addArg("markdown");

    const Isa_markdown = gen_isa.addOutputFileArg("Isa.md");

    const Isa_markdown_install = b.addInstallFile(Isa_markdown, "docs/Isa.md");

    const gen_types = b.addRunArtifact(gen_tool);

    gen_types.addArg("types");

    const Instruction_src = gen_types.addOutputFileArg("Instruction.zig");
    const Instruction_src_install = b.addInstallFileWithDir(Instruction_src, .{ .custom = "tmp" }, "Instruction.zig");

    Instruction_mod.root_source_file = Instruction_src;

    // create exports //

    const main_bin = b.addExecutable(.{
        .name = "ribbon",
        .root_module = main_mod,
        .linkage = .static,
    });

    const main_install = b.addInstallArtifact(main_bin, .{});

    // create tests //
    const abi_test = b.addTest(.{ .root_module = abi_mod });
    const bytecode_test = b.addTest(.{ .root_module = bytecode_mod });
    const core_test = b.addTest(.{ .root_module = core_mod });
    const gen_test = b.addTest(.{ .root_module = gen_mod });
    const Instruction_test = b.addTest(.{ .root_module = Instruction_mod });
    const interpreter_test = b.addTest(.{ .root_module = interpreter_mod });
    const ir_test = b.addTest(.{ .root_module = ir_mod });
    const backend_test = b.addTest(.{ .root_module = backend_mod });
    const isa_test = b.addTest(.{ .root_module = isa_mod });
    const machine_test = b.addTest(.{ .root_module = machine_mod });
    const main_test = b.addTest(.{ .root_module = main_mod });
    const meta_language_test = b.addTest(.{ .root_module = meta_language_mod });
    const source_test = b.addTest(.{ .root_module = source_mod });
    const common_test = b.addTest(.{ .root_module = common_mod });
    const ribbon_test = b.addTest(.{ .root_module = ribbon_mod });
    const bc_interp_test = b.addTest(.{ .root_module = bc_interp_mod });
    const sma_test = b.addTest(.{ .root_module = sma_mod });
    const cbr_test = b.addTest(.{ .root_module = cbr_mod });

    // add imports //

    abi_mod.addImport("assembler", assembler_mod);
    abi_mod.addImport("core", core_mod);

    binary_mod.addImport("core", core_mod);
    binary_mod.addImport("common", common_mod);

    bytecode_mod.addImport("common", common_mod);
    bytecode_mod.addImport("core", core_mod);
    bytecode_mod.addImport("Instruction", Instruction_mod);
    bytecode_mod.addImport("binary", binary_mod);

    core_mod.addImport("common", common_mod);
    core_mod.addOptions("build_info", build_info_opts);

    gen_mod.addImport("common", common_mod);
    gen_mod.addImport("isa", isa_mod);
    gen_mod.addImport("core", core_mod);
    gen_mod.addImport("assembler", assembler_mod);
    gen_mod.addImport("abi", abi_mod);

    gen_mod.addAnonymousImport("Isa_intro.md", .{ .root_source_file = b.path("src/gen-base/markdown/Isa_intro.md") });
    gen_mod.addAnonymousImport("Instruction_intro.zig", .{ .root_source_file = b.path("src/gen-base/zig/Instruction_intro.zig") });

    Instruction_mod.addImport("common", common_mod);
    Instruction_mod.addImport("core", core_mod);

    interpreter_mod.addImport("core", core_mod);
    interpreter_mod.addImport("Instruction", Instruction_mod);
    interpreter_mod.addImport("bytecode", bytecode_mod);
    interpreter_mod.addImport("common", common_mod);
    // interpreter_mod.addObjectFile(assembly_obj);

    ir_mod.addImport("core", core_mod);
    ir_mod.addImport("common", common_mod);
    ir_mod.addImport("bytecode", bytecode_mod);
    ir_mod.addImport("source", source_mod);

    backend_mod.addImport("common", common_mod);
    backend_mod.addImport("core", core_mod);
    backend_mod.addImport("bytecode", bytecode_mod);
    backend_mod.addImport("ir", ir_mod);

    machine_mod.addImport("core", core_mod);
    machine_mod.addImport("abi", abi_mod);
    machine_mod.addImport("assembler", assembler_mod);
    machine_mod.addImport("common", common_mod);

    main_mod.addImport("ribbon_language", ribbon_mod);
    main_mod.addImport("repl", repl_mod);

    source_mod.addImport("common", common_mod);
    source_mod.addImport("rg", rg_mod);

    meta_language_mod.addImport("rg", rg_mod);
    meta_language_mod.addImport("common", common_mod);
    meta_language_mod.addImport("source", source_mod);
    meta_language_mod.addImport("core", core_mod);
    meta_language_mod.addImport("ir", ir_mod);
    meta_language_mod.addImport("backend", backend_mod);

    ribbon_mod.addImport("core", core_mod);
    ribbon_mod.addImport("abi", abi_mod);
    ribbon_mod.addImport("bytecode", bytecode_mod);
    ribbon_mod.addImport("interpreter", interpreter_mod);
    ribbon_mod.addImport("ir", ir_mod);
    ribbon_mod.addImport("binary", binary_mod);
    ribbon_mod.addImport("backend", backend_mod);
    ribbon_mod.addImport("machine", machine_mod);
    ribbon_mod.addImport("meta_language", meta_language_mod);
    ribbon_mod.addImport("source", source_mod);
    ribbon_mod.addImport("common", common_mod);
    ribbon_mod.addImport("sma", sma_mod);
    ribbon_mod.addImport("cbr", cbr_mod);

    bc_interp_mod.addImport("ribbon_language", ribbon_mod);
    bc_interp_mod.addImport("common", common_mod);
    bc_interp_mod.addImport("repl", repl_mod);

    sma_mod.addImport("ir", ir_mod);
    sma_mod.addImport("source", source_mod);
    sma_mod.addImport("common", common_mod);
    sma_mod.addImport("backend", backend_mod);
    sma_mod.addImport("core", core_mod);
    sma_mod.addImport("cbr", cbr_mod);

    cbr_mod.addImport("ir", ir_mod);
    cbr_mod.addImport("source", source_mod);
    cbr_mod.addImport("common", common_mod);
    cbr_mod.addImport("backend", backend_mod);
    cbr_mod.addImport("core", core_mod);
    cbr_mod.addImport("sma", sma_mod);

    // setup steps //

    const install_step = b.default_step;
    install_step.dependOn(&main_install.step);

    const run_step = b.step("run", "Run the ribbon driver");
    const run_main = b.addRunArtifact(main_bin);
    if (b.args) |args| {
        run_main.addArgs(args);
    }
    run_step.dependOn(&run_main.step);

    const dump_intermediates_step = b.step("dump-intermediates", "Dump intermediate files to zig-out");
    dump_intermediates_step.dependOn(&Instruction_src_install.step);
    // dump_intermediates_step.dependOn(&assembly_src_install.step);
    // dump_intermediates_step.dependOn(&assembly_obj_install.step);
    // dump_intermediates_step.dependOn(&assembly_header_install.step);
    // dump_intermediates_step.dependOn(&assembly_template_install.step);
    dump_intermediates_step.dependOn(&b.addInstallFile(Isa_markdown, "tmp/Isa.md").step);

    if (optimize == .Debug) { // debugging assembly codegen somewhat requires this atm TODO: re-evaluate when stable
        install_step.dependOn(dump_intermediates_step);
        run_step.dependOn(dump_intermediates_step);
    }

    // const write_assembly_header_step = b.step("asm-header", "Output the assembly header file for nasm language features");
    // write_assembly_header_step.dependOn(&assembly_header_install.step);

    // const write_assembly_template_step = b.step("asm-template", "Output an interpreter assembly template");
    // write_assembly_template_step.dependOn(&assembly_template_install.step);

    const check_step = b.step("check", "Run semantic source");
    check_step.dependOn(&abi_test.step);

    check_step.dependOn(&bytecode_test.step);
    check_step.dependOn(&core_test.step);
    check_step.dependOn(&gen_test.step);
    check_step.dependOn(&interpreter_test.step);
    check_step.dependOn(&ir_test.step);
    check_step.dependOn(&backend_test.step);
    check_step.dependOn(&isa_test.step);
    check_step.dependOn(&machine_test.step);
    check_step.dependOn(&main_test.step);
    check_step.dependOn(&meta_language_test.step);
    check_step.dependOn(&source_test.step);
    check_step.dependOn(&ribbon_test.step);
    check_step.dependOn(&bc_interp_test.step);
    check_step.dependOn(&common_test.step);
    check_step.dependOn(&sma_test.step);
    check_step.dependOn(&cbr_test.step);

    const test_step = b.step("unit-test", "Run all unit tests");
    test_step.dependOn(&b.addRunArtifact(abi_test).step);

    test_step.dependOn(&b.addRunArtifact(bytecode_test).step);
    test_step.dependOn(&b.addRunArtifact(core_test).step);
    test_step.dependOn(&b.addRunArtifact(gen_test).step);
    test_step.dependOn(&b.addRunArtifact(Instruction_test).step);
    test_step.dependOn(&b.addRunArtifact(interpreter_test).step);
    test_step.dependOn(&b.addRunArtifact(ir_test).step);
    test_step.dependOn(&b.addRunArtifact(backend_test).step);
    test_step.dependOn(&b.addRunArtifact(isa_test).step);
    test_step.dependOn(&b.addRunArtifact(machine_test).step);
    test_step.dependOn(&b.addRunArtifact(main_test).step);
    test_step.dependOn(&b.addRunArtifact(meta_language_test).step);
    test_step.dependOn(&b.addRunArtifact(source_test).step);
    test_step.dependOn(&b.addRunArtifact(ribbon_test).step);
    test_step.dependOn(&b.addRunArtifact(bc_interp_test).step);
    test_step.dependOn(&b.addRunArtifact(common_test).step);
    test_step.dependOn(&b.addRunArtifact(sma_test).step);
    test_step.dependOn(&b.addRunArtifact(cbr_test).step);

    const docs_step = b.step("docs", "Generate documentation");

    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = ribbon_test.getEmittedDocs(),
        .install_dir = .{ .custom = "docs" },
        .install_subdir = "api",
    }).step);
    docs_step.dependOn(&Isa_markdown_install.step);

    const isa_step = b.step("isa", "Generate ISA documentation");

    isa_step.dependOn(&Isa_markdown_install.step);
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

// fn zigObjectFmtToNasm(zigFmt: std.Target.ObjectFormat) []const u8 {
//     switch (zigFmt) {
//         .coff => return "coff",
//         .elf => return "elf64",

//         else => std.debug.panic(
//             \\
//             \\
//             \\Object format `{s}` is not supported by Ribbon.
//             \\
//             \\
//         ,
//             .{@tagName(zigFmt)},
//         ),
//     }
// }

fn validateTarget(target: std.Target) void {
    if (std.mem.indexOfScalar(std.Target.Cpu.Arch, SUPPORTED_ARCH, target.cpu.arch) == null) {
        if (target.cpu.arch.endian() == .big) {
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
                .{@tagName(target.cpu.arch)},
            );
        }
    }

    if (std.mem.indexOfScalar(std.Target.Os.Tag, SUPPORTED_OS, target.os.tag) == null) {
        std.debug.panic(
            \\
            \\
            \\Ribbon cannot yet build for {s} operating systems.
            \\You can try disabling this check in the `build.zig file`.
            \\If it happens to work let us know on GitHub!
            \\
            \\
        ,
            .{@tagName(target.os.tag)},
        );
    }
}
