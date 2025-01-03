const std = @import("std");

const Rml = @import("root.zig");
const Error = Rml.Error;
const Ordering = Rml.Ordering;
const OOM = Rml.OOM;
const const_ptr = Rml.const_ptr;
const ptr = Rml.ptr;
const Obj = Rml.Obj;
const Object = Rml.Object;
const Block = Rml.Block;
const Pattern = Rml.Pattern;
const Writer = Rml.Writer;
const getHeader = Rml.getHeader;
const getObj = Rml.getObj;
const getRml = Rml.getRml;
const forceObj = Rml.forceObj;

pub const ProcedureKind = enum {
    macro,
    function,
    native_macro,
    native_function,
};

pub const Case = union(enum) {
    @"else": Rml.array.ArrayUnmanaged,

    pattern: struct {
        scrutinizer: Obj(Pattern),
        body: Rml.array.ArrayUnmanaged,
    },

    pub fn onDeinit(self: ptr(Case)) void {
        switch (self.*) {
            .@"else" => |*arr| arr.deinit(getRml(self)),
            .pattern => |*data| {
                data.scrutinizer.deinit();
                data.body.deinit(getRml(self));
            },
        }
    }

    pub fn body(self: ptr(Case)) *Rml.array.ArrayUnmanaged {
        return switch (self.*) {
            .@"else" => |*arr| arr,
            .pattern => |*data| &data.body,
        };
    }

    pub fn parse(interpreter: ptr(Rml.Interpreter), origin: Rml.Origin, args: []const Object) Rml.Result! Obj(Case) {
        Rml.interpreter.evaluation.debug("parseCase {}:{any}", .{origin,args});

        if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount,
            "expected at least 2 arguments, found {}", .{args.len});

        var offset: usize = 1;

        const case = if (Rml.object.isExactSymbol("else", args[0])) elseCase: {
            break :elseCase Rml.procedure.Case { .@"else" = .{} };
        } else patternCase: {
            var diag: ?Rml.Diagnostic = null;
            const parseResult = Rml.Pattern.parse(&diag, args)
                catch |err| {
                    if (err == error.SyntaxError) {
                        if (diag) |d| {
                            try interpreter.abort(origin, error.PatternError,
                                "cannot parse pattern starting with syntax object `{}`: {}", .{args[0], d.formatter(error.SyntaxError)});
                        } else {
                            Rml.log.err("requested pattern parse diagnostic is null", .{});
                            try interpreter.abort(origin, error.PatternError,
                                "cannot parse pattern `{}`", .{args[0]});
                        }
                    }

                    return err;
                };

            Rml.interpreter.evaluation.debug("pattern parse result: {}", .{parseResult});
            offset = parseResult.offset;

            break :patternCase Rml.procedure.Case {
                .pattern = .{
                    .scrutinizer = parseResult.value,
                    .body = .{},
                },
            };
        };

        const out = try Rml.wrap(getRml(interpreter), origin, case);
        errdefer out.deinit();

        const content = out.data.body();
        errdefer content.deinit(getRml(interpreter));

        for (args[offset..]) |arg| {
            try content.append(getRml(interpreter), arg.clone());
        }

        Rml.interpreter.evaluation.debug("case body: {any}", .{content});

        return out;
    }
};

pub const ProcedureBody = struct {
    env: Obj(Rml.Env),
    cases: Rml.array.TypedArrayUnmanaged(Case),

    pub fn deinit(self: *ProcedureBody, rml: *Rml) void {
        self.env.deinit();
        self.cases.deinit(rml);
    }
};

pub const Procedure = union(ProcedureKind) {
    macro: ProcedureBody,
    function: ProcedureBody,
    native_macro: Rml.bindgen.NativeFunction,
    native_function: Rml.bindgen.NativeFunction,

    pub fn onInit(_: ptr(Procedure)) OOM! void {
        return;
    }

    pub fn onCompare(self: ptr(Procedure), other: Object) Ordering {
        return Rml.compare(getHeader(self).type_id, other.getTypeId());
    }

    pub fn onFormat(self: ptr(Procedure), writer: Rml.Obj(Writer)) Error! void {
        return writer.data.print("[{s}-{x}]", .{@tagName(self.*), @intFromPtr(self)});
    }

    pub fn onDeinit(self: ptr(Procedure)) void {
        switch (self.*) {
            .macro => |*data| data.deinit(getRml(self)),
            .function => |*data| data.deinit(getRml(self)),
            .native_macro => {},
            .native_function => {},
        }
    }

    pub fn call(self: ptr(Procedure), interpreter: ptr(Rml.Interpreter), callOrigin: Rml.Origin, blame: Object, args: []const Object) Rml.Result! Object {
        switch (self.*) {
            .macro => |macro| {
                Rml.interpreter.evaluation.debug("calling macro {}", .{macro});

                var errors: Rml.string.StringUnmanaged = .{};
                defer errors.deinit(getRml(self));

                const writer = errors.writer(getRml(self));

                var result: ?Object = null;
                defer if (result) |res| res.deinit();

                for (macro.cases.items()) |case| switch (case.data.*) {
                    .@"else" => |caseData| {
                        result = try interpreter.runProgram(case.getOrigin(), false, caseData.items());
                        break;
                    },
                    .pattern => |caseData| {
                        var diag: ?Rml.Diagnostic = null;
                        const table: ?Obj(Rml.map.Table) = try caseData.scrutinizer.data.run(interpreter, &diag, callOrigin, args);
                        if (table) |tbl| {
                            defer tbl.deinit();

                            const oldEnv = interpreter.evaluation_env;
                            defer {
                                interpreter.evaluation_env.deinit();
                                interpreter.evaluation_env = oldEnv;
                            }

                            interpreter.evaluation_env = env: {
                                const env: Obj(Rml.Env) = try macro.env.data.clone(callOrigin);
                                errdefer env.deinit();

                                try env.data.copyFromTable(&tbl.data.unmanaged);

                                break :env env;
                            };

                            result = try interpreter.runProgram(case.getOrigin(), false, caseData.body.items());
                            break;
                        } else if (diag) |d| {
                            writer.print("failed to match; {} vs {any}:\n\t{}", .{ caseData.scrutinizer, args, d.formatter(error.PatternError)})
                                catch |err| return Rml.errorCast(err);
                        } else {
                            Rml.interpreter.evaluation.err("requested pattern diagnostic is null", .{});
                            writer.print("failed to match; {} vs {any}", .{ caseData.scrutinizer, args})
                                catch |err| return Rml.errorCast(err);
                        }
                    },
                };

                if (result) |res| {
                    return try interpreter.eval(res);
                } else {
                    try interpreter.abort(callOrigin, error.PatternError, "{} failed; no matching case found for input {any}", .{blame, args});
                }
            },
            .function => |func| {
                Rml.interpreter.evaluation.debug("calling func {}", .{func});

                var eArgs = try interpreter.evalAll(args);
                defer eArgs.deinit(getRml(self));

                var errors: Rml.string.StringUnmanaged = .{};
                defer errors.deinit(getRml(self));

                const writer = errors.writer(getRml(self));

                for (func.cases.items()) |case| switch (case.data.*) {
                    .@"else" => |caseData| {
                        return interpreter.runProgram(case.getOrigin(), false, caseData.items());
                    },
                    .pattern => |caseData| {
                        var diag: ?Rml.Diagnostic = null;
                        const result: ?Obj(Rml.map.Table) = try caseData.scrutinizer.data.run(interpreter, &diag, callOrigin, eArgs.items());
                        if (result) |res| {
                            defer res.deinit();

                            const oldEnv = interpreter.evaluation_env;
                            defer {
                                interpreter.evaluation_env.deinit();
                                interpreter.evaluation_env = oldEnv;
                            }

                            interpreter.evaluation_env = env: {
                                const env: Obj(Rml.Env) = try func.env.data.clone(callOrigin);
                                errdefer env.deinit();

                                try env.data.copyFromTable(&res.data.unmanaged);

                                break :env env;
                            };

                            return interpreter.runProgram(case.getOrigin(), false, caseData.body.items());
                        } else if (diag) |d| {
                            writer.print("failed to match; {} vs {}:\n\t{}", .{ caseData.scrutinizer, eArgs, d.formatter(error.PatternError)})
                                catch |err| return Rml.errorCast(err);
                        } else {
                            Rml.interpreter.evaluation.err("requested pattern diagnostic is null", .{});
                            writer.print("failed to match; {} vs {}", .{ caseData.scrutinizer, eArgs})
                                catch |err| return Rml.errorCast(err);
                        }
                    },
                };

                try interpreter.abort(callOrigin, error.PatternError, "{} failed; no matching case found for input {any}", .{blame, eArgs});
            },
            .native_macro => |func| {
                Rml.interpreter.evaluation.debug("calling native macro {x}", .{@intFromPtr(func)});

                return func(interpreter, callOrigin, args);
            },
            .native_function => |func| {
                Rml.interpreter.evaluation.debug("calling native func {x}", .{@intFromPtr(func)});

                var eArgs = try interpreter.evalAll(args);
                defer eArgs.deinit(getRml(self));

                return func(interpreter, callOrigin, eArgs.items());
            },
        }
    }
};
