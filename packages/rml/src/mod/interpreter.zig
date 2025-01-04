const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Rml = @import("root.zig");
const Ordering = Rml.Ordering;
const Error = Rml.Error;
const OOM = Rml.OOM;
const log = Rml.log;
const Object = Rml.Object;
const Origin = Rml.Origin;
const Obj = Rml.Obj;
const ptr = Rml.ptr;
const Nil = Rml.Nil;
const Env = Rml.Env;
const Symbol = Rml.Symbol;
const Block = Rml.Block;
const Quote = Rml.Quote;
const Writer = Rml.Writer;
const getObj = Rml.getObj;
const getHeader = Rml.getHeader;
const getTypeId = Rml.getTypeId;
const getRml = Rml.getRml;
const castObj = Rml.castObj;
const forceObj = Rml.forceObj;
const downgradeCast = Rml.downgradeCast;


pub const evaluation = std.log.scoped(.evaluation);


pub const Result = Signal || Error || Rml.parser.SyntaxError;
pub const Signal = error { Terminate };
pub const EvalError = error {
    TypeError,
    PatternError,
    UnboundSymbol,
    SymbolAlreadyBound,
    InvalidArgumentCount,
};

pub const Interpreter = struct {
    evaluation_env: Obj(Env),

    pub fn create(rml: *Rml) OOM! Interpreter {
        return .{.evaluation_env = try Obj(Env).wrap(rml, try .fromStr(rml, "system"), .{})};
    }

    pub fn onCompare(a: ptr(Interpreter), other: Object) Ordering {
        return Rml.compare(@intFromPtr(a), @intFromPtr(other.data));
    }

    pub fn onFormat(self: ptr(Interpreter), writer: Obj(Writer)) Error! void {
        return writer.data.print("Obj(Interpreter){x}", .{@intFromPtr(self)});
    }

    pub fn reset(self: ptr(Interpreter)) OOM! void {
        const rml = getRml(self);
        self.evaluation_env = try Obj(Env).wrap(rml, getHeader(self).origin, .{});
    }

    pub fn castObj(self: ptr(Interpreter), comptime T: type, object: Object) Error! Obj(T) {
        if (Rml.castObj(T, object)) |x| return x
        else {
            try self.abort(object.getOrigin(), error.TypeError, "expected `{s}`, got `{s}`", .{@typeName(T), Rml.TypeId.name(object.getTypeId())});
        }
    }

    pub fn abort(self: ptr(Interpreter), origin: Origin, err: Error, comptime fmt: []const u8, args: anytype) Error! noreturn {
        const diagnostic = getRml(self).diagnostic orelse return err;

        var diag = Rml.Diagnostic {
            .error_origin = origin,
        };

        // the error produced is only NoSpaceLeft, if the buffer is too small, so give the length of the buffer
        diag.message_len = len: {
            break :len (std.fmt.bufPrintZ(&diag.message_mem, fmt, args) catch {
                log.warn("Diagnostic message too long, truncating", .{});
                break :len Rml.Diagnostic.MAX_LENGTH;
            }).len;
        };

        diagnostic.* = diag;

        return err;
    }

    pub fn eval(self: ptr(Interpreter), expr: Object) Result! Object {
        var offset: usize = 0;
        return self.evalCheck(expr.getOrigin(), false, &.{expr}, &offset, null);
    }

    pub fn evalAll(self: ptr(Interpreter), exprs: []const Object) Result! Rml.array.ArrayUnmanaged {
        const rml = getRml(self);

        var results: Rml.array.ArrayUnmanaged = .{};

        for (exprs) |expr| {
            const value = try self.eval(expr);

            try results.append(rml, value);
        }

        return results;
    }

    pub fn evalCheck(self: ptr(Interpreter), origin: Origin, shouldInvoke: bool, program: []const Object, offset: *usize, workDone: ?*bool) Result! Object {
        evaluation.debug("evalCheck {}:{any} @ {}", .{origin, program, offset.*});

        const expr = if (offset.* < program.len) expr: {
            const out = program[offset.*];
            offset.* += 1;
            break :expr out;
        } else (try Obj(Rml.Nil).wrap(getRml(self), origin, .{})).typeErase();

        const value = value: {
            if (Rml.castObj(Symbol, expr)) |symbol| {

                if (workDone) |x| x.* = true;

                evaluation.debug("looking up symbol {}", .{symbol});

                break :value self.lookup(symbol) orelse {
                    try self.abort(origin, error.UnboundSymbol, "no symbol `{s}` in evaluation environment", .{symbol});
                };
            } else if (Rml.castObj(Block, expr)) |block| {
                if (block.data.array.length() == 0) {
                    evaluation.debug("empty block", .{});
                    break :value expr;
                }

                if (workDone) |x| x.* = true;

                evaluation.debug("running block", .{});
                break :value try self.runProgram(block.getOrigin(), block.data.kind == .paren, block.data.items());
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

            return self.invoke(origin, expr, value, args);
        } else {
            return value;
        }
    }

    pub fn lookup(self: ptr(Interpreter), symbol: Obj(Symbol)) ?Object {
        return self.evaluation_env.data.get(symbol)
        orelse getRml(self).global_env.data.get(symbol);
    }

    pub fn runProgram(self: ptr(Interpreter), origin: Origin, shouldInvoke: bool, program: []const Object) Result! Object {
        evaluation.debug("runProgram {}:{any}", .{origin, program});


        var last: Object = (try Obj(Rml.Nil).wrap(getRml(self), origin, .{})).typeErase();

        evaluation.debug("runProgram - begin loop", .{});

        var offset: usize = 0;
        while (offset < program.len) {
            const value = try self.evalCheck(origin, shouldInvoke, program, &offset, null);

            last = value;
        }

        evaluation.debug("runProgram - end loop: {}", .{last});

        return last;
    }

    pub fn invoke(self: ptr(Interpreter), callOrigin: Origin, blame: Object, callable: Object, args: []const Object) Result! Object {
        if (Rml.castObj(Rml.procedure.Procedure, callable)) |procedure| {
            return procedure.data.call(self, callOrigin, blame, args);
        } else {
            try self.abort(callOrigin, error.TypeError, "expected a procedure, got {s}: {s}", .{Rml.TypeId.name(callable.getTypeId()), callable});
        }
    }
};

