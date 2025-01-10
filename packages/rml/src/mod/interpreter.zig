const std = @import("std");

const Rml = @import("root.zig");


pub const evaluation = std.log.scoped(.evaluation);


pub const Result = Signal || Rml.Error;
pub const Signal = error { Terminate };
pub const EvalError = error {
    TypeError,
    PatternError,
    UnboundSymbol,
    SymbolAlreadyBound,
    InvalidArgumentCount,
};

pub const Interpreter = struct {
    evaluation_env: Rml.Obj(Rml.Env),

    pub fn create(rml: *Rml) Rml.OOM! Interpreter {
        return .{.evaluation_env = try Rml.Obj(Rml.Env).wrap(rml, try .fromStr(rml, "system"), .{.allocator = rml.blobAllocator()})};
    }

    pub fn onCompare(a: *Interpreter, other: Rml.Object) Rml.Ordering {
        return Rml.compare(@intFromPtr(a), @intFromPtr(other.data));
    }

    pub fn onFormat(self: *Interpreter, writer: std.io.AnyWriter) anyerror! void {
        return writer.print("Rml.Obj(Interpreter){x}", .{@intFromPtr(self)});
    }

    pub fn reset(self: *Interpreter) Rml.OOM! void {
        const rml = Rml.getRml(self);
        self.evaluation_env = try Rml.Obj(Rml.Env).wrap(rml, Rml.getHeader(self).origin, .{.allocator = rml.blobAllocator()});
    }

    pub fn castObj(self: *Interpreter, comptime T: type, object: Rml.Object) Rml.Error! Rml.Obj(T) {
        if (Rml.castObj(T, object)) |x| return x
        else {
            try self.abort(object.getOrigin(), error.TypeError, "expected `{s}`, got `{s}`", .{@typeName(T), Rml.TypeId.name(object.getTypeId())});
        }
    }

    pub fn abort(self: *Interpreter, origin: Rml.Origin, err: Rml.Error, comptime fmt: []const u8, args: anytype) Rml.Error! noreturn {
        const diagnostic = Rml.getRml(self).diagnostic orelse return err;

        var diag = Rml.Diagnostic {
            .error_origin = origin,
        };

        // the error produced is only NoSpaceLeft, if the buffer is too small, so give the length of the buffer
        diag.message_len = len: {
            break :len (std.fmt.bufPrintZ(&diag.message_mem, fmt, args) catch {
                evaluation.warn("Diagnostic message too long, truncating", .{});
                break :len Rml.Diagnostic.MAX_LENGTH;
            }).len;
        };

        diagnostic.* = diag;

        return err;
    }

    pub fn eval(self: *Interpreter, expr: Rml.Object) Result! Rml.Object {
        var offset: usize = 0;
        return self.evalCheck(false, &.{expr}, &offset, null);
    }

    pub fn evalAll(self: *Interpreter, exprs: []const Rml.Object) Result! []Rml.Object {
        var results: std.ArrayListUnmanaged(Rml.Object) = .{};

        for (exprs) |expr| {
            const value = try self.eval(expr);

            try results.append(Rml.getRml(self).blobAllocator(), value);
        }

        return results.items;
    }

    pub fn evalCheck(self: *Interpreter, shouldInvoke: bool, program: []const Rml.Object, offset: *usize, workDone: ?*bool) Result! Rml.Object {
        evaluation.debug("evalCheck {any} @ {}", .{program, offset.*});

        const blob = program[offset.*..];

        const expr = if (offset.* < program.len) expr: {
            const out = program[offset.*];
            offset.* += 1;
            break :expr out;
        } else (try Rml.Obj(Rml.Nil).wrap(Rml.getRml(self), Rml.source.blobOrigin(blob), .{})).typeErase();

        const value = value: {
            if (Rml.castObj(Rml.Symbol, expr)) |symbol| {

                if (workDone) |x| x.* = true;

                evaluation.debug("looking up symbol {}", .{symbol});

                break :value self.lookup(symbol) orelse {
                    try self.abort(expr.getOrigin(), error.UnboundSymbol, "no symbol `{s}` in evaluation environment", .{symbol});
                };
            } else if (Rml.castObj(Rml.Block, expr)) |block| {
                if (block.data.length() == 0) {
                    evaluation.debug("empty block", .{});
                    break :value expr;
                }

                if (workDone) |x| x.* = true;

                evaluation.debug("running block", .{});
                break :value try self.runProgram(block.data.kind == .paren, block.data.items());
            } else if (Rml.castObj(Rml.Quote, expr)) |quote| {
                if (workDone) |x| x.* = true;

                evaluation.debug("running quote", .{});
                break :value try quote.data.run(self);
            }

            evaluation.debug("cannot evaluate further: {}", .{expr});

            break :value expr;
        };

        if (Rml.isType(Rml.Procedure, value) and (shouldInvoke or program.len > offset.*)) {
            const args = program[offset.*..];
            offset.* = program.len;

            return self.invoke(Rml.source.blobOrigin(blob), expr, value, args);
        } else {
            return value;
        }
    }

    pub fn lookup(self: *Interpreter, symbol: Rml.Obj(Rml.Symbol)) ?Rml.Object {
        return self.evaluation_env.data.get(symbol)
        orelse Rml.getRml(self).global_env.data.get(symbol);
    }

    pub fn runProgram(self: *Interpreter, shouldInvoke: bool, program: []const Rml.Object) Result! Rml.Object {
        evaluation.debug("runProgram {}:{any}", .{program});


        var last: Rml.Object = (try Rml.Obj(Rml.Nil).wrap(Rml.getRml(self), Rml.source.blobOrigin(program), .{})).typeErase();

        evaluation.debug("runProgram - begin loop", .{});

        var offset: usize = 0;
        while (offset < program.len) {
            const value = try self.evalCheck(shouldInvoke, program, &offset, null);

            last = value;
        }

        evaluation.debug("runProgram - end loop: {}", .{last});

        return last;
    }

    pub fn invoke(self: *Interpreter, callOrigin: Rml.Origin, blame: Rml.Object, callable: Rml.Object, args: []const Rml.Object) Result! Rml.Object {
        if (Rml.castObj(Rml.procedure.Procedure, callable)) |procedure| {
            return procedure.data.call(self, callOrigin, blame, args);
        } else {
            try self.abort(callOrigin, error.TypeError, "expected a procedure, got {s}: {s}", .{Rml.TypeId.name(callable.getTypeId()), callable});
        }
    }
};

