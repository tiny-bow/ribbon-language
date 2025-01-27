const Rml = @import("../../Rml.zig");

const std = @import("std");
const utils = @import("utils");


pub const CASE_SEP_SYM = "=>";

pub const ProcedureKind = enum {
    macro,
    function,
    native_macro,
    native_function,
    cancellation,
};

pub const Case = union(enum) {
    @"else": Rml.Obj(Rml.Block),

    pattern: struct {
        scrutinizer: Rml.Obj(Rml.Pattern),
        body: Rml.Obj(Rml.Block),
    },

    pub fn body(self: Case) Rml.Obj(Rml.Block) {
        return switch (self) {
            .@"else" => |block| block,
            .pattern => |pat| pat.body,
        };
    }

    pub fn parse(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Case {
        Rml.log.parser.debug("parseCase {}:{any}", .{origin, args});

        if (args.len < 2) {
            try interpreter.abort(origin, error.InvalidArgumentCount,
                "expected at least 2 arguments, found {}", .{args.len});
        }

        var offset: usize = 1;

        const case = if (Rml.object.isExactSymbol("else", args[0])
                     or  Rml.object.isExactSymbol(CASE_SEP_SYM, args[0])) elseCase: {
            break :elseCase Rml.object.procedure.Case { .@"else" =
                try Rml.Obj(Rml.Block).wrap(Rml.getRml(interpreter), origin, try .create(Rml.getRml(interpreter), .doc, &.{}))
            };
        } else patternCase: {
            var diag: ?Rml.Diagnostic = null;
            const parseResult = Rml.Pattern.parse(&diag, args)
                catch |err| {
                    if (Rml.isSyntaxError(err)) {
                        if (diag) |d| {
                            try interpreter.abort(args[0].getOrigin(), err,
                                "cannot parse pattern starting with syntax object `{}`:\n\t{}", .{args[0], d.formatter(null)});
                        } else {
                            Rml.log.parser.err("requested pattern parse diagnostic is null", .{});
                            try interpreter.abort(args[0].getOrigin(), error.UnexpectedInput,
                                "cannot parse pattern `{}`", .{args[0]});
                        }
                    }

                    return err;
                }
                orelse try interpreter.abort(args[0].getOrigin(), error.UnexpectedInput,
                    "expected a pattern, got `{}`", .{args[0]});

            Rml.log.parser.debug("pattern parse result: {}", .{parseResult});
            offset = parseResult.offset;

            if (offset + 2 > args.len) try interpreter.abort(parseResult.value.getOrigin(), error.UnexpectedEOF,
                "expected {s} and a body to follow case scrutinizer pattern",
                .{Rml.object.procedure.CASE_SEP_SYM});

            const sepSym = Rml.castObj(Rml.Symbol, args[offset]) orelse {
                try interpreter.abort(args[offset].getOrigin(), error.UnexpectedInput,
                    "expected {s} to follow case scrutinizer pattern, found {}",
                    .{Rml.object.procedure.CASE_SEP_SYM, args[offset]});
            };

            offset += 1;

            if (!std.mem.eql(u8, sepSym.data.text(), Rml.object.procedure.CASE_SEP_SYM)) {
                try interpreter.abort(sepSym.getOrigin(), error.UnexpectedInput,
                    "expected {s} to follow case scrutinizer pattern, found {}",
                    .{Rml.object.procedure.CASE_SEP_SYM, sepSym});
            }

            break :patternCase Case {
                .pattern = .{
                    .scrutinizer = parseResult.value,
                    .body = try Rml.Obj(Rml.Block).wrap(Rml.getRml(interpreter), origin, try .create(Rml.getRml(interpreter), .doc, &.{})),
                },
            };
        };

        const content = case.body();

        for (args[offset..]) |arg| {
            try content.data.append(arg);
        }

        Rml.log.interpreter.debug("case body: {any}", .{content});

        return case;
    }
};

pub const ProcedureBody = struct {
    env: Rml.Obj(Rml.Env),
    cases: std.ArrayListUnmanaged(Case),
};

pub const Procedure = union(ProcedureKind) {
    macro: ProcedureBody,
    function: ProcedureBody,
    native_macro: Rml.bindgen.NativeFunction,
    native_function: Rml.bindgen.NativeFunction,
    cancellation: Rml.WithId,

    pub fn compare(self: Procedure, other: Procedure) utils.Ordering {
        var ord = utils.compare(std.meta.activeTag(self), std.meta.activeTag(other));

        if (ord == .Equal) {
            switch (self) {
                .macro => |macro| {
                    ord = utils.compare(macro.env, other.macro.env);
                    if (ord == .Equal) ord = utils.compare(macro.cases, other.macro.cases);
                },
                .function => |function| {
                    ord = utils.compare(function.env, other.function.env);
                    if (ord == .Equal) ord = utils.compare(function.cases, other.function.cases);
                },
                .native_macro => |native| {
                    ord = utils.compare(native, other.native_macro);
                },
                .native_function => |native| {
                    ord = utils.compare(native, other.native_function);
                },
                .cancellation => |cancellation| {
                    ord = utils.compare(cancellation, other.cancellation);
                },
            }
        }

        return ord;
    }

    pub fn format(self: *const Procedure, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror! void {
        // TODO: source formatting
        return writer.print("[{s}-{x}]", .{@tagName(self.*), @intFromPtr(self)});
    }

    pub fn call(self: *Procedure, interpreter: *Rml.Interpreter, callOrigin: Rml.Origin, blame: Rml.Object, args: []const Rml.Object) Rml.Result! Rml.Object {
        switch (self.*) {
            .cancellation => |cancellation| {
                Rml.log.interpreter.debug("calling cancellation {}", .{cancellation});

                std.debug.assert(interpreter.cancellation == null);

                const eArgs = try interpreter.evalAll(args);

                interpreter.cancellation = .{
                    .with_id = cancellation,
                    .output =
                        if (eArgs.items.len == 0) (try Rml.Obj(Rml.Nil).wrap(Rml.getRml(interpreter), callOrigin, .{})).typeErase()
                        else if (eArgs.items.len == 1) eArgs.items[0]
                        else (try Rml.Obj(Rml.Array).wrap(Rml.getRml(interpreter), callOrigin, .{.allocator = Rml.getRml(interpreter).blobAllocator(), .native_array = eArgs})).typeErase()
                };

                return Rml.Signal.Cancel;
            },
            .macro => |macro| {
                Rml.log.interpreter.debug("calling macro {}", .{macro});

                var errors: Rml.String = try .create(Rml.getRml(self), "");

                const writer = errors.writer();

                var result: ?Rml.Object = null;

                for (macro.cases.items) |case| switch (case) {
                    .@"else" => |caseData| {
                        result = try interpreter.runProgram(false, caseData.data.items());
                        break;
                    },
                    .pattern => |caseData| {
                        var diag: ?Rml.Diagnostic = null;
                        const table: ?Rml.Obj(Rml.object.map.Table) = try caseData.scrutinizer.data.run(interpreter, &diag, callOrigin, args);
                        if (table) |tbl| {
                            const oldEnv = interpreter.evaluation_env;
                            defer interpreter.evaluation_env = oldEnv;

                            interpreter.evaluation_env = env: {
                                const env: Rml.Obj(Rml.Env) = try macro.env.data.clone(callOrigin);
                                try env.data.copyFromTable(&tbl.data.native_map);

                                break :env env;
                            };

                            result = try interpreter.runProgram(false, caseData.body.data.items());
                            break;
                        } else if (diag) |d| {
                            writer.print("failed to match; {} vs {any}:\n\t{}", .{ caseData.scrutinizer, args, d.formatter(error.PatternFailed)})
                                catch |err| return Rml.errorCast(err);
                        } else {
                            Rml.log.interpreter.err("requested pattern diagnostic is null", .{});
                            writer.print("failed to match; {} vs {any}", .{ caseData.scrutinizer, args})
                                catch |err| return Rml.errorCast(err);
                        }
                    },
                };

                if (result) |res| {
                    return try interpreter.eval(res);
                } else {
                    try interpreter.abort(callOrigin, error.PatternFailed, "{} failed; no matching case found for input {any}", .{blame, args});
                }
            },
            .function => |func| {
                Rml.log.interpreter.debug("calling func {}", .{func});

                const eArgs = (try interpreter.evalAll(args)).items;
                var errors: Rml.object.string.String = try .create(Rml.getRml(self), "");

                const writer = errors.writer();

                Rml.log.interpreter.debug("calling func {any}", .{func.cases});
                for (func.cases.items) |case| switch (case) {
                    .@"else" => |caseData| {
                        Rml.log.interpreter.debug("calling else case {}", .{caseData});
                        return interpreter.runProgram(false, caseData.data.items());
                    },
                    .pattern => |caseData| {
                        Rml.log.interpreter.debug("calling pattern case {}", .{caseData});
                        var diag: ?Rml.Diagnostic = null;
                        const result: ?Rml.Obj(Rml.object.map.Table) = try caseData.scrutinizer.data.run(interpreter, &diag, callOrigin, eArgs);
                        if (result) |res| {
                            const oldEnv = interpreter.evaluation_env;
                            defer interpreter.evaluation_env = oldEnv;

                            interpreter.evaluation_env = env: {
                                const env: Rml.Obj(Rml.Env) = try func.env.data.clone(callOrigin);

                                try env.data.copyFromTable(&res.data.native_map);

                                break :env env;
                            };

                            return interpreter.runProgram(false, caseData.body.data.items());
                        } else if (diag) |d| {
                            writer.print("failed to match; {} vs {any}:\n\t{}", .{ caseData.scrutinizer, eArgs, d.formatter(error.PatternFailed)})
                                catch |err| return Rml.errorCast(err);
                        } else {
                            Rml.log.interpreter.err("requested pattern diagnostic is null", .{});
                            writer.print("failed to match; {} vs {any}", .{ caseData.scrutinizer, eArgs})
                                catch |err| return Rml.errorCast(err);
                        }
                    },
                };

                try interpreter.abort(callOrigin, error.PatternFailed, "{} failed; no matching case found for input {any}", .{blame, eArgs});
            },
            .native_macro => |func| {
                Rml.log.interpreter.debug("calling native macro {x}", .{@intFromPtr(func)});

                return func(interpreter, callOrigin, args);
            },
            .native_function => |func| {
                Rml.log.interpreter.debug("calling native func {x}", .{@intFromPtr(func)});

                const eArgs = try interpreter.evalAll(args);

                return func(interpreter, callOrigin, eArgs.items);
            },
        }
    }
};
