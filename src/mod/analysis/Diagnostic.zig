//! Compiler diagnostics facility for use by various analysis processes.
const Diagnostic = @This();

const std = @import("std");
const log = std.log.scoped(.diagnostic);

const common = @import("common");

const analysis = @import("../analysis.zig");

pub const Doc = common.PrettyPrinter.Doc;

test {
    // std.debug.print("semantic analysis for diagnostic\n", .{});
    std.testing.refAllDecls(@This());
}

/// The level of severity for this message.
severity: Severity,
/// The source location this diagnostic message pertains to.
source: analysis.Source,
/// The unique name of the diagnostic.
name: []const u8,
/// The human-readable message associated with this diagnostic.
message: *const Doc,
/// The list of notes associated with this diagnostic.
notes: []const Note,

/// The severity level of a diagnostic message.
pub const Severity = enum {
    /// An informational message, typically used for debugging or tracing.
    info,
    /// A warning message, indicating a potential issue that does not prevent compilation.
    warning,
    /// An error message, indicating a serious issue that prevents successful compilation.
    @"error",
};

/// A supplementary note providing additional context for a diagnostic message.
pub const Note = struct {
    /// The source location this note pertains to.
    source: analysis.Source,
    /// The human-readable message associated with this note.
    message: *const Doc,
};

/// A context for the generation and collection of diagnostics.
pub const Context = struct {
    /// The pretty printer used to format diagnostic messages.
    /// This also provides the allocators for all memory used in this context.
    pp: common.PrettyPrinter,
    /// The list of diagnostics collected in this context.
    diagnostics: common.ArrayList(Diagnostic) = .empty,
    /// Whether this context has encountered any error-level diagnostics.
    has_error: bool = false,

    /// Initializes a new diagnostic context with the given allocator.
    pub fn init(allocator: std.mem.Allocator) Context {
        return Context{
            .pp = common.PrettyPrinter.init(allocator),
        };
    }

    /// Deallocates all resources associated with this diagnostic context and its printer.
    pub fn deinit(self: *Context) void {
        self.diagnostics.deinit(self.pp.gpa);
        self.pp.deinit();
    }

    /// Determine if this context has any diagnostics recorded.
    pub fn hasDiagnostics(self: *const Context) bool {
        return self.diagnostics.items.len != 0;
    }

    /// Adds a new pre-composed diagnostic message to this context.
    /// * Note that this assumes ownership of the Diagnostic's allocations already belongs to the Context's PrettyPrinter
    pub fn append(self: *Context, diag: Diagnostic) !void {
        try self.diagnostics.append(self.pp.gpa, diag);

        if (diag.severity == .@"error") {
            self.has_error = true;
        }
    }

    /// Compose a new diagnostic message without adding it to this context. (Use `append` to add it later.)
    /// * Note that this assumes Docs used are already owned by the Context's PrettyPrinter
    pub fn compose(
        self: *Context,
        severity: Severity,
        source: analysis.Source,
        name: []const u8,
        message: *const Doc,
        notes: []const Note,
    ) !Diagnostic {
        return Diagnostic{
            .severity = severity,
            .source = source,
            .name = try self.pp.arena.allocator().dupe(u8, name),
            .message = message,
            .notes = try self.pp.arena.allocator().dupe(Note, notes),
        };
    }

    /// Adds a new diagnostic message to this context.
    /// * Note that this assumes Docs used are already owned by the Context's PrettyPrinter
    pub fn raise(
        self: *Context,
        severity: Severity,
        source: analysis.Source,
        name: []const u8,
        message: *const Doc,
        notes: []const Note,
    ) !void {
        const diag = try self.compose(severity, source, name, message, notes);

        try self.append(diag);

        if (severity == .@"error") {
            self.has_error = true;
        }
    }

    /// `raise` an informational diagnostic.
    pub fn info(
        self: *Context,
        source: analysis.Source,
        name: []const u8,
        message: *const Doc,
        notes: []const Note,
    ) !void {
        try self.raise(.info, source, name, message, notes);
    }

    /// `raise` a warning diagnostic.
    pub fn warn(
        self: *Context,
        source: analysis.Source,
        name: []const u8,
        message: *const Doc,
        notes: []const Note,
    ) !void {
        try self.raise(.warning, source, name, message, notes);
    }

    /// `raise` an error diagnostic.
    pub fn @"error"(
        self: *Context,
        source: analysis.Source,
        name: []const u8,
        message: *const Doc,
        notes: []const Note,
    ) !void {
        try self.raise(.@"error", source, name, message, notes);
    }

    /// Wrapper for `PrettyPrinter.fail`.
    pub fn fail(self: *Context) *const Doc {
        return self.pp.fail();
    }

    /// Wrapper for `PrettyPrinter.nil`.
    pub fn nil(self: *Context) *const Doc {
        return self.pp.nil();
    }

    /// Wrapper for `PrettyPrinter.text`.
    pub fn text(self: *Context, str: []const u8) *const Doc {
        return self.pp.text(str);
    }

    /// Wrapper for `PrettyPrinter.print`.
    pub fn print(self: *Context, comptime fmt: []const u8, args: anytype) *const Doc {
        return self.pp.print(fmt, args);
    }

    /// Wrapper for `PrettyPrinter.line`.
    pub fn line(self: *Context) *const Doc {
        return self.pp.line();
    }

    /// Wrapper for `PrettyPrinter.space`.
    pub fn space(self: *Context) *const Doc {
        return self.pp.space();
    }

    /// Wrapper for `PrettyPrinter.concat`.
    pub fn concat(self: *Context, docs: []const *const Doc) *const Doc {
        return self.pp.concat(docs);
    }

    /// Wrapper for `PrettyPrinter.nest`.
    pub fn nest(self: *Context, indent_val: usize, doc: *const Doc) *const Doc {
        return self.pp.nest(indent_val, doc);
    }

    /// Wrapper for `PrettyPrinter.hang`.
    pub fn hang(self: *Context, indent_val: usize, doc: *const Doc) *const Doc {
        return self.pp.hang(indent_val, doc);
    }

    /// Wrapper for `PrettyPrinter.breaker`.
    pub fn breaker(self: *Context, doc: *const Doc) *const Doc {
        return self.pp.breaker(doc);
    }

    /// Wrapper for `PrettyPrinter.filler`.
    pub fn filler(self: *Context, doc: *const Doc) *const Doc {
        return self.pp.filler(doc);
    }

    /// Wrapper for `PrettyPrinter.flow`.
    pub fn flow(self: *Context, docs: []const *const Doc) *const Doc {
        return self.pp.flow(docs);
    }

    /// Wrapper for `PrettyPrinter.join`.
    pub fn join(self: *Context, separator: *const Doc, docs: []const *const Doc) *const Doc {
        return self.pp.join(separator, docs);
    }

    /// Print all diagnostics to stderr.
    /// * Note this will panic on any errors during format/write.
    pub fn dumpDiagnostics(self: *Context, header: ?[]const u8) void {
        if (self.hasDiagnostics()) {
            var buf: [1024]u8 = undefined;
            const writer = std.debug.lockStderrWriter(&buf);
            defer writer.flush() catch unreachable;

            if (header) |h| writer.print("{s}:\n", .{h}) catch unreachable;
            self.writeAll(writer, .{ .indent_lvl = if (header != null) 1 else 0 }) catch unreachable;
        }
    }

    /// `std.fmt` impl
    pub fn format(self: *const Context, writer: *std.io.Writer) !void {
        for (self.diagnostics.items) |*diag| {
            try writer.print("{f}\n", .{diag});
        }
    }

    pub fn writeAll(self: *Context, writer: *std.io.Writer, options: common.PrettyPrinter.RenderOptions) !void {
        for (self.diagnostics.items) |*diag| {
            self.pp.render(
                diag.render(&self.pp),
                writer,
                options,
            ) catch |err| {
                log.err("Failed to render diagnostic: {s}", .{@errorName(err)});
                return error.WriteFailed;
            };
            // try writer.writeAll("\n");
        }
    }

    /// Pretty printer formatter
    pub fn render(self: *const Context) !void {
        var docs = self.pp.gpa.alloc(*const Doc, self.diagnostics.len) catch return self.fail();
        defer self.pp.gpa.free(docs);

        for (self.diagnostics.items, 0..) |*diag, i| {
            docs[i] = self.concat(&.{
                self.render(diag),
                if (i < self.diagnostics.len - 1) self.line() else self.nil(),
            });
        }

        return self.concat(docs);
    }
};

/// `std.fmt` impl
pub fn format(self: *const Diagnostic, writer: *std.io.Writer) !void {
    try writer.print("{s}{f}: {f}", .{
        @tagName(self.severity),
        self.source,
        self.message,
    });
    if (self.notes.len != 0) try writer.writeAll("\n");
    for (self.notes, 0..) |*note, i| {
        try writer.print("    note{f}: {f}", .{ note.source, note.message });
        if (i < self.notes.len - 1) try writer.writeAll("\n");
    }
}

/// Pretty printer formatter
pub fn render(self: *const Diagnostic, pp: *common.PrettyPrinter) *const Doc {
    return pp.concat(&.{
        pp.text(@tagName(self.severity)),
        pp.print("{f}:", .{self.source}),
        pp.hang(1, self.message),
        pp.nest(1, notes: {
            var note_docs = pp.gpa.alloc(*const Doc, self.notes.len + 1) catch return pp.fail();
            defer pp.gpa.free(note_docs);
            note_docs[0] = pp.line();
            for (self.notes, 0..) |*note, i| {
                note_docs[i + 1] = pp.concat(&.{
                    pp.print("note{f}:", .{note.source}),
                    pp.hang(1, note.message),
                    if (i < self.notes.len - 1) pp.line() else pp.nil(),
                });
            }
            break :notes pp.concat(note_docs);
        }),
    });
}

/// Convert a Diagnostic to a Note.
pub fn toNote(self: *const Diagnostic, pp: *common.PrettyPrinter) Note {
    return Note{
        .source = self.source,
        .message = pp.concat(&.{
            pp.print("{s}:", .{self.name}),
            pp.hang(1, self.message),

            pp.nest(1, notes: {
                if (self.notes.len == 0) break :notes pp.nil();
                var note_docs = pp.gpa.alloc(*const Doc, self.notes.len + 1) catch break :notes pp.fail();
                defer pp.gpa.free(note_docs);
                note_docs[0] = pp.line();
                for (self.notes, 0..) |*note, i| {
                    note_docs[i + 1] = pp.concat(&.{
                        pp.print("note{f}:", .{note.source}),
                        pp.hang(1, note.message),
                        if (i < self.notes.len - 1) pp.line() else pp.nil(),
                    });
                }
                break :notes pp.concat(note_docs);
            }),
        }),
    };
}
