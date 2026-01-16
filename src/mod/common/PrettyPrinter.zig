//! A Pretty Printer based on the Wadler-Leijen algorithm.
//! Supports both consistent (Group) and inconsistent (Flow/Fill) breaking.
const PrettyPrinter = @This();

const std = @import("std");
const log = std.log.scoped(.pretty);

// -------------------------------------------------------------------------
// Public API
// -------------------------------------------------------------------------

/// GPA used for building and the backing arena.
gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator) PrettyPrinter {
    return PrettyPrinter{
        .gpa = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
}

pub fn deinit(pp: *PrettyPrinter) void {
    pp.arena.deinit();
}

/// Create a failure document.
pub fn fail(_: *PrettyPrinter) *const Doc {
    return &fail_doc;
}

/// Create a document that contains nothing.
pub fn nil(_: *PrettyPrinter) *const Doc {
    return &nil_doc;
}

/// Literal text. Must not contain newlines.
pub fn text(pp: *PrettyPrinter, str: []const u8) *const Doc {
    return pp.make(.{
        .text = pp.arena.allocator().dupe(u8, str) catch return &fail_doc,
    });
}

/// Formatted text. Must not contain newlines.
pub fn print(pp: *PrettyPrinter, comptime fmt: []const u8, args: anytype) *const Doc {
    var interface = std.io.Writer.Allocating.init(pp.gpa);
    defer interface.deinit();

    interface.writer.print(fmt, args) catch return &fail_doc;

    return pp.text(interface.written());
}

/// A hard line break. Always breaks, preserving indentation.
pub fn line(_: *PrettyPrinter) *const Doc {
    return &line_doc;
}

/// A space that can become a newline if the line is full.
/// (Behaves like a space if it fits, newline if it doesn't).
pub fn space(pp: *PrettyPrinter) *const Doc {
    // A softline is a Union of (Space, Line)
    // If it fits, we do Space. If not, Line.
    return pp.makeUnion(pp.text(" "), pp.line());
}

/// Concatenate a list of documents.
pub fn concat(pp: *PrettyPrinter, docs: []const *const Doc) *const Doc {
    if (docs.len == 0) return pp.nil();
    return pp.make(.{
        .concat = pp.arena.allocator().dupe(*const Doc, docs) catch return &fail_doc,
    });
}

/// Increase indentation for the inner document.
pub fn nest(pp: *PrettyPrinter, indent_val: usize, doc: *const Doc) *const Doc {
    return pp.make(.{
        .nest = .{
            .indent = indent_val,
            .doc = doc,
        },
    });
}

/// Increase indentation for the inner document with a space proceeding it.
pub fn hang(pp: *PrettyPrinter, indent_val: usize, doc: *const Doc) *const Doc {
    return pp.nest(indent_val, pp.concat(&.{
        pp.space(),
        doc,
    }));
}

/// **Consistent Grouping**:
/// Treats the document as a single unit.
pub fn breaker(pp: *PrettyPrinter, doc: *const Doc) *const Doc {
    return pp.make(.{ .breaker = doc });
}

/// **Inconsistent Filling** (Flow Layout):
/// Treats the document as a flow, breaking only when necessary.
pub fn filler(pp: *PrettyPrinter, doc: *const Doc) *const Doc {
    return pp.make(.{ .filler = doc });
}

/// **Inconsistent Filling** (Flow Layout):
/// Collapses a list of documents onto lines, breaking only when necessary.
/// e.g. "Word word word \n word word"
pub fn flow(pp: *PrettyPrinter, docs: []const *const Doc) *const Doc {
    if (docs.len == 0) return pp.nil();

    // To achieve "fill", we join items with a `Union(Space, Line)`.
    // We DO NOT wrap this in a `group`. This allows the renderer to
    // decide purely based on "does the *next* word fit?" without forcing
    // the whole paragraph to break.
    var new_docs = std.ArrayList(*const Doc).empty;
    defer new_docs.deinit(pp.gpa);

    const separator = pp.space();

    for (docs, 0..) |d, i| {
        if (i > 0) new_docs.append(pp.gpa, separator) catch return &fail_doc;
        new_docs.append(pp.gpa, d) catch return &fail_doc;
    }

    return pp.concat(pp.arena.allocator().dupe(*const Doc, new_docs.items) catch return &fail_doc);
}

/// Join a list of docs with a specific separator.
pub fn join(pp: *PrettyPrinter, separator: *const Doc, docs: []const *const Doc) *const Doc {
    if (docs.len == 0) return pp.nil();
    var new_docs = std.ArrayList(*const Doc).empty;
    defer new_docs.deinit(pp.gpa);

    for (docs, 0..) |d, i| {
        if (i > 0) new_docs.append(pp.gpa, separator) catch return &fail_doc;
        new_docs.append(pp.gpa, d) catch return &fail_doc;
    }

    return pp.concat(pp.arena.allocator().dupe(*const Doc, new_docs.items) catch return &fail_doc);
}

pub const Doc = union(enum) {
    fail,
    nil,
    line,
    text: []const u8,
    concat: []const *const Doc,
    nest: struct { indent: usize, doc: *const Doc },

    /// This is the "Consistent" behavior.
    breaker: *const Doc,
    /// This is the "Inconsistent" behavior.
    filler: *const Doc,

    /// The core of the algorithm.
    /// A Union represents a choice: "Try LHS (Flat). If it fails, do RHS (Break)".
    /// Used to implement SoftLine and Fill.
    choice: struct { flat: *const Doc, broken: *const Doc },
};

const fail_doc: Doc = .fail;
const nil_doc: Doc = .nil;
const line_doc: Doc = .line;
const fail_str = "<<<Failed to allocate doc>>>";

fn make(pp: *PrettyPrinter, d: Doc) *const Doc {
    const ptr = pp.arena.allocator().create(Doc) catch return &fail_doc;
    ptr.* = d;
    return ptr;
}

fn makeUnion(pp: *PrettyPrinter, flat: *const Doc, broken: *const Doc) *const Doc {
    return pp.make(.{ .choice = .{ .flat = flat, .broken = broken } });
}

pub const RenderOptions = struct {
    max_width: usize = 80,
    indent_str: []const u8 = "    ",
    indent_lvl: usize = 0,
};

pub fn render(pp: *PrettyPrinter, doc: *const Doc, writer: *std.io.Writer, options: RenderOptions) !void {
    // We start with a buffer containing just the root document.
    // We use a simplified deque approach for the rendering loop.
    var state = RenderState{
        .pp = pp,
        .max_width = options.max_width,
        .current_width = options.indent_lvl * options.indent_str.len,
        .indent_str = options.indent_str,
        .writer = writer,
    };
    defer state.queue.deinit(pp.gpa);

    try state.queue.append(pp.gpa, .{ .indent = options.indent_lvl, .mode = .fill, .doc = doc });

    try state.renderLoop();
}

const Mode = enum { fill, flat, brk };

const RenderJob = struct {
    indent: usize,
    mode: Mode,
    doc: *const Doc,
};

const RenderState = struct {
    pp: *PrettyPrinter,
    max_width: usize,
    current_width: usize,
    indent_str: []const u8,
    writer: *std.io.Writer,
    queue: std.ArrayList(RenderJob) = .empty,

    fn renderLoop(self: *RenderState) !void {
        while (self.queue.pop()) |job| {
            switch (job.doc.*) {
                .fail => try self.writer.writeAll(fail_str),
                .nil => {},
                .text => |s| {
                    try self.writer.writeAll(s);
                    self.current_width += s.len;
                },
                .line => {
                    try self.writer.writeAll("\n");
                    const indent_len = job.indent * self.indent_str.len;
                    for (0..job.indent) |_| try self.writer.writeAll(self.indent_str);
                    self.current_width = indent_len;
                },
                .concat => |docs| {
                    // Push in reverse order
                    var i = docs.len;
                    while (i > 0) {
                        i -= 1;
                        try self.queue.append(self.pp.gpa, .{
                            .indent = job.indent,
                            .mode = job.mode,
                            .doc = docs[i],
                        });
                    }
                },
                .nest => |n| {
                    try self.queue.append(self.pp.gpa, .{
                        .indent = job.indent + n.indent,
                        .mode = job.mode,
                        .doc = n.doc,
                    });
                },
                .breaker => |g| {
                    const fits = self.checkFit(self.max_width -| self.current_width, g) != null;
                    try self.queue.append(self.pp.gpa, .{
                        .indent = job.indent,
                        .mode = if (fits) .flat else .brk,
                        .doc = g,
                    });
                },
                .filler => |f| {
                    try self.queue.append(self.pp.gpa, .{
                        .indent = job.indent,
                        .mode = .fill,
                        .doc = f,
                    });
                },
                .choice => |c| {
                    if (job.mode == .flat) {
                        // Forced flat (inside a fitting group)
                        try self.queue.append(self.pp.gpa, .{ .indent = job.indent, .mode = .flat, .doc = c.flat });
                    } else if (job.mode == .brk) {
                        // Forced break (inside a broken group)
                        try self.queue.append(self.pp.gpa, .{ .indent = job.indent, .mode = .brk, .doc = c.broken });
                    } else {
                        // Mode is .fill (Inconsistent / Flow)
                        // We try to print the flat version (space).
                        // BUT! We only do it if the flat version AND the next item in the queue fit.
                        var fits = false;

                        // 1. Check if the flat choice itself fits
                        if (self.checkFit(self.max_width -| self.current_width, c.flat)) |rem_after_flat| {
                            // 2. Lookahead: Check if the *next* item in the queue fits in the remaining space.
                            if (self.queue.items.len > 0) {
                                const next_doc = self.queue.items[self.queue.items.len - 1].doc;
                                if (self.checkFit(rem_after_flat, next_doc) != null) {
                                    fits = true;
                                }
                            } else {
                                // No next item, so it fits
                                fits = true;
                            }
                        }

                        if (fits) {
                            try self.queue.append(self.pp.gpa, .{ .indent = job.indent, .mode = .fill, .doc = c.flat });
                        } else {
                            try self.queue.append(self.pp.gpa, .{ .indent = job.indent, .mode = .fill, .doc = c.broken });
                        }
                    }
                },
            }
        }
    }

    fn checkFit(self: *RenderState, max_width: usize, doc: *const Doc) ?usize {
        if (max_width == 0) return null;

        return switch (doc.*) {
            .fail => if (fail_str.len <= max_width) max_width - fail_str.len else null,
            .nil => max_width,
            .text => |s| if (s.len <= max_width) max_width - s.len else null,
            .line => null,
            .concat => |docs| {
                var remaining = max_width;
                for (docs) |d| {
                    if (self.checkFit(remaining, d)) |r| {
                        remaining = r;
                    } else {
                        return null;
                    }
                }
                return remaining;
            },
            .nest => |n| self.checkFit(max_width, n.doc),
            inline .breaker, .filler => |g| self.checkFit(max_width, g),
            .choice => |c| self.checkFit(max_width, c.flat),
        };
    }
};
