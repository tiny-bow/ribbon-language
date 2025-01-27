const std = @import("std");
const Rml = @import("Rml");

const log = std.log.scoped(.rml_main);

pub const std_options = std.Options {
    .log_level = .info,
};

test {
    std.debug.print("rml-test\n", .{});
    try main();
}



pub fn main () !void {
    log.info("starting rml", .{});

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer {
        log.debug("Deinitializing gpa", .{});
        _ = gpa.deinit();
    }

    var diagnostic: ?Rml.Diagnostic = null;

    const rml: *Rml = try .init(gpa.allocator(), null, null, &diagnostic, &.{});
    log.debug("rml initialized", .{});
    defer {
        log.debug("Deinitializing Rml", .{});
        rml.deinit() catch |err| log.err("on Rml.deinit, {s}", .{@errorName(err)});
    }

    log.debug("test start", .{});

    rml.beginBlob();
    defer rml.endBlob().deinit();

    log.debug("namespace_env: {}", .{rml.namespace_env});
    log.debug("global_env: {}", .{rml.global_env});
    log.debug("evaluation_env: {}", .{rml.main_interpreter.data.evaluation_env});

    try rml.main_interpreter.data.evaluation_env.data.bind(
        try Rml.Obj(Rml.Symbol).wrap(rml, rml.data.origin, try .create(rml,"print-int")),
        (try Rml.bindgen.toObjectConst(rml, rml.data.origin, &struct{
            pub fn func(int: Rml.Int) void {
                log.info("print-int: {}", .{int});
            }
        }.func)).typeErase(),
    );


    const srcText: []const u8 = try std.fs.cwd().readFileAlloc(rml.blobAllocator(), "test.rml", std.math.maxInt(u16));

    const parser: Rml.Obj(Rml.Parser) = try .wrap(rml, rml.data.origin, .create("test.rml", try Rml.Obj(Rml.String).wrap(rml, rml.data.origin, try .create(rml, srcText))));

    while (true) {
        const blob = parser.data.nextBlob() catch |err| {
            if (diagnostic) |diag| {
                log.err("{s} {}: {s}", .{@errorName(err), diag.error_origin, diag.message_mem[0..diag.message_len]});
            } else {
                log.err("requested parser diagnostic is null", .{});
            }

            diagnostic = null;

            return err;
        } orelse break;

        log.debug("blob: {any}", .{blob});
        log.debug("peek: {?}", .{parser.data.obj_peek_cache});

        if (rml.main_interpreter.data.runProgram(false, blob)) |result| {
            if (!Rml.isType(Rml.Nil, result)) {
                log.info("result: {}", .{result});
            }
        } else |err| {
            log.err("on eval, {s}", .{@errorName(err)});
            if (diagnostic) |diag| {
                log.err("{s} {}: {s}", .{@errorName(err), diag.error_origin, diag.message_mem[0..diag.message_len]});
            } else {
                log.err("requested interpreter diagnostic is null", .{});
            }

            diagnostic = null;

            return err;
        }
    }
}
