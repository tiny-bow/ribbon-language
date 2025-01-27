const std = @import("std");

const Rml = @import("../Rml.zig");



pub const WithId = enum(usize) {_};

pub const Cancellation = struct {
    with_id: WithId,
    output: Rml.Object,
};

pub const Interpreter = struct {
    evaluation_env: Rml.Obj(Rml.Env),
    evidence_env: Rml.Obj(Rml.Env),
    cancellation: ?Cancellation = null,

    pub fn create(rml: *Rml) Rml.OOM! Interpreter {
        return Interpreter {
            .evaluation_env = try Rml.Obj(Rml.Env).wrap(rml, try .fromStr(rml, "system"), .{.allocator = rml.blobAllocator()}),
            .evidence_env = try Rml.Obj(Rml.Env).wrap(rml, try .fromStr(rml, "system"), .{.allocator = rml.blobAllocator()}),
        };
    }

    pub fn onCompare(a: *Interpreter, other: Rml.Object) Rml.Ordering {
        return Rml.compare(@intFromPtr(a), @intFromPtr(other.data));
    }

    pub fn onFormat(self: *Interpreter, _: Rml.Format, writer: std.io.AnyWriter) anyerror! void {
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

    pub fn freshCancellation(self: *Interpreter, origin: Rml.Origin) Rml.OOM! Rml.Obj(Rml.Procedure) {
        const withId = Rml.getRml(self).data.fresh(WithId);
        return Rml.Obj(Rml.Procedure).wrap(Rml.getRml(self), origin, Rml.Procedure { .cancellation = withId });
    }

    pub fn abort(self: *Interpreter, origin: Rml.Origin, err: Rml.Error, comptime fmt: []const u8, args: anytype) Rml.Error! noreturn {
        const diagnostic = Rml.getRml(self).diagnostic orelse return err;

        var diag = Rml.Diagnostic {
            .error_origin = origin,
        };

        // the error produced is only NoSpaceLeft, if the buffer is too small, so give the length of the buffer
        diag.message_len = len: {
            break :len (std.fmt.bufPrintZ(&diag.message_mem, fmt, args) catch {
                Rml.log.interpreter.warn("Diagnostic message too long, truncating", .{});
                break :len Rml.Diagnostic.MAX_LENGTH;
            }).len;
        };

        diagnostic.* = diag;

        return err;
    }

    pub fn eval(self: *Interpreter, expr: Rml.Object) Rml.Result! Rml.Object {
        var offset: usize = 0;
        return self.evalCheck(false, &.{expr}, &offset, null);
    }

    pub fn evalAll(self: *Interpreter, exprs: []const Rml.Object) Rml.Result! std.ArrayListUnmanaged(Rml.Object) {
        var results: std.ArrayListUnmanaged(Rml.Object) = .{};

        for (exprs) |expr| {
            const value = try self.eval(expr);

            try results.append(Rml.getRml(self).blobAllocator(), value);
        }

        return results;
    }

    pub fn evalCheck(self: *Interpreter, shouldInvoke: bool, program: []const Rml.Object, offset: *usize, workDone: ?*bool) Rml.Result! Rml.Object {
        Rml.log.interpreter.debug("evalCheck {any} @ {}", .{program, offset.*});

        const blob = program[offset.*..];

        const expr = if (offset.* < program.len) expr: {
            const out = program[offset.*];
            offset.* += 1;
            break :expr out;
        } else (try Rml.Obj(Rml.Nil).wrap(Rml.getRml(self), Rml.source.blobOrigin(blob), .{})).typeErase();

        const value = value: {
            if (Rml.castObj(Rml.Symbol, expr)) |symbol| {

                if (workDone) |x| x.* = true;

                Rml.log.interpreter.debug("looking up symbol {}", .{symbol});

                break :value self.lookup(symbol) orelse {
                    Rml.log.interpreter.err("failed to lookup symbol {}", .{symbol});
                    Rml.log.interpreter.err("evaluation_env: {debug}", .{self.evaluation_env.data.keys()});
                    Rml.log.interpreter.err("evidence_env: {debug}", .{self.evidence_env.data.keys()});
                    Rml.log.interpreter.err("global_env: {debug}", .{Rml.getRml(self).global_env.data.keys()});
                    Rml.log.interpreter.err("namespace_env: {debug}", .{Rml.getRml(self).namespace_env.data.keys()});
                    for (Rml.getRml(self).namespace_env.data.keys()) |key| {
                        Rml.log.interpreter.err("namespace {message}: {debug}", .{key, Rml.getRml(self).namespace_env.data.get(key).?});
                    }
                    try self.abort(expr.getOrigin(), error.UnboundSymbol, "no symbol `{s}` in evaluation environment", .{symbol});
                };
            } else if (Rml.castObj(Rml.Block, expr)) |block| {
                if (block.data.length() == 0) {
                    Rml.log.interpreter.debug("empty block", .{});
                    break :value expr;
                }

                if (workDone) |x| x.* = true;

                Rml.log.interpreter.debug("running block", .{});
                break :value try self.runProgram(block.data.kind == .paren, block.data.items());
            } else if (Rml.castObj(Rml.Quote, expr)) |quote| {
                if (workDone) |x| x.* = true;

                Rml.log.interpreter.debug("running quote", .{});
                break :value try quote.data.run(self);
            }

            Rml.log.interpreter.debug("cannot evaluate further: {}", .{expr});

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
        orelse self.evidence_env.data.get(symbol)
        orelse Rml.getRml(self).global_env.data.get(symbol);
    }

    pub fn runProgram(self: *Interpreter, shouldInvoke: bool, program: []const Rml.Object) Rml.Result! Rml.Object {
        Rml.log.interpreter.debug("runProgram {any}", .{program});


        var last: Rml.Object = (try Rml.Obj(Rml.Nil).wrap(Rml.getRml(self), Rml.source.blobOrigin(program), .{})).typeErase();

        Rml.log.interpreter.debug("runProgram - begin loop", .{});

        var offset: usize = 0;
        while (offset < program.len) {
            const value = try self.evalCheck(shouldInvoke, program, &offset, null);

            last = value;
        }

        Rml.log.interpreter.debug("runProgram - end loop: {}", .{last});

        return last;
    }

    pub fn invoke(self: *Interpreter, callOrigin: Rml.Origin, blame: Rml.Object, callable: Rml.Object, args: []const Rml.Object) Rml.Result! Rml.Object {
        if (Rml.castObj(Rml.Procedure, callable)) |procedure| {
            return procedure.data.call(self, callOrigin, blame, args);
        } else {
            try self.abort(callOrigin, error.TypeError, "expected a procedure, got {s}: {s}", .{Rml.TypeId.name(callable.getTypeId()), callable});
        }
    }
};

