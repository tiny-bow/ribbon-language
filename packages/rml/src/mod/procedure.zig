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
    @"else": Obj(Rml.Block),

    pattern: struct {
        scrutinizer: Obj(Pattern),
        body: Obj(Rml.Block),
    },

    pub fn body(self: Case) Obj(Rml.Block) {
        return switch (self) {
            .@"else" => |block| block,
            .pattern => |pat| pat.body,
        };
    }

    pub fn parse(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Object) Rml.Result! Case {
        Rml.parser.parsing.debug("parseCase {}:{any}", .{origin,args});

        if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount,
            "expected at least 2 arguments, found {}", .{args.len});

        var offset: usize = 1;

        const case = if (Rml.object.isExactSymbol("else", args[0])) elseCase: {
            break :elseCase Rml.procedure.Case { .@"else" = try Obj(Rml.Block).wrap(getRml(interpreter), origin, try .create(getRml(interpreter), .doc, &.{})) };
        } else patternCase: {
            var diag: ?Rml.Diagnostic = null;
            const parseResult = Rml.Pattern.parse(&diag, args)
                catch |err| {
                    if (err == error.SyntaxError) {
                        if (diag) |d| {
                            try interpreter.abort(origin, error.PatternError,
                                "cannot parse pattern starting with syntax object `{}`: {}", .{args[0], d.formatter(error.SyntaxError)});
                        } else {
                            Rml.parser.parsing.err("requested pattern parse diagnostic is null", .{});
                            try interpreter.abort(origin, error.PatternError,
                                "cannot parse pattern `{}`", .{args[0]});
                        }
                    }

                    return err;
                };

            Rml.parser.parsing.debug("pattern parse result: {}", .{parseResult});
            offset = parseResult.offset;

            break :patternCase Rml.procedure.Case {
                .pattern = .{
                    .scrutinizer = parseResult.value,
                    .body = try Obj(Rml.Block).wrap(getRml(interpreter), origin, try .create(getRml(interpreter), .doc, &.{})),
                },
            };
        };

        const content = case.body();

        for (args[offset..]) |arg| {
            try content.data.append(arg);
        }

        Rml.interpreter.evaluation.debug("case body: {any}", .{content});

        return case;
    }
};

pub const ProcedureBody = struct {
    env: Obj(Rml.Env),
    cases: std.ArrayListUnmanaged(Case),
};

pub const Procedure = union(ProcedureKind) {
    macro: ProcedureBody,
    function: ProcedureBody,
    native_macro: Rml.bindgen.NativeFunction,
    native_function: Rml.bindgen.NativeFunction,

    pub fn onInit(_: *Procedure) OOM! void {
        return;
    }

    pub fn onCompare(self: *Procedure, other: Object) Ordering {
        return Rml.compare(getHeader(self).type_id, other.getTypeId());
    }

    pub fn onFormat(self: *Procedure, writer: std.io.AnyWriter) anyerror! void {
        return writer.print("[{s}-{x}]", .{@tagName(self.*), @intFromPtr(self)});
    }

    pub fn call(self: *Procedure, interpreter: *Rml.Interpreter, callOrigin: Rml.Origin, blame: Object, args: []const Object) Rml.Result! Object {
        switch (self.*) {
            .macro => |macro| {
                Rml.interpreter.evaluation.debug("calling macro {}", .{macro});

                var errors: Rml.string.StringUnmanaged = .{};

                const writer = errors.writer(getRml(self));

                var result: ?Object = null;

                for (macro.cases.items) |case| switch (case) {
                    .@"else" => |caseData| {
                        result = try interpreter.runProgram(caseData.getOrigin(), false, caseData.data.items());
                        break;
                    },
                    .pattern => |caseData| {
                        var diag: ?Rml.Diagnostic = null;
                        const table: ?Obj(Rml.map.Table) = try caseData.scrutinizer.data.run(interpreter, &diag, callOrigin, args);
                        if (table) |tbl| {
                            const oldEnv = interpreter.evaluation_env;
                            defer interpreter.evaluation_env = oldEnv;

                            interpreter.evaluation_env = env: {
                                const env: Obj(Rml.Env) = try macro.env.data.clone(callOrigin);
                                try env.data.copyFromTable(&tbl.data.native_map);

                                break :env env;
                            };

                            result = try interpreter.runProgram(caseData.body.getOrigin(), false, caseData.body.data.items());
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

                const eArgs = try interpreter.evalAll(args);
                var errors: Rml.string.StringUnmanaged = .{};

                const writer = errors.writer(getRml(self));

                Rml.interpreter.evaluation.debug("calling func {any}", .{func.cases});
                for (func.cases.items) |case| switch (case) {
                    .@"else" => |caseData| {
                        Rml.interpreter.evaluation.debug("calling else case {}", .{caseData});
                        return interpreter.runProgram(caseData.getOrigin(), false, caseData.data.items());
                    },
                    .pattern => |caseData| {
                        Rml.interpreter.evaluation.debug("calling pattern case {}", .{caseData});
                        var diag: ?Rml.Diagnostic = null;
                        const result: ?Obj(Rml.map.Table) = try caseData.scrutinizer.data.run(interpreter, &diag, callOrigin, eArgs);
                        if (result) |res| {
                            const oldEnv = interpreter.evaluation_env;
                            defer interpreter.evaluation_env = oldEnv;

                            interpreter.evaluation_env = env: {
                                const env: Obj(Rml.Env) = try func.env.data.clone(callOrigin);

                                try env.data.copyFromTable(&res.data.native_map);

                                break :env env;
                            };

                            return interpreter.runProgram(caseData.body.getOrigin(), false, caseData.body.data.items());
                        } else if (diag) |d| {
                            writer.print("failed to match; {} vs {any}:\n\t{}", .{ caseData.scrutinizer, eArgs, d.formatter(error.PatternError)})
                                catch |err| return Rml.errorCast(err);
                        } else {
                            Rml.interpreter.evaluation.err("requested pattern diagnostic is null", .{});
                            writer.print("failed to match; {} vs {any}", .{ caseData.scrutinizer, eArgs})
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

                const eArgs = try interpreter.evalAll(args);

                return func(interpreter, callOrigin, eArgs);
            },
        }
    }
};
