const std = @import("std");

const Rml = @import("Rml");
const log = std.log.scoped(.main);

pub const std_options = std.Options {
    .log_level = .info,
    // .log_scope_levels = &.{
    //     std.log.ScopeLevel {
    //         .level = .info,
    //         .scope = .refcount,
    //     },
    //     std.log.ScopeLevel {
    //         .level = .info,
    //         .scope = .@"object-dispatch",
    //     },
    // },
    // .log_scope_levels = &.{
    //     std.log.ScopeLevel {
    //         .level = .debug,
    //         .scope = .parsing,
    //     }
    // },
    // .log_scope_levels = &.{
    //     std.log.ScopeLevel {
    //         .level = .debug,
    //         .scope = .evaluation,
    //     }
    // },
};

pub fn main () !void {
    log.debug("init", .{});

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


    Rml.object.refcount.debug("test start object_count: {}", .{rml.storage.object_count});
    defer Rml.object.refcount.debug("test end object_count: {}", .{rml.storage.object_count});

    log.debug("namespace_env: {}", .{rml.namespace_env});
    log.debug("global_env: {}", .{rml.global_env});
    log.debug("evaluation_env: {}", .{rml.main_interpreter.data.evaluation_env});

    try rml.main_interpreter.data.evaluation_env.data.bind(
        try Rml.Obj(Rml.Symbol).new(rml, rml.storage.origin, .{"print-int"}),
        (try Rml.bindgen.toObjectConst(rml, rml.storage.origin, &struct{
            pub fn func(int: Rml.Int) void {
                log.info("print-int: {}", .{int});
            }
        }.func)).typeEraseLeak(),
    );


    const srcText: []const u8 = try std.fs.cwd().readFileAlloc(rml.storage.object, "test.bb", std.math.maxInt(u16));
    defer rml.storage.object.free(srcText);

    const parser: Rml.Obj(Rml.Parser) = try .new(rml, rml.storage.origin, .{"test.bb", try Rml.Obj(Rml.String).new(rml, rml.storage.origin, .{srcText})});
    defer {
        log.debug("Deinitializing parser", .{});
        parser.deinit();
    }

    const input: Rml.Obj(Rml.Int) = try .wrap(rml, rml.storage.origin, 10);
    defer {
        log.debug("Deinitializing input", .{});
        input.deinit();
    }

    while (parser.data.nextBlob() catch |err| {
        if (diagnostic) |diag| {
            log.err("{s} {}: {s}", .{@errorName(err), diag.error_origin, diag.message_mem[0..diag.message_len]});
        } else {
            log.err("requested interpreter diagnostic is null", .{});
        }

        diagnostic = null;

        return err;
    }) |blob| {
        defer blob.deinit();

        log.debug("blob{}: {}", .{blob.getHeader().origin, blob});

        if (rml.main_interpreter.data.eval(blob)) |result| {
            defer result.deinit();

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
