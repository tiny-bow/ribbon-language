const std = @import("std");

const Rml = @import("root.zig");
const ptr = Rml.ptr;
const Obj = Rml.Obj;
const Result = Rml.Result;
const Object = Rml.Object;
const Origin = Rml.Origin;
const Nil = Rml.Nil;
const Bool = Rml.Bool;
const Int = Rml.Int;
const Float = Rml.Float;
const Char = Rml.Char;
const Writer = Rml.Writer;
const Interpreter = Rml.Interpreter;
const TypeId = Rml.TypeId;
const getRml = Rml.getRml;
const castObj = Rml.castObj;
const forceObj = Rml.forceObj;
const isType = Rml.isType;
const coerceBool = Rml.coerceBool;


/// import a namespace into the current environment
pub const import = Rml.Procedure {
    .native_macro = &struct {
        pub fn fun(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
            if (args.len != 1) try interpreter.abort(origin, error.InvalidArgumentCount, "expected 1 argument, found {}", .{args.len});

            const namespaceSym = try interpreter.castObj(Rml.Symbol, args[0]);
            defer namespaceSym.deinit();

            const namespace: Object = getRml(interpreter).namespace_env.data.get(namespaceSym) orelse {
                try interpreter.abort(origin, error.UnboundSymbol, "namespace {} not found; available namespaces are: {any}", .{namespaceSym, getRml(interpreter).namespace_env.data.keys()});
            };
            defer namespace.deinit();

            const env = try interpreter.castObj(Rml.Env, namespace);
            defer env.deinit();

            const localEnv: ptr(Rml.Env) = interpreter.evaluation_env.data;

            var it = env.data.table.iter();
            while (it.next()) |entry| {
                const slashSym = slashSym: { // TODO: use frame allocator
                    const slashStr = try std.fmt.allocPrint(getRml(interpreter).storage.object, "{}/{}", .{namespaceSym, entry.key_ptr.*});
                    defer getRml(interpreter).storage.object.free(slashStr);

                    break :slashSym try Rml.newWith(Rml.Symbol, getRml(interpreter), origin, .{slashStr});
                };
                errdefer slashSym.deinit();

                const val = entry.value_ptr.clone();
                defer val.deinit();

                try localEnv.rebindCell(slashSym, val);
            }

            return Rml.newObject(Nil, getRml(interpreter), origin);
        }
    }.fun,
};

/// Create a global variable binding
pub const global = Rml.Procedure {
    .native_macro = &struct {
        pub fn fun (_: ptr(Interpreter), _: Origin, _: []const Object) Result! Object {
            @panic("NYI");
            // Rml.interpreter.evaluation.debug("global {}: {any}", .{origin, args});

            // if (args.len < 1) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found 0", .{});

            // const sym = try interpreter.castObj(Rml.Symbol, args[0]);
            // errdefer sym.deinit();

            // const nilObj = try Rml.newObject(Nil, getRml(interpreter), origin);
            // errdefer nilObj.deinit();

            // const equalSym = try Rml.newObjectWith(Rml.Symbol, getRml(interpreter), origin, .{"="});
            // defer equalSym.deinit();

            // const obj =
            //     if (args.len == 1) nilObj.clone()
            //     else obj: {
            //         var offset: usize = 1;
            //         if (Rml.equal(args[offset], equalSym)) offset += 1;
            //         const body = args[offset..];
            //         break :obj if (body.len == 1) single: {
            //             const bod = body[0];
            //             if (Rml.castObj(Rml.Block, bod)) |b| {
            //                 defer b.deinit();

            //                 break :single try interpreter.runProgram(origin, b.data.kind == .paren, b.data.array.items());
            //             } else {
            //                 break :single try interpreter.eval(bod);
            //             }
            //         } else try interpreter.runProgram(origin, false, body);
            //     };
            // errdefer obj.deinit();

            // getRml(interpreter).global_env.data.bind(sym, obj) catch |err| {
            //     if (err == error.SymbolAlreadyBound) {
            //         try interpreter.abort(origin, error.SymbolAlreadyBound, "symbol `{}` is already bound", .{sym});
            //     } else {
            //         return err;
            //     }
            // };

            // return nilObj;
        }
    }.fun,
};


/// Create a local variable binding
pub const local = Rml.Procedure {
    .native_macro = &struct {
        pub fn fun(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
            Rml.interpreter.evaluation.debug("local {}: {any}", .{origin, args});

            if (args.len < 1)
                try interpreter.abort(origin, error.InvalidArgumentCount,
                    "expected at least a name for local variable", .{});

            const nilObj = try Rml.newObject(Nil, getRml(interpreter), origin);
            defer nilObj.deinit();

            const equalSym = try Rml.newObjectWith(Rml.Symbol, getRml(interpreter), origin, .{"="});
            defer equalSym.deinit();

            const patt, const offset = parse: {
                var diag: ?Rml.Diagnostic = null;
                const parseResult = Rml.Pattern.parse(&diag, args)
                    catch |err| {
                        if (err == error.SyntaxError) {
                            if (diag) |d| {
                                try interpreter.abort(origin, error.PatternError,
                                    "cannot parse local variable pattern: {}",
                                    .{d.formatter(error.SyntaxError)});
                            } else {
                                Rml.log.err("requested pattern parse diagnostic is null", .{});
                                try interpreter.abort(origin, error.PatternError,
                                    "cannot parse local variable pattern `{}`", .{args[0]});
                            }
                        }

                        return err;
                    };

                break :parse .{parseResult.value, parseResult.offset};
            };
            defer patt.deinit();

            Rml.parser.parsing.debug("local variable pattern: {}", .{patt});

            var dom = Rml.pattern.patternBinders(patt.typeEraseLeak())
                catch |err| switch (err) {
                    error.BadDomain => {
                        try interpreter.abort(origin, error.SyntaxError,
                            "bad domain in pattern `{}`", .{patt});
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
            defer dom.deinit(getRml(interpreter));

            // for (dom.keys()) |sym| {
            //     Rml.interpreter.evaluation.debug("rebinding local variable {} = nil", .{sym});
            //     try interpreter.evaluation_env.data.rebind(sym.clone(), nilObj.clone());
            // }

            const obj =
                if (args.len - offset == 0) nilObj.clone()
                else obj: {
                    if (!Rml.equal(args[offset], equalSym)) {
                        try interpreter.abort(origin, error.SyntaxError,
                            "expected `=` after local variable pattern", .{});
                    }

                    const body = args[offset + 1..];

                    if (body.len == 1) {
                        if (Rml.castObj(Rml.Block, body[0])) |bod| {
                            defer bod.deinit();

                            break :obj try interpreter.runProgram(
                                origin,
                                bod.data.kind == .paren,
                                bod.data.array.items(),
                            );
                        }
                    }

                    break :obj try interpreter.runProgram(origin, false, body);
                };
            defer obj.deinit();

            Rml.interpreter.evaluation.debug("evaluating local variable {} ({}) = {} ({})", .{
                patt, patt.getHeader().ref_count, obj, obj.getHeader().ref_count
            });

            const table = table: {
                var diag: ?Rml.Diagnostic = null;
                if (try patt.data.run(interpreter, &diag, origin, &.{obj})) |m| break :table m;

                if (diag) |d| {
                    try interpreter.abort(origin, error.PatternError,
                        "failed to match; {} vs {}:\n\t{}",
                        .{patt, obj, d.formatter(error.PatternError)});
                } else {
                    Rml.interpreter.evaluation.err("requested pattern diagnostic is null", .{});
                    try interpreter.abort(origin, error.PatternError,
                        "failed to match; {} vs {}", .{patt, obj});
                }
            };
            defer table.deinit();

            var it = table.data.unmanaged.iter();
            while (it.next()) |entry| {
                const sym = entry.key_ptr.clone();
                errdefer sym.deinit();
                const val = entry.value_ptr.clone();
                errdefer val.deinit();

                Rml.interpreter.evaluation.debug("setting local variable {} ({}) = {} ({})", .{
                    sym, sym.getHeader().ref_count, val, val.getHeader().ref_count
                });

                try interpreter.evaluation_env.data.rebind(sym, val);
            }

            return nilObj.clone();
        }
    }.fun,
};

/// Set the value of a variable associated with an existing binding in the current environment
pub const @"set!" = Rml.Procedure {
    .native_macro = &struct {
        pub fn fun (interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
            const sym = Rml.castObj(Rml.Symbol, args[0])
                orelse try interpreter.abort(origin, error.TypeError,
                    "expected symbol, found {s}", .{TypeId.name(args[0].getTypeId())});
            defer sym.deinit();

            const value = try interpreter.eval(args[1]);
            errdefer value.deinit();

            try interpreter.evaluation_env.data.set(sym, value);

            const nil = try Rml.newObject(Nil, getRml(interpreter), origin);
            return nil;
        }
    }.fun,
};

/// Create a function closure
pub const fun = Rml.Procedure {
    .native_macro = &struct {
        pub fn fun(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
            Rml.interpreter.evaluation.debug("fun {}: {any}", .{origin, args});

            if (args.len == 0) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found 0", .{});

            const rml = getRml(interpreter);

            var cases: Rml.array.TypedArrayUnmanaged(Rml.procedure.Case) = .{};
            errdefer cases.deinit(rml);

            if (args.len == 1) {
                Rml.parser.parsing.debug("case fun", .{});
                const caseSet: Obj(Rml.Block) = try interpreter.castObj(Rml.Block, args[0]);
                defer caseSet.deinit();
                Rml.parser.parsing.debug("case set {}", .{caseSet});

                var isCases = true;
                for (caseSet.data.items()) |obj| {
                    if (!Rml.isType(Rml.Block, obj)) {
                        isCases = false;
                        break;
                    }
                }

                if (isCases) {
                    for (caseSet.data.array.items()) |case| {
                        Rml.parser.parsing.debug("case {}", .{case});
                        const caseBlock = try interpreter.castObj(Rml.Block, case);
                        defer caseBlock.deinit();

                        const c = try Rml.procedure.Case.parse(interpreter, caseBlock.getOrigin(), caseBlock.data.array.items());
                        errdefer c.deinit();

                        try cases.append(rml, c);
                    }
                } else {
                    Rml.parser.parsing.debug("fun single case: {any}", .{caseSet.data.array.items()});
                    const c = try Rml.procedure.Case.parse(interpreter, caseSet.getOrigin(), caseSet.data.array.items());
                    errdefer c.deinit();

                    try cases.append(rml, c);
                }
            } else {
                Rml.parser.parsing.debug("fun single case: {any}", .{args});
                const c = try Rml.procedure.Case.parse(interpreter, origin, args);
                errdefer c.deinit();

                try cases.append(rml, c);
            }

            const env = try interpreter.evaluation_env.data.clone(origin);
            errdefer env.deinit();

            const out = try Rml.wrapObject(rml, origin, Rml.Procedure {
                .function = .{
                    .env = env,
                    .cases = cases,
                },
            });

            Rml.parser.parsing.debug("fun done: {} ({})", .{out, out.getHeader().ref_count});

            return out;
        }
    }.fun,
};

/// Create a macro closure
pub const macro = Rml.Procedure {
    .native_macro = &struct {
        pub fn fun(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
            Rml.interpreter.evaluation.debug("macro {}: {any}", .{origin, args});

            if (args.len == 0) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found 0", .{});

            const rml = getRml(interpreter);

            var cases: Rml.array.TypedArrayUnmanaged(Rml.procedure.Case) = .{};
            errdefer cases.deinit(rml);

            if (args.len == 1) {
                Rml.interpreter.evaluation.debug("case macro", .{});
                const caseSet: Obj(Rml.Block) = try interpreter.castObj(Rml.Block, args[0]);
                defer caseSet.deinit();
                Rml.interpreter.evaluation.debug("case set {}", .{caseSet});

                var isCases = true;
                for (caseSet.data.items()) |obj| {
                    if (!Rml.isType(Rml.Block, obj)) {
                        isCases = false;
                        break;
                    }
                }

                if (isCases) {
                    for (caseSet.data.array.items()) |case| {
                        Rml.interpreter.evaluation.debug("case {}", .{case});
                        const caseBlock = try interpreter.castObj(Rml.Block, case);
                        defer caseBlock.deinit();

                        const c = try Rml.procedure.Case.parse(interpreter, origin, caseBlock.data.array.items());
                        errdefer c.deinit();

                        try cases.append(rml, c);
                    }
                } else {
                    Rml.interpreter.evaluation.debug("macro single case: {any}", .{caseSet.data.array.items()});
                    const c = try Rml.procedure.Case.parse(interpreter, origin, caseSet.data.array.items());
                    errdefer c.deinit();

                    try cases.append(rml, c);
                }
            } else {
                Rml.interpreter.evaluation.debug("macro single case: {any}", .{args});
                const c = try Rml.procedure.Case.parse(interpreter, origin, args);
                errdefer c.deinit();

                try cases.append(rml, c);
            }

            const env = try interpreter.evaluation_env.data.clone(origin);
            errdefer env.deinit();

            const out = try Rml.wrapObject(rml, origin, Rml.Procedure {
                .macro = .{
                    .env = env,
                    .cases = cases,
                },
            });

            return out;
        }
    }.fun,
};

/// Print any number of arguments followed by a new line
pub fn @"print-ln"(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    const rml = getRml(interpreter);

    const stdout = std.io.getStdOut();
    const nativeWriter = stdout.writer();

    const writer: Obj(Writer) = try .new(rml, origin, .{nativeWriter.any()});
    defer writer.deinit();

    try writer.data.print("{}: ", .{origin});

    for (args) |arg| try arg.getHeader().onFormat(writer);

    try writer.data.writeAll("\n");

    return Rml.newObject(Nil, rml, origin);
}



/// Print any number of arguments
pub fn print(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    const rml = getRml(interpreter);

    const stdout = std.io.getStdOut();
    const nativeWriter = stdout.writer();

    const writer: Obj(Writer) = try .new(rml, origin, .{nativeWriter.any()});
    defer writer.deinit();

    for (args) |arg| try arg.getHeader().onFormat(writer);

    return Rml.newObject(Nil, rml, origin);
}



/// Alias for `+`
pub const add = @"+";
/// Sum any number of arguments of type `int | float | char`;
/// if only one argument is provided, return the argument's absolute value
pub fn @"+"(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    if (args.len == 0) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found 0", .{});

    var sum: Object = args[0].clone();
    defer sum.deinit();

    if (args.len == 1) {
        if (castObj(Int, sum)) |int| {
            defer int.deinit();

            return (try Obj(Int).wrap(int.getRml(), origin, @intCast(@abs(int.data.*)))).typeEraseLeak();
        } else if (castObj(Float, sum)) |float| {
            defer float.deinit();

            return (try Obj(Float).wrap(float.getRml(), origin, @abs(float.data.*))).typeEraseLeak();
        } if (castObj(Char, sum)) |char| {
            defer char.deinit();

            return (try Obj(Char).wrap(char.getRml(), origin, char.data.*)).typeEraseLeak();
        } else {
            try interpreter.abort(origin, error.TypeError, "expected int | float | char, found {s}", .{TypeId.name(sum.getTypeId())});
        }
    }

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Int, b: Int) Int { return a + b; }
        pub fn float(a: Float, b: Float) Float { return a + b; }
        pub fn char(a: Char, b: Char) Char { return a + b; }
    });
}



/// Alias for `-`
pub const sub = @"-";
/// Subtract any number of arguments of type `int | float | char`;
/// if only one argument is provided, return the argument's negative value
pub fn @"-"(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    if (args.len == 0) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found 0", .{});

    var sum: Object = args[0].clone();
    defer sum.deinit();

    if (args.len == 1) {
        if (castObj(Int, sum)) |int| {
            defer int.deinit();

            return (try Obj(Int).wrap(int.getRml(), origin, -int.data.*)).typeEraseLeak();
        } else if (castObj(Float, sum)) |float| {
            defer float.deinit();

            return (try Obj(Float).wrap(float.getRml(), origin, -float.data.*)).typeEraseLeak();
        } if (castObj(Char, sum)) |char| { // TODO: ???
            defer char.deinit();

            return (try Obj(Char).wrap(char.getRml(), origin, char.data.*)).typeEraseLeak();
        } else {
            try interpreter.abort(origin, error.TypeError, "expected int | float | char, found {s}", .{TypeId.name(sum.getTypeId())});
        }
    }

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Int, b: Int) Int { return a - b; }
        pub fn float(a: Float, b: Float) Float { return a - b; }
        pub fn char(a: Char, b: Char) Char { return a - b; }
    });
}


/// Alias for `/`
pub const div = @"/";
/// Divide any number of arguments of type `int | float | char`;
/// it is an error to provide less than two arguments
pub fn @"/"(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Object = args[0].clone();
    defer sum.deinit();

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Int, b: Int) Int { return @divFloor(a, b); }
        pub fn float(a: Float, b: Float) Float { return a / b; }
        pub fn char(a: Char, b: Char) Char { return @divFloor(a, b); }
    });
}


/// Alias for `*`
pub const mul = @"*";
/// Multiply any number of arguments of type `int | float | char`;
/// it is an error to provide less than two arguments
pub fn @"*"(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Object = args[0].clone();
    defer sum.deinit();

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Int, b: Int) Int { return a * b; }
        pub fn float(a: Float, b: Float) Float { return a * b; }
        pub fn char(a: Char, b: Char) Char { return a * b; }
    });
}


/// remainder division on any number of arguments of type `int | float | char`;
/// it is an error to provide less than two arguments
pub fn @"rem"(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Object = args[0].clone();
    defer sum.deinit();

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Int, b: Int) Int { return @rem(a, b); }
        pub fn float(a: Float, b: Float) Float { return @rem(a, b); }
        pub fn char(a: Char, b: Char) Char { return @rem(a, b); }
    });
}


/// exponentiation on any number of arguments of type `int | float | char`;
/// it is an error to provide less than two arguments
pub fn pow(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Object = args[0].clone();
    defer sum.deinit();

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Int, b: Int) Int { return std.math.pow(Int, a, b); }
        pub fn float(a: Float, b: Float) Float { return std.math.pow(Float, a, b); }
        pub fn char(a: Char, b: Char) Char { return std.math.pow(Char, a, b); }
    });
}


/// bitwise NOT on an argument of type `int | char`
pub fn @"bit-not"(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    if (args.len != 1) try interpreter.abort(origin, error.InvalidArgumentCount, "expected 1 argument, found {}", .{args.len});

    if (castObj(Int, args[0])) |i| {
        return (try Obj(Int).wrap(i.getRml(), origin, ~i.data.*)).typeErase();
    } else if (castObj(Char, args[0])) |c| {
        return (try Obj(Char).wrap(c.getRml(), origin, ~c.data.*)).typeEraseLeak();
    } else {
        try interpreter.abort(origin, error.TypeError, "expected int | char, found {s}", .{TypeId.name(args[0].getTypeId())});
    }
}


/// bitwise AND on any number of arguments of type `int | char`;
/// it is an error to provide less than two arguments
pub fn @"bit-and"(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Object = args[0].clone();
    defer sum.deinit();

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Int, b: Int) Int { return a & b; }
        pub fn char(a: Char, b: Char) Char { return a & b; }
    });
}

/// bitwise OR on any number of arguments of type `int | char`;
/// it is an error to provide less than two arguments
pub fn @"bit-or"(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Object = args[0].clone();
    defer sum.deinit();

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Int, b: Int) Int { return a | b; }
        pub fn char(a: Char, b: Char) Char { return a | b; }
    });
}

/// bitwise XOR on any number of arguments of type `int | char`;
/// it is an error to provide less than two arguments
pub fn @"bit-xor"(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    if (args.len < 2) try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

    var sum: Object = args[0].clone();
    defer sum.deinit();

    return arithCastReduce(interpreter, origin, &sum, args[1..], struct {
        pub fn int(a: Int, b: Int) Int { return a ^ b; }
        pub fn char(a: Char, b: Char) Char { return a ^ b; }
    });
}


/// coerce an argument to type `bool`
pub fn @"truthy?"(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    if (args.len != 1) {
        try interpreter.abort(origin, error.InvalidArgumentCount, "expected 1 argument, found {}", .{args.len});
    }

    return (try Obj(Rml.Bool).wrap(getRml(interpreter), origin, Rml.coerceBool(args[0]))).typeEraseLeak();
}

/// logical NOT on an argument coerced to type `bool`
pub fn not(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
    if (args.len != 1) {
        try interpreter.abort(origin, error.InvalidArgumentCount, "expected 1 argument, found {}", .{args.len});
    }

    return (try Obj(Rml.Bool).wrap(getRml(interpreter), origin, !Rml.coerceBool(args[0]))).typeEraseLeak();
}

/// Short-circuiting logical AND on any number of arguments of any type;
/// returns the last succeeding argument or nil
pub const @"and" = Rml.Procedure {
    .native_macro = &struct{
        pub fn fun(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
            if (args.len == 0) return Rml.newObject(Rml.Nil, getRml(interpreter), origin);

            var a = try interpreter.eval(args[0]);
            errdefer a.deinit();

            if (!coerceBool(a)) {
                return Rml.newObject(Rml.Nil, getRml(interpreter), origin);
            }

            for (args[1..]) |aN| {
                const b = try interpreter.eval(aN);
                errdefer b.deinit();

                if (!coerceBool(b)) return a;

                a.deinit();
                a = b;
            }

            return a;
        }
    }.fun,
};

/// Short-circuiting logical OR on any number of arguments of any type;
/// returns the first succeeding argument or nil
pub const @"or" = Rml.Procedure {
    .native_macro = &struct{
        pub fn fun(interpreter: ptr(Interpreter), origin: Origin, args: []const Object) Result! Object {
            for (args[0..]) |aN| {
                const a = try interpreter.eval(aN);

                if (coerceBool(a)) return a;

                a.deinit();
            }

            return Rml.newObject(Rml.Nil, getRml(interpreter), origin);
        }
    }.fun,
};


fn arithCastReduce(
    interpreter: ptr(Interpreter),
    origin: Origin, acc: *Object, args: []const Object,
    comptime Ops: type,
) Result! Object {
    const offset = 1;
    comptime var expect: []const u8 = "";
    const decls = comptime std.meta.declarations(Ops);
    inline for (decls, 0..) |decl, i| comptime {
        expect = expect ++ decl.name;
        if (i < decls.len - 1) expect = expect ++ " | ";
    };
    for (args, 0..) |arg, i| {
        if (@hasDecl(Ops, "int") and isType(Int, acc.*)) {
            const int = forceObj(Int, acc.*);
            defer int.deinit();

            if (castObj(Int, arg)) |int2| {
                defer int2.deinit();

                const int3: Obj(Int) = try .wrap(int2.getRml(), origin, @field(Ops, "int")(int.data.*, int2.data.*));
                defer int3.deinit();

                acc.deinit();
                acc.* = int3.typeErase();
            } else if (@hasDecl(Ops, "float") and isType(Float, arg)) {
                const float = forceObj(Float, arg);
                defer float.deinit();

                const float2: Obj(Float) = try .wrap(float.getRml(), origin, @field(Ops, "float")(@as(Float, @floatFromInt(int.data.*)), float.data.*));
                defer float2.deinit();

                acc.deinit();
                acc.* = float2.typeErase();
            } else if (castObj(Char, arg)) |char| {
                defer char.deinit();

                const int2: Obj(Int) = try .wrap(char.getRml(), origin, @field(Ops, "int")(int.data.*, @as(Int, @intCast(char.data.*))));
                defer int2.deinit();

                acc.deinit();
                acc.* = int2.typeErase();
            } else {
                try interpreter.abort(origin, error.TypeError, "expected " ++ expect ++ " for argument {}, found {s}", .{i + offset, TypeId.name(arg.getTypeId())});
            }
        } else if (@hasDecl(Ops, "float") and isType(Float, acc.*)) {
            const float = forceObj(Float, acc.*);
            defer float.deinit();

            if (castObj(Int, arg)) |int| {
                defer int.deinit();

                const float2: Obj(Float) = try .wrap(int.getRml(), origin, @field(Ops, "float")(float.data.*, @as(Float, @floatFromInt(int.data.*))));
                defer float2.deinit();

                acc.deinit();
                acc.* = float2.typeErase();
            } else if (castObj(Float, arg)) |float2| {
                defer float2.deinit();

                const float3: Obj(Float) = try .wrap(float2.getRml(), origin, @field(Ops, "float")(float.data.*, float2.data.*));
                defer float3.deinit();

                acc.deinit();
                acc.* = float3.typeErase();
            } else if (castObj(Char, arg)) |char| {
                defer char.deinit();

                const float2: Obj(Float) = try .wrap(char.getRml(), origin, @field(Ops, "float")(float.data.*, @as(Float, @floatFromInt(char.data.*))));
                defer float2.deinit();

                acc.deinit();
                acc.* = float2.typeErase();
            } else {
                try interpreter.abort(origin, error.TypeError, "expected " ++ expect ++ " for argument {}, found {s}", .{i + offset, TypeId.name(arg.getTypeId())});
            }
        } else if (@hasDecl(Ops, "char") and isType(Char, acc.*)) {
            const char = forceObj(Char, acc.*);
            defer char.deinit();

            if (@hasDecl(Ops, "int") and isType(Int, arg)) {
                const int = forceObj(Int, arg);
                defer int.deinit();

                const int2: Obj(Int) = try .wrap(char.getRml(), origin, @field(Ops, "int")(@as(Int, @intCast(char.data.*)), int.data.*));
                defer int2.deinit();

                acc.deinit();
                acc.* = int2.typeErase();
            } else if (@hasDecl(Ops, "float") and isType(Float, arg)) {
                const float = forceObj(Float, arg);
                defer float.deinit();

                const float2: Obj(Float) = try .wrap(float.getRml(), origin, @field(Ops, "float")(@as(Float, @floatFromInt(char.data.*)), float.data.*));
                defer float2.deinit();

                acc.deinit();
                acc.* = float2.typeErase();
            } else if (castObj(Char, arg)) |char2| {
                defer char2.deinit();

                const char3: Obj(Char) = try .wrap(char2.getRml(), origin, @field(Ops, "char")(char.data.*, char2.data.*));
                defer char3.deinit();

                acc.deinit();
                acc.* = char3.typeErase();
            } else {
                try interpreter.abort(origin, error.TypeError, "expected " ++ expect ++ " for argument {}, found {s}", .{i + offset, TypeId.name(arg.getTypeId())});
            }
        } else {
            try interpreter.abort(origin, error.TypeError, "expected " ++ expect ++ " for argument {}, found {s}", .{i, TypeId.name(acc.getTypeId())});
        }
    }

    return acc.clone();
}

