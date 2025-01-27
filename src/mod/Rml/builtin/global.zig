const Rml = @import("../../Rml.zig");

const std = @import("std");
const utils = @import("utils");

/// Creates a string from any sequence of objects. If there are no objects, the string will be empty.
///
/// Each object will be evaluated, and stringified with message formatting.
/// The resulting strings will be concatenated to form the final string.
pub fn format(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    const allocator = Rml.getRml(interpreter).blobAllocator();

    var out = Rml.object.string.NativeString{};

    try out.writer(allocator).print("{message}", .{Rml.format.slice(args)});

    return (try Rml.Obj(Rml.String).wrap(Rml.getRml(interpreter), origin, .{ .allocator = allocator, .native_string = out })).typeErase();
}

/// Forces the Rml runtime to abort evaluation with `EvalError.Panic`, and a message.
///
/// The message can be derived from any sequence of objects. If there are no objects, the panic message will be empty.
///
/// Each object will be evaluated, and stringified with message formatting.
/// The resulting strings will be concatenated to form the final abort message.
///
/// Note that the resulting message will only be seen if the interpreter has an `Rml.Diagnostic` output bound to it.
pub fn panic(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    try interpreter.abort(origin, error.Panic, "{message}", .{Rml.format.slice(args)});
}

/// Evaluates the first argument, and coerces it to a bool.
///
/// + **If the coerced bool is true**:
/// Returns the un-coerced, evaluated value. Any remaining arguments are left un-evaluated.
/// + **Otherwise**: Triggers a panic.
/// Any remaining arguments are passed as the arguments to panic; or if there were no remaining arguments,
/// the panic message will be the string representation of the value in un-evaluated and evaluated (but un-coerced) forms.
/// Note that the resulting message will only be seen if the interpreter has an `Rml.Diagnostic` output bound to it.
pub const assert = Rml.Procedure{
    .native_macro = &struct {
        pub fn fun(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
            if (args.len == 0) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found {}", .{args.len});

            const cond = try interpreter.eval(args[0]);

            if (Rml.coerceBool(cond)) {
                return cond;
            } else if (args.len > 1) {
                const eArgs = try interpreter.evalAll(args[1..]);
                try interpreter.abort(origin, error.Panic, "Assertion failed: {message}", .{Rml.format.slice(eArgs.items)});
            } else {
                try interpreter.abort(origin, error.Panic, "Assertion failed: {source} ({message})", .{ args[0], cond });
            }
        }
    }.fun,
};

/// Evaluates the first two arguments, and compares them.
///
/// + **If the two values are equal**:
/// Returns the first value. Any remaining arguments are left un-evaluated.
/// + **Otherwise**: Triggers a panic.
/// Any remaining arguments are passed as the arguments to panic; or if there were no remaining arguments,
/// the panic message will be a string representation of the comparison in un-evaluated and evaluated forms.
/// Note that the resulting message will only be seen if the interpreter has an `Rml.Diagnostic` output bound to it.
pub const @"assert-eq" = Rml.Procedure{
    .native_macro = &struct {
        pub fn fun(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
            if (args.len != 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected 2 arguments, found {}", .{args.len});

            const a = try interpreter.eval(args[0]);
            const b = try interpreter.eval(args[1]);

            if (utils.equal(a, b)) {
                return a;
            } else if (args.len > 2) {
                try interpreter.abort(origin, error.Panic, "Assertion failed: {message}", .{Rml.format.slice(args[2..])});
            } else {
                try interpreter.abort(origin, error.Panic, "Assertion failed: {source} ({message}) (of type {}) is not equal to {source} ({message}) (of type {})", .{ args[0], a, a.getTypeId(), args[1], b, b.getTypeId() });
            }
        }
    }.fun,
};

/// # `import` Syntax
///
/// Imports a namespace into the current environment
///
/// ## Example
/// ```rml
/// import text
/// assert (text/lowercase? 't')
/// ```
pub const import = Rml.Procedure{
    .native_macro = &struct {
        pub fn fun(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
            if (args.len != 1) try interpreter.abort(origin, error.InvalidArgumentCount, "expected 1 argument, found {}", .{args.len});

            const namespaceSym = try interpreter.castObj(Rml.Symbol, args[0]);

            const namespace: Rml.Object = Rml.getRml(interpreter).namespace_env.data.get(namespaceSym) orelse {
                try interpreter.abort(origin, error.UnboundSymbol, "namespace {} not found; available namespaces are: {any}", .{ namespaceSym, Rml.getRml(interpreter).namespace_env.data.keys() });
            };

            const env = try interpreter.castObj(Rml.Env, namespace);

            const localEnv: *Rml.Env = interpreter.evaluation_env.data;

            var it = env.data.table.iterator();
            while (it.next()) |entry| {
                const slashSym = slashSym: {
                    const slashStr = try std.fmt.allocPrint(Rml.getRml(interpreter).blobAllocator(), "{}/{}", .{ namespaceSym, entry.key_ptr.* });

                    break :slashSym try Rml.Obj(Rml.Symbol).wrap(Rml.getRml(interpreter), origin, try .create(Rml.getRml(interpreter), slashStr));
                };

                try localEnv.rebindCell(slashSym, entry.value_ptr.*);
            }

            return (try Rml.Obj(Rml.Nil).wrap(Rml.getRml(interpreter), origin, .{})).typeErase();
        }
    }.fun,
};

/// # `global` Syntax
///
/// Binds a new variable in the global environment
///
/// ## Example
/// ```rml
/// global x = 1
/// global (y z) = '(2 3)
/// assert-eq x 1
/// assert-eq y 2
/// assert-eq z 3
/// ```
pub const global = Rml.Procedure{
    .native_macro = &struct {
        pub fn fun(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
            Rml.log.interpreter.debug("global {}: {any}", .{ origin, args });

            if (args.len < 1)
                try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least a name for global variable", .{});

            const nilObj = try Rml.Obj(Rml.Nil).wrap(Rml.getRml(interpreter), origin, .{});
            const equalSym = try Rml.Obj(Rml.Symbol).wrap(Rml.getRml(interpreter), origin, try .create(Rml.getRml(interpreter), ASSIGNMENT_OPERATOR));

            const patt, const offset = parse: {
                var diag: ?Rml.Diagnostic = null;
                const parseResult = Rml.Pattern.parse(&diag, args) catch |err| {
                    if (err == error.SyntaxError) {
                        if (diag) |d| {
                            try interpreter.abort(origin, error.PatternFailed, "cannot parse global variable pattern: {}", .{d.formatter(error.SyntaxError)});
                        } else {
                            Rml.log.err("requested pattern parse diagnostic is null", .{});
                            try interpreter.abort(origin, error.PatternFailed, "cannot parse global variable pattern `{}`", .{args[0]});
                        }
                    }

                    return err;
                } orelse {
                    try interpreter.abort(origin, error.UnexpectedInput, "cannot parse global variable pattern `{}`", .{args[0]});
                };

                break :parse .{ parseResult.value, parseResult.offset };
            };

            Rml.log.parser.debug("global variable pattern: {}", .{patt});

            const dom = Rml.object.pattern.patternBinders(patt.typeErase()) catch |err| switch (err) {
                error.BadDomain => {
                    try interpreter.abort(origin, error.PatternFailed, "bad domain in pattern `{}`", .{patt});
                },
                error.OutOfMemory => return error.OutOfMemory,
            };

            for (dom.keys()) |sym| {
                Rml.log.interpreter.debug("rebinding global variable {} = nil", .{sym});
                try Rml.getRml(interpreter).global_env.data.rebind(sym, nilObj.typeErase());
            }

            const obj =
                if (args.len - offset == 0) nilObj.typeErase() else obj: {
                if (!utils.equal(args[offset], equalSym.typeErase())) {
                    try interpreter.abort(origin, error.UnexpectedInput, "expected `=` after global variable pattern", .{});
                }

                const body = args[offset + 1 ..];

                if (body.len == 1) {
                    if (Rml.castObj(Rml.Block, body[0])) |bod| {
                        break :obj try interpreter.runProgram(
                            bod.data.kind == .paren,
                            bod.data.items(),
                        );
                    }
                }

                break :obj try interpreter.runProgram(false, body);
            };

            Rml.log.interpreter.debug("evaluating global variable {} = {}", .{ patt, obj });

            const table = table: {
                var diag: ?Rml.Diagnostic = null;
                if (try patt.data.run(interpreter, &diag, origin, &.{obj})) |m| break :table m;

                if (diag) |d| {
                    try interpreter.abort(origin, error.PatternFailed, "failed to match; {} vs {}:\n\t{}", .{ patt, obj, d.formatter(error.PatternFailed) });
                } else {
                    Rml.log.interpreter.err("requested pattern diagnostic is null", .{});
                    try interpreter.abort(origin, error.PatternFailed, "failed to match; {} vs {}", .{ patt, obj });
                }
            };

            var it = table.data.native_map.iterator();
            while (it.next()) |entry| {
                const sym = entry.key_ptr.*;
                const val = entry.value_ptr.*;

                Rml.log.interpreter.debug("setting global variable {} = {}", .{ sym, val });

                // TODO: deep copy into long term memory

                try Rml.getRml(interpreter).global_env.data.rebind(sym, val);
            }

            return nilObj.typeErase();
        }
    }.fun,
};

/// # `local` Syntax
///
/// Binds a new variable in the local environment
///
/// ## Example
/// ```rml
/// local x = 1
/// local (y z) = '(2 3)
/// assert-eq x 1
/// assert-eq y 2
/// assert-eq z 3
/// ```
pub const local = Rml.Procedure{
    .native_macro = &struct {
        pub fn fun(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
            Rml.log.interpreter.debug("local {}: {any}", .{ origin, args });

            if (args.len < 1)
                try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least a name for local variable", .{});

            const nilObj = try Rml.Obj(Rml.Nil).wrap(Rml.getRml(interpreter), origin, .{});
            const equalSym = try Rml.Obj(Rml.Symbol).wrap(Rml.getRml(interpreter), origin, try .create(Rml.getRml(interpreter), ASSIGNMENT_OPERATOR));

            const patt, const offset = parse: {
                var diag: ?Rml.Diagnostic = null;
                const parseResult = Rml.Pattern.parse(&diag, args) catch |err| {
                    if (err == error.SyntaxError) {
                        if (diag) |d| {
                            try interpreter.abort(origin, error.PatternFailed, "cannot parse local variable pattern: {}", .{d.formatter(error.SyntaxError)});
                        } else {
                            Rml.log.err("requested pattern parse diagnostic is null", .{});
                            try interpreter.abort(origin, error.PatternFailed, "cannot parse local variable pattern `{}`", .{args[0]});
                        }
                    }

                    return err;
                } orelse {
                    try interpreter.abort(origin, error.UnexpectedInput, "cannot parse local variable pattern `{}`", .{args[0]});
                };

                break :parse .{ parseResult.value, parseResult.offset };
            };

            Rml.log.parser.debug("local variable pattern: {}", .{patt});

            const dom = patt.data.binders() catch |err| switch (err) {
                error.BadDomain => {
                    try interpreter.abort(origin, error.PatternFailed, "bad domain in pattern `{}`", .{patt});
                },
                error.OutOfMemory => return error.OutOfMemory,
            };

            for (dom.keys()) |sym| {
                Rml.log.interpreter.debug("rebinding local variable {} = nil", .{sym});
                try interpreter.evaluation_env.data.rebind(sym, nilObj.typeErase());
            }

            const obj =
                if (args.len - offset == 0) nilObj.typeErase() else obj: {
                if (!utils.equal(args[offset], equalSym.typeErase())) {
                    try interpreter.abort(origin, error.UnexpectedInput, "expected `=` after local variable pattern", .{});
                }

                const body = args[offset + 1 ..];

                if (body.len == 1) {
                    if (Rml.castObj(Rml.Block, body[0])) |bod| {
                        break :obj try interpreter.runProgram(
                            bod.data.kind == .paren,
                            bod.data.items(),
                        );
                    }
                }

                break :obj try interpreter.runProgram(false, body);
            };

            Rml.log.interpreter.debug("evaluating local variable {} = {}", .{ patt, obj });

            const table = table: {
                var diag: ?Rml.Diagnostic = null;
                if (try patt.data.run(interpreter, &diag, origin, &.{obj})) |m| break :table m;

                if (diag) |d| {
                    try interpreter.abort(origin, error.PatternFailed, "failed to match; {} vs {}:\n\t{}", .{ patt, obj, d.formatter(error.PatternFailed) });
                } else {
                    Rml.log.interpreter.err("requested pattern diagnostic is null", .{});
                    try interpreter.abort(origin, error.PatternFailed, "failed to match; {} vs {}", .{ patt, obj });
                }
            };

            var it = table.data.native_map.iterator();
            while (it.next()) |entry| {
                const sym = entry.key_ptr.*;
                const val = entry.value_ptr.*;

                Rml.log.interpreter.debug("setting local variable {} = {}", .{ sym, val });

                try interpreter.evaluation_env.data.set(sym, val);
            }

            return nilObj.typeErase();
        }
    }.fun,
};

/// Sets the value of a variable associated with an existing binding in the current environment
///
/// E.g. `(set! x 42)` will set the value of the variable `x` to `42`.
pub const @"set!" = Rml.Procedure{
    .native_macro = &struct {
        pub fn fun(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
            if (args.len != 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected 2 arguments, found {}", .{args.len});

            const sym = Rml.castObj(Rml.Symbol, args[0]) orelse try interpreter.abort(origin, error.TypeError, "expected symbol, found {s}", .{Rml.TypeId.name(args[0].getTypeId())});

            const value = try interpreter.eval(args[1]);

            try interpreter.evaluation_env.data.set(sym, value);

            const nil = try Rml.Obj(Rml.Nil).wrap(Rml.getRml(interpreter), origin, .{});
            return nil.typeErase();
        }
    }.fun,
};

/// # `with` Syntax
///
/// Binds provided effect handlers to the evidence environment, then evaluates its body.
///
/// Effect handlers bound this way have access to the `cancel` Syntax, which can be used to escape the with block.
///
/// ## Example
/// ```rml
/// local x = 0
/// with {
///     fresh = fun =>
///         local out = x
///         set! x (+ x 1)
///         out
/// }
///     local a = (fresh)
///     local b = (fresh)
///     assert-eq a 0
///     assert-eq b 1
/// ```
///
/// ## Example
/// ```rml
/// assert-eq 'failed (with (fail = fun => cancel 'failed) (fail))
/// ```
pub const with = Rml.Procedure{
    .native_macro = &struct {
        pub fn fun(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
            if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            const context = (Rml.castObj(Rml.Block, args[0]) orelse {
                try interpreter.abort(args[0].getOrigin(), error.TypeError, "expected a context block for with-syntax, found {s}", .{Rml.TypeId.name(args[0].getTypeId())});
            });

            const body = args[1..];

            const newEvidence = try interpreter.evidence_env.data.clone(origin);

            const cancellation = try interpreter.freshCancellation(origin);

            var isCases = true;
            for (context.data.items()) |obj| {
                if (!Rml.isType(Rml.Block, obj)) {
                    isCases = false;
                    break;
                }
            }

            const cases: []const Rml.Obj(Rml.Block) =
                if (isCases) @as([*]const Rml.Obj(Rml.Block), @ptrCast(context.data.items().ptr))[0..@intCast(context.data.length())] else &.{context};

            for (cases) |caseBlock| {
                const case = caseBlock.data.items();
                const effectSym = Rml.castObj(Rml.Symbol, case[0]) orelse {
                    try interpreter.abort(case[0].getOrigin(), error.TypeError, "expected a symbol for the effect handler in with-syntax case block, found {s}", .{Rml.TypeId.name(case[0].getTypeId())});
                };

                const sepSym = Rml.castObj(Rml.Symbol, case[1]) orelse {
                    try interpreter.abort(case[1].getOrigin(), error.TypeError, "expected {s} in with-syntax context block, found {}", .{ ASSIGNMENT_OPERATOR, case[1] });
                };

                if (!std.mem.eql(u8, ASSIGNMENT_OPERATOR, sepSym.data.text())) {
                    try interpreter.abort(sepSym.getOrigin(), error.TypeError, "expected {s} in with-syntax context block, found {s}", .{ ASSIGNMENT_OPERATOR, sepSym.data.text() });
                }

                const handlerBody = case[2..];

                const handler = handler: {
                    const cancelerSym = try Rml.Obj(Rml.Symbol).wrap(Rml.getRml(interpreter), origin, try .create(Rml.getRml(interpreter), "cancel"));

                    const oldEnv = interpreter.evaluation_env;
                    defer interpreter.evaluation_env = oldEnv;
                    interpreter.evaluation_env = try oldEnv.data.clone(origin);
                    try interpreter.evaluation_env.data.rebind(cancelerSym, cancellation.typeErase());

                    break :handler try interpreter.runProgram(false, handlerBody);
                };

                try newEvidence.data.rebind(effectSym, handler);
            }

            const oldEvidence = interpreter.evidence_env;
            defer interpreter.evidence_env = oldEvidence;
            interpreter.evidence_env = newEvidence;

            return interpreter.runProgram(false, body) catch |sig| {
                if (sig == Rml.Signal.Cancel) {
                    const currentCancellation = interpreter.cancellation orelse @panic("cancellation signal received without a cancellation context");

                    if (currentCancellation.with_id == cancellation.data.cancellation) {
                        defer interpreter.cancellation = null;

                        return currentCancellation.output;
                    }
                }

                return sig;
            };
        }
    }.fun,
};

/// # `fun` Syntax
///
/// Creates a function closure
///
/// ## Example
/// ```rml
/// local add = fun (a b) => (+ a b)
/// assert-eq (add 1 2) 3
/// ```
pub const fun = Rml.Procedure{
    .native_macro = &struct {
        pub fn fun(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
            Rml.log.parser.debug("fun {}: {any}", .{ origin, args });

            if (args.len == 0) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found 0", .{});

            const rml = Rml.getRml(interpreter);

            var cases: std.ArrayListUnmanaged(Rml.object.procedure.Case) = .{};

            if (args.len == 1) {
                Rml.log.parser.debug("case fun", .{});
                const caseSet: Rml.Obj(Rml.Block) = try interpreter.castObj(Rml.Block, args[0]);
                Rml.log.parser.debug("case set {}", .{caseSet});

                var isCases = true;
                for (caseSet.data.items()) |obj| {
                    if (!Rml.isType(Rml.Block, obj)) {
                        isCases = false;
                        break;
                    }
                }

                if (isCases) {
                    Rml.log.parser.debug("isCases {any}", .{caseSet.data.array.items});
                    for (caseSet.data.array.items) |case| {
                        Rml.log.parser.debug("case {}", .{case});
                        const caseBlock = try interpreter.castObj(Rml.Block, case);

                        const c = try Rml.object.procedure.Case.parse(interpreter, caseBlock.getOrigin(), caseBlock.data.array.items);

                        try cases.append(rml.blobAllocator(), c);
                    }
                } else {
                    Rml.log.parser.debug("fun single case: {any}", .{caseSet.data.array.items});
                    const c = try Rml.object.procedure.Case.parse(interpreter, caseSet.getOrigin(), caseSet.data.array.items);

                    try cases.append(rml.blobAllocator(), c);
                }
            } else {
                Rml.log.parser.debug("fun single case: {any}", .{args});
                const c = try Rml.object.procedure.Case.parse(interpreter, origin, args);

                try cases.append(rml.blobAllocator(), c);
            }

            const env = try interpreter.evaluation_env.data.clone(origin);

            const out: Rml.Obj(Rml.Procedure) = try .wrap(rml, origin, Rml.Procedure{
                .function = .{
                    .env = env,
                    .cases = cases,
                },
            });

            Rml.log.parser.debug("fun done: {}", .{out});

            return out.typeErase();
        }
    }.fun,
};

/// # `macro` Syntax
///
/// Creates a macro closure
///
/// ## Example
/// ```rml
/// local add = macro (a b) => `(+ a b)
/// assert-eq (add 1 2) 3
/// ```
pub const macro = Rml.Procedure{
    .native_macro = &struct {
        pub fn fun(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
            Rml.log.interpreter.debug("macro {}: {any}", .{ origin, args });

            if (args.len == 0) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found 0", .{});

            const rml = Rml.getRml(interpreter);

            var cases: std.ArrayListUnmanaged(Rml.object.procedure.Case) = .{};

            if (args.len == 1) {
                Rml.log.interpreter.debug("case macro", .{});
                const caseSet: Rml.Obj(Rml.Block) = try interpreter.castObj(Rml.Block, args[0]);
                Rml.log.interpreter.debug("case set {}", .{caseSet});

                var isCases = true;
                for (caseSet.data.items()) |obj| {
                    if (!Rml.isType(Rml.Block, obj)) {
                        isCases = false;
                        break;
                    }
                }

                if (isCases) {
                    Rml.log.interpreter.debug("isCases {}", .{isCases});
                    for (caseSet.data.array.items) |case| {
                        Rml.log.interpreter.debug("case {}", .{case});
                        const caseBlock = try interpreter.castObj(Rml.Block, case);

                        const c = try Rml.object.procedure.Case.parse(interpreter, origin, caseBlock.data.array.items);

                        try cases.append(rml.blobAllocator(), c);
                    }
                } else {
                    Rml.log.interpreter.debug("isCases {}", .{isCases});
                    Rml.log.interpreter.debug("macro single case: {any}", .{caseSet.data.array.items});
                    const c = try Rml.object.procedure.Case.parse(interpreter, origin, caseSet.data.array.items);

                    try cases.append(rml.blobAllocator(), c);
                }
            } else {
                Rml.log.interpreter.debug("macro single case: {any}", .{args});
                const c = try Rml.object.procedure.Case.parse(interpreter, origin, args);
                try cases.append(rml.blobAllocator(), c);
            }

            const env = try interpreter.evaluation_env.data.clone(origin);

            const out: Rml.Obj(Rml.Procedure) = try .wrap(rml, origin, Rml.Procedure{
                .macro = .{
                    .env = env,
                    .cases = cases,
                },
            });

            return out.typeErase();
        }
    }.fun,
};

/// Prints a message followed by a new line. (To skip the new line, use `print`)
///
/// The message can be derived from any sequence of objects. If there are no objects, the message will be empty.
///
/// Each object will be evaluated, stringified with message formatting,
/// and the resulting strings will be concatenated to form the final message.
pub fn @"print-ln"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    const rml = Rml.getRml(interpreter);

    const stdout = std.io.getStdOut();

    stdout.writer().print("{}: {message}\n", .{ origin, Rml.format.slice(args) }) catch |err| return Rml.errorCast(err);

    return (try Rml.Obj(Rml.Nil).wrap(rml, origin, .{})).typeErase();
}

/// Prints a message. (To append a new line to the message, use `print-ln`)
///
/// The message can be derived from any sequence of objects. If there are no objects, the message will be empty.
///
/// Each object will be evaluated, stringified with message formatting,
/// and the resulting strings will be concatenated to form the final message.
pub fn print(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    const rml = Rml.getRml(interpreter);

    const stdout = std.io.getStdOut();

    stdout.writer().print("{}: {message}", .{ origin, Rml.format.slice(args) }) catch |err| return Rml.errorCast(err);

    return (try Rml.Obj(Rml.Nil).wrap(rml, origin, .{})).typeErase();
}

/// alias for `+`
pub const add = @"+";
/// sum any number of arguments of type `int | float | char`;
/// if only one argument is provided, return the argument's absolute value
pub fn @"+"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len == 0) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found 0", .{});

    var sum: Rml.Object = args[0];

    if (args.len == 1) {
        if (Rml.castObj(Rml.Int, sum)) |int| {
            return (try Rml.Obj(Rml.Int).wrap(int.getRml(), origin, @intCast(@abs(int.data.*)))).typeErase();
        } else if (Rml.castObj(Rml.Float, sum)) |float| {
            return (try Rml.Obj(Rml.Float).wrap(float.getRml(), origin, @abs(float.data.*))).typeErase();
        }
        if (Rml.castObj(Rml.Char, sum)) |char| {
            return (try Rml.Obj(Rml.Char).wrap(char.getRml(), origin, char.data.*)).typeErase();
        } else {
            try interpreter.abort(origin, error.TypeError, "expected int | float | char, found {s}", .{Rml.TypeId.name(sum.getTypeId())});
        }
    }

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Rml.Int, b: Rml.Int) Rml.Int {
            return a + b;
        }
        pub fn float(a: Rml.Float, b: Rml.Float) Rml.Float {
            return a + b;
        }
        pub fn char(a: Rml.Char, b: Rml.Char) Rml.Char {
            return a + b;
        }
    });
}

/// alias for `-`
pub const sub = @"-";
/// subtract any number of arguments of type `int | float | char`;
/// if only one argument is provided, return the argument's negative value
pub fn @"-"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len == 0) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found 0", .{});

    var sum: Rml.Object = args[0];

    if (args.len == 1) {
        if (Rml.castObj(Rml.Int, sum)) |int| {
            return (try Rml.Obj(Rml.Int).wrap(int.getRml(), origin, -int.data.*)).typeErase();
        } else if (Rml.castObj(Rml.Float, sum)) |float| {
            return (try Rml.Obj(Rml.Float).wrap(float.getRml(), origin, -float.data.*)).typeErase();
        }
        if (Rml.castObj(Rml.Char, sum)) |char| { // TODO: ???
            return (try Rml.Obj(Rml.Char).wrap(char.getRml(), origin, char.data.*)).typeErase();
        } else {
            try interpreter.abort(origin, error.TypeError, "expected int | float | char, found {s}", .{Rml.TypeId.name(sum.getTypeId())});
        }
    }

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Rml.Int, b: Rml.Int) Rml.Int {
            return a - b;
        }
        pub fn float(a: Rml.Float, b: Rml.Float) Rml.Float {
            return a - b;
        }
        pub fn char(a: Rml.Char, b: Rml.Char) Rml.Char {
            return a - b;
        }
    });
}

/// alias for `/`
pub const div = @"/";
/// divide any number of arguments of type `int | float | char`;
/// it is an error to provide less than two arguments
pub fn @"/"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Rml.Object = args[0];

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Rml.Int, b: Rml.Int) Rml.Int {
            return @divFloor(a, b);
        }
        pub fn float(a: Rml.Float, b: Rml.Float) Rml.Float {
            return a / b;
        }
        pub fn char(a: Rml.Char, b: Rml.Char) Rml.Char {
            return @divFloor(a, b);
        }
    });
}

/// alias for `*`
pub const mul = @"*";
/// multiply any number of arguments of type `int | float | char`;
/// it is an error to provide less than two arguments
pub fn @"*"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Rml.Object = args[0];

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Rml.Int, b: Rml.Int) Rml.Int {
            return a * b;
        }
        pub fn float(a: Rml.Float, b: Rml.Float) Rml.Float {
            return a * b;
        }
        pub fn char(a: Rml.Char, b: Rml.Char) Rml.Char {
            return a * b;
        }
    });
}

/// remainder division on any number of arguments of type `int | float | char`;
/// it is an error to provide less than two arguments
pub fn rem(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Rml.Object = args[0];

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Rml.Int, b: Rml.Int) Rml.Int {
            return @rem(a, b);
        }
        pub fn float(a: Rml.Float, b: Rml.Float) Rml.Float {
            return @rem(a, b);
        }
        pub fn char(a: Rml.Char, b: Rml.Char) Rml.Char {
            return @rem(a, b);
        }
    });
}

/// exponentiation on any number of arguments of type `int | float | char`;
/// it is an error to provide less than two arguments
pub fn pow(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Rml.Object = args[0];

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Rml.Int, b: Rml.Int) Rml.Int {
            return std.math.pow(Rml.Int, a, b);
        }
        pub fn float(a: Rml.Float, b: Rml.Float) Rml.Float {
            return std.math.pow(Rml.Float, a, b);
        }
        pub fn char(a: Rml.Char, b: Rml.Char) Rml.Char {
            return std.math.pow(Rml.Char, a, b);
        }
    });
}

/// bitwise NOT on an argument of type `int | char`
pub fn @"bit-not"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len != 1) try interpreter.abort(origin, error.InvalidArgumentCount, "expected 1 argument, found {}", .{args.len});

    if (Rml.castObj(Rml.Int, args[0])) |i| {
        return (try Rml.Obj(Rml.Int).wrap(i.getRml(), origin, ~i.data.*)).typeErase();
    } else if (Rml.castObj(Rml.Char, args[0])) |c| {
        return (try Rml.Obj(Rml.Char).wrap(c.getRml(), origin, ~c.data.*)).typeErase();
    } else {
        try interpreter.abort(origin, error.TypeError, "expected int | char, found {s}", .{Rml.TypeId.name(args[0].getTypeId())});
    }
}

/// bitwise AND on any number of arguments of type `int | char`;
/// it is an error to provide less than two arguments
pub fn @"bit-and"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Rml.Object = args[0];

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Rml.Int, b: Rml.Int) Rml.Int {
            return a & b;
        }
        pub fn char(a: Rml.Char, b: Rml.Char) Rml.Char {
            return a & b;
        }
    });
}

/// bitwise OR on any number of arguments of type `int | char`;
/// it is an error to provide less than two arguments
pub fn @"bit-or"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Rml.Object = args[0];

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Rml.Int, b: Rml.Int) Rml.Int {
            return a | b;
        }
        pub fn char(a: Rml.Char, b: Rml.Char) Rml.Char {
            return a | b;
        }
    });
}

/// bitwise XOR on any number of arguments of type `int | char`;
/// it is an error to provide less than two arguments
pub fn @"bit-xor"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Rml.Object = args[0];

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Rml.Int, b: Rml.Int) Rml.Int {
            return a ^ b;
        }
        pub fn char(a: Rml.Char, b: Rml.Char) Rml.Char {
            return a ^ b;
        }
    });
}

/// bitwise right shift on two arguments of type `int | char`
pub fn @"bit-rshift"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len != 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected 2 arguments, found {}", .{args.len});

    var sum: Rml.Object = args[0];

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Rml.Int, b: Rml.Int) Rml.Int {
            return a >> @intCast(b);
        }
        pub fn char(a: Rml.Char, b: Rml.Char) Rml.Char {
            return a >> @intCast(b);
        }
    });
}

/// bitwise left shift on two arguments of type `int | char`
pub fn @"bit-lshift"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len != 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected 2 arguments, found {}", .{args.len});

    var sum: Rml.Object = args[0];

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Rml.Int, b: Rml.Int) Rml.Int {
            return a << @intCast(b);
        }
        pub fn char(a: Rml.Char, b: Rml.Char) Rml.Char {
            return a << @intCast(b);
        }
    });
}

/// coerce an argument to type `bool`
pub fn @"truthy?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len != 1) {
        try interpreter.abort(origin, error.InvalidArgumentCount, "expected 1 argument, found {}", .{args.len});
    }

    return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, Rml.coerceBool(args[0]))).typeErase();
}

/// logical NOT on an argument coerced to type `bool`
pub fn not(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len != 1) {
        try interpreter.abort(origin, error.InvalidArgumentCount, "expected 1 argument, found {}", .{args.len});
    }

    return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, !Rml.coerceBool(args[0]))).typeErase();
}

/// short-circuiting logical AND on any number of arguments of any type;
/// returns the last succeeding argument or nil
pub const @"and" = Rml.Procedure{
    .native_macro = &struct {
        pub fn fun(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
            if (args.len == 0) return (try Rml.Obj(Rml.Nil).wrap(Rml.getRml(interpreter), origin, .{})).typeErase();

            var a = try interpreter.eval(args[0]);

            if (!Rml.coerceBool(a)) {
                return (try Rml.Obj(Rml.Nil).wrap(Rml.getRml(interpreter), origin, .{})).typeErase();
            }

            for (args[1..]) |aN| {
                const b = try interpreter.eval(aN);

                if (!Rml.coerceBool(b)) return a;

                a = b;
            }

            return a;
        }
    }.fun,
};

/// short-circuiting logical OR on any number of arguments of any type;
/// returns the first succeeding argument or nil
pub const @"or" = Rml.Procedure{
    .native_macro = &struct {
        pub fn fun(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
            for (args[0..]) |aN| {
                const a = try interpreter.eval(aN);

                if (Rml.coerceBool(a)) return a;
            }

            return (try Rml.Obj(Rml.Nil).wrap(Rml.getRml(interpreter), origin, .{})).typeErase();
        }
    }.fun,
};

/// alias for `==`
pub const @"eq?" = @"==";
/// determine if any number of values are equal; uses structural comparison
/// it is an error to provide less than two arguments
pub fn @"=="(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len < 2)
        try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    const a = args[0];

    for (args[1..]) |aN| {
        const b = aN;

        if (!utils.equal(a, b)) return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, false)).typeErase();
    }

    return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, true)).typeErase();
}

/// alias for `!=`
pub const @"ne?" = @"!=";
/// determine if any number of values are not equal; uses structural comparison
/// it is an error to provide less than two arguments
pub fn @"!="(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len < 2)
        try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    const a = args[0];

    for (args[1..]) |aN| {
        const b = aN;

        if (utils.equal(a, b)) return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, false)).typeErase();
    }

    return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, true)).typeErase();
}

/// alias for `<`
pub const @"lt?" = @"<";
/// determine if any number of values are in strictly increasing order
/// it is an error to provide less than two arguments
pub fn @"<"(
    interpreter: *Rml.Interpreter,
    origin: Rml.Origin,
    args: []const Rml.Object,
) Rml.Result!Rml.Object {
    if (args.len < 2)
        try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var a = args[0];

    for (args[1..]) |aN| {
        const b = aN;

        if (utils.compare(a, b) != .Less) return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, false)).typeErase();

        a = b;
    }

    return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, true)).typeErase();
}

/// alias for `<=`
pub const @"le?" = @"<=";
/// determine if any number of values are in increasing order, allowing for equality on adjacent values
/// it is an error to provide less than two arguments
pub fn @"<="(
    interpreter: *Rml.Interpreter,
    origin: Rml.Origin,
    args: []const Rml.Object,
) Rml.Result!Rml.Object {
    if (args.len < 2)
        try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var a = args[0];

    for (args[1..]) |aN| {
        const b = aN;

        if (utils.compare(a, b) == .Greater) return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, false)).typeErase();

        a = b;
    }

    return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, true)).typeErase();
}

/// alias for `>`
pub const @"gt?" = @">";
/// determine if any number of values are in strictly decreasing order
/// it is an error to provide less than two arguments
pub fn @">"(
    interpreter: *Rml.Interpreter,
    origin: Rml.Origin,
    args: []const Rml.Object,
) Rml.Result!Rml.Object {
    if (args.len < 2)
        try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var a = args[0];

    for (args[1..]) |aN| {
        const b = aN;

        if (utils.compare(a, b) != .Greater) return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, false)).typeErase();

        a = b;
    }

    return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, true)).typeErase();
}

/// alias for `>=`
pub const @"ge?" = @">=";
/// determine if any number of values are in decreasing order, allowing for equality on adjacent values
/// it is an error to provide less than two arguments
pub fn @">="(
    interpreter: *Rml.Interpreter,
    origin: Rml.Origin,
    args: []const Rml.Object,
) Rml.Result!Rml.Object {
    if (args.len < 2)
        try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var a = args[0];

    for (args[1..]) |aN| {
        const b = aN;

        if (utils.compare(a, b) == .Less) return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, false)).typeErase();

        a = b;
    }

    return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, true)).typeErase();
}

/// calls a function with a list of arguments
pub const apply = Rml.Procedure{ .native_macro = &struct {
    pub fn fun(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
        if (args.len != 2)
            try interpreter.abort(origin, error.InvalidArgumentCount, "expected 2 arguments, found {}", .{args.len});

        const proc = try interpreter.castObj(Rml.Procedure, try interpreter.eval(args[0]));
        const argsArr = try Rml.coerceArray(try interpreter.eval(args[1])) orelse try interpreter.abort(origin, error.TypeError, "expected array, found {s}", .{Rml.TypeId.name(args[1].getTypeId())});

        return proc.data.call(interpreter, origin, args[0], argsArr.data.items());
    }
}.fun };

/// generates a unique Symbol
pub fn gensym(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result!Rml.Object {
    if (args.len != 0) {
        try interpreter.abort(origin, error.InvalidArgumentCount, "expected 0 arguments, found {}", .{args.len});
    }

    const rml = Rml.getRml(interpreter);

    const sym = try rml.data.gensym(origin);

    return (try Rml.Obj(Rml.Symbol).wrap(rml, origin, .{ .str = sym })).typeErase();
}

const ASSIGNMENT_OPERATOR = "=";

fn arithCastReduce(
    interpreter: *Rml.Interpreter,
    origin: Rml.Origin,
    acc: *Rml.Object,
    args: []const Rml.Object,
    comptime Ops: type,
) Rml.Result!Rml.Object {
    const offset = 1;
    comptime var expect: []const u8 = "";
    const decls = comptime std.meta.declarations(Ops);
    inline for (decls, 0..) |decl, i| comptime {
        expect = expect ++ decl.name;
        if (i < decls.len - 1) expect = expect ++ " | ";
    };
    for (args, 0..) |arg, i| {
        if (@hasDecl(Ops, "int") and Rml.isType(Rml.Int, acc.*)) {
            const int = Rml.forceObj(Rml.Int, acc.*);
            if (Rml.castObj(Rml.Int, arg)) |int2| {
                const int3: Rml.Obj(Rml.Int) = try .wrap(int2.getRml(), origin, @field(Ops, "int")(int.data.*, int2.data.*));
                acc.* = int3.typeErase();
            } else if (@hasDecl(Ops, "float") and Rml.isType(Rml.Float, arg)) {
                const float = Rml.forceObj(Rml.Float, arg);
                const float2: Rml.Obj(Rml.Float) = try .wrap(float.getRml(), origin, @field(Ops, "float")(@as(Rml.Float, @floatFromInt(int.data.*)), float.data.*));
                acc.* = float2.typeErase();
            } else if (Rml.castObj(Rml.Char, arg)) |char| {
                const int2: Rml.Obj(Rml.Int) = try .wrap(char.getRml(), origin, @field(Ops, "int")(int.data.*, @as(Rml.Int, @intCast(char.data.*))));
                acc.* = int2.typeErase();
            } else {
                try interpreter.abort(origin, error.TypeError, "expected " ++ expect ++ " for argument {}, found {s}", .{ i + offset, Rml.TypeId.name(arg.getTypeId()) });
            }
        } else if (@hasDecl(Ops, "float") and Rml.isType(Rml.Float, acc.*)) {
            const float = Rml.forceObj(Rml.Float, acc.*);

            if (Rml.castObj(Rml.Int, arg)) |int| {
                const float2: Rml.Obj(Rml.Float) = try .wrap(int.getRml(), origin, @field(Ops, "float")(float.data.*, @as(Rml.Float, @floatFromInt(int.data.*))));
                acc.* = float2.typeErase();
            } else if (Rml.castObj(Rml.Float, arg)) |float2| {
                const float3: Rml.Obj(Rml.Float) = try .wrap(float2.getRml(), origin, @field(Ops, "float")(float.data.*, float2.data.*));
                acc.* = float3.typeErase();
            } else if (Rml.castObj(Rml.Char, arg)) |char| {
                const float2: Rml.Obj(Rml.Float) = try .wrap(char.getRml(), origin, @field(Ops, "float")(float.data.*, @as(Rml.Float, @floatFromInt(char.data.*))));
                acc.* = float2.typeErase();
            } else {
                try interpreter.abort(origin, error.TypeError, "expected " ++ expect ++ " for argument {}, found {s}", .{ i + offset, Rml.TypeId.name(arg.getTypeId()) });
            }
        } else if (@hasDecl(Ops, "char") and Rml.isType(Rml.Char, acc.*)) {
            const char = Rml.forceObj(Rml.Char, acc.*);

            if (@hasDecl(Ops, "int") and Rml.isType(Rml.Int, arg)) {
                const int = Rml.forceObj(Rml.Int, arg);
                const int2: Rml.Obj(Rml.Int) = try .wrap(char.getRml(), origin, @field(Ops, "int")(@as(Rml.Int, @intCast(char.data.*)), int.data.*));
                acc.* = int2.typeErase();
            } else if (@hasDecl(Ops, "float") and Rml.isType(Rml.Float, arg)) {
                const float = Rml.forceObj(Rml.Float, arg);
                const float2: Rml.Obj(Rml.Float) = try .wrap(float.getRml(), origin, @field(Ops, "float")(@as(Rml.Float, @floatFromInt(char.data.*)), float.data.*));
                acc.* = float2.typeErase();
            } else if (Rml.castObj(Rml.Char, arg)) |char2| {
                const char3: Rml.Obj(Rml.Char) = try .wrap(char2.getRml(), origin, @field(Ops, "char")(char.data.*, char2.data.*));
                acc.* = char3.typeErase();
            } else {
                try interpreter.abort(origin, error.TypeError, "expected " ++ expect ++ " for argument {}, found {s}", .{ i + offset, Rml.TypeId.name(arg.getTypeId()) });
            }
        } else {
            try interpreter.abort(origin, error.TypeError, "expected " ++ expect ++ " for argument {}, found {s}", .{ i, Rml.TypeId.name(acc.getTypeId()) });
        }
    }

    return acc.*;
}
