//! # Formatter
//! This module is a data type providing a flexible and extensible way to format and output text.
//!
//! * **Indentation Management** - automatically handles indentation using levels and styles
//! * **Block Formatting** - supports different block styles for indented code; like array-style, struct-style, etc
//! * **Customizable Number Formats** - numbers can be printed in different formats, settings are persistent
//! * **State Management** - maintains internal state for arbitrary flags, user data pointers, and styles
//! * **Writer Agnostic** - can be used with any writer that converts to `std.io.AnyWriter`, a vtable type
//!
//! ## Key Components
//! * `Formatter` - the main structure representing the formatter
//! * `State` - maintains the internal state of the formatter
//! * `BlockStyle` - describes how to format a block of text
//! * `NumberStyle` - represents the style of a number
//! * `Base` - represents the base of a number
//!
//! ## Usage
//! 1. Initialize a `Formatter` instance using `Formatter.init`.
//! 2. Use the `Formatter` instance to format and write text.
//! 3. De-initialize the formatter to free any allocated memory.
const Formatter = @This();

const std = @import("std");
const log = std.log.scoped(.fmt);

const pl = @import("platform");

test {
    std.testing.refAllDeclsRecursive(@This());
}

/// The internal state of the formatter.
state: *State,

/// Initializes a new Formatter instance.
///
/// Allocates memory for the internal state of the formatter using the provided allocator
/// and associates it with the given writer.
pub fn init(allocator: std.mem.Allocator, writer: std.io.AnyWriter) error{OutOfMemory}!Formatter {
    const state = try allocator.create(State);

    state.* = .{
        .allocator = allocator,
        .writer = writer,
    };

    return Formatter{ .state = state };
}

/// Deinitializes the Formatter instance, freeing all allocated memory.
pub fn deinit(self: Formatter) void {
    const allocator = self.state.allocator;
    defer allocator.destroy(self.state);

    self.state.block_style.deinit(allocator);
    self.state.flags.deinit(allocator);
    self.state.user_data.deinit(allocator);
}

/// The internal state of Formatter.
pub const State = struct {
    /// The allocator used for memory management.
    allocator: std.mem.Allocator,
    /// The writer used for output.
    writer: std.io.AnyWriter,
    /// The current indentation depth.
    depth: usize = 0,
    /// The maximum indentation depth.
    max_depth: usize = 8,
    /// The string used for indentation.
    indent_str: []const u8 = "    ",
    /// Stack of block information.
    block_style: pl.ArrayList(BlockStyle) = .{},
    /// Map of flags.
    flags: pl.StringMap(bool) = .{},
    /// Map of user data.
    user_data: pl.StringMap(*anyopaque) = .{},
    /// Whether the last write ended a line.
    line_ended: bool = false,
    /// Style for integers.
    int_style: NumberStyle = .{},
    /// Style for floats.
    float_style: NumberStyle = .{},
};

// TODO: this doesn't actually need to be AnyError
/// An error that can occur during formatting.
///
/// This is just `anyerror`, but the declaration is necessary for zig std's format function.
pub const Error = anyerror;

/// Describes how to format a block of text.
pub const BlockStyle = struct {
    /// The opening tag for the block.
    opening_tag: ?[]const u8 = null,
    /// The closing tag for the block.
    closing_tag: ?[]const u8 = null,
    /// The line ending for the block.
    line_ending: ?[]const u8 = null,

    /// Prepends a prefix to the opening tag of a block, returning a new block
    /// (at compile time, because it uses comptime string concatenation).
    pub fn prependOpeningTag(comptime self: BlockStyle, comptime pfx: []const u8) BlockStyle {
        comptime return BlockStyle{
            .opening_tag = if (self.opening_tag) |tag| pfx ++ tag else pfx,
            .closing_tag = self.closing_tag,
            .line_ending = self.line_ending,
        };
    }

    /// Replaces the opening tag of a block, returning a new block
    pub fn withOpeningTag(self: BlockStyle, newOpeningTag: ?[]const u8) BlockStyle {
        return BlockStyle{
            .opening_tag = newOpeningTag,
            .closing_tag = self.closing_tag,
            .line_ending = self.line_ending,
        };
    }

    /// Replaces the closing tag of a block, returning a new block
    pub fn withClosingTag(self: BlockStyle, newClosingTag: ?[]const u8) BlockStyle {
        return BlockStyle{
            .opening_tag = self.opening_tag,
            .closing_tag = newClosingTag,
            .line_ending = self.line_ending,
        };
    }

    /// Replaces the line ending of a block, returning a new block
    pub fn withLineEnding(self: BlockStyle, newLineEnding: ?[]const u8) BlockStyle {
        return BlockStyle{
            .opening_tag = self.opening_tag,
            .closing_tag = self.closing_tag,
            .line_ending = newLineEnding,
        };
    }

    /// A block with no decoration other than indentation.
    pub const Indent = BlockStyle{};

    /// An array-constructor-like object block.
    ///
    /// Surrounds the block in square brackets, and ends lines with comma.
    pub const Array = BlockStyle{
        .opening_tag = "[",
        .closing_tag = "]",
        .line_ending = ",",
    };

    /// A vector-constructor-like object block.
    ///
    /// Surrounds the block in angle brackets, and ends lines with a comma.
    pub const Vector = BlockStyle{
        .opening_tag = "<",
        .closing_tag = ">",
        .line_ending = ",",
    };

    /// A program-statements-like object block.
    ///
    /// Surrounds the block in curly braces, and ends lines with a semicolon.
    pub const Statements = BlockStyle{
        .opening_tag = "{",
        .closing_tag = "}",
        .line_ending = ";",
    };

    /// A struct-like object block.
    ///
    /// Surrounds the block in curly braces, and ends lines with a comma.
    pub const Structure = Statements.withLineEnding(",");
};

/// Represents the base of a number.
pub const Base = union(enum) {
    /// Binary base.
    binary: void,
    /// Decimal base.
    decimal: void,
    /// Hexadecimal base.
    hexadecimal: struct { case: std.fmt.Case = .lower },
    /// Character base.
    character: void,
};

/// Represents the style of a number.
pub const NumberStyle = struct {
    /// The base of the number.
    base: Base = .decimal,
    /// The format options.
    options: std.fmt.FormatOptions = .{},
};

/// Returns a `std.io.AnyWriter` that can be used to write to the formatter.
pub fn any(self: Formatter) std.io.AnyWriter {
    comptime std.debug.assert(@sizeOf(Formatter) == @sizeOf(*const anyopaque));
    comptime std.debug.assert(@alignOf(Formatter) == @alignOf(*const anyopaque));

    return .{
        .context = self.state,
        .writeFn = @as(*const fn (context: *const anyopaque, bytes: []const u8) anyerror!usize, @ptrCast(&Formatter.write)),
    };
}

/// Bind a flag to a key in the formatter's state.
/// This allows on-the-fly boolean configuration of the formatter.
///
/// See `getFlag`, `swapFlag`.
pub fn setFlag(self: Formatter, flag: pl.EnumLiteral, value: bool) error{OutOfMemory}!void {
    return self.state.flags.put(self.state.allocator, @tagName(flag), value);
}

/// Gets a flag from the formatter's state.
///
/// See `setFlag`, `swapFlag`.
pub fn getFlag(self: Formatter, flag: pl.EnumLiteral) bool {
    return self.state.flags.get(@tagName(flag)) orelse false;
}

/// Swaps a flag in the formatter's state with a new value, returning the old value.
///
/// See `setFlag`, `getFlag`.
pub fn swapFlag(self: Formatter, flag: pl.EnumLiteral, newValue: bool) error{OutOfMemory}!bool {
    const getOrPut = try self.state.flags.getOrPut(self.state.allocator, @tagName(flag));
    const oldValue = if (getOrPut.found_existing) getOrPut.value_ptr.* orelse false;
    getOrPut.value_ptr.* = newValue;
    return oldValue;
}

/// Bind a pointer to arbitrary userdata to a key in the formatter's state.
/// This allows on-the-fly state sharing in the formatter.
///
/// See `getUserData`, `swapUserData`.
pub fn setUserData(self: Formatter, key: pl.EnumLiteral, value: *anyopaque) error{OutOfMemory}!void {
    return self.state.user_data.put(self.state.allocator, @tagName(key), value);
}

/// Gets userdata from the formatter's state.
///
/// See `setUserData`, `swapUserData`.
pub fn getUserData(self: Formatter, key: pl.EnumLiteral) error{TypeMismatch}!?*anyopaque {
    return self.state.user_data.get(@tagName(key));
}

/// Swaps userdata in the formatter's state with a new value, returning the old value.
pub fn swapUserData(self: Formatter, key: pl.EnumLiteral, newValue: anytype) error{OutOfMemory}!?@TypeOf(newValue) {
    const getOrPut = try self.state.user_data.getOrPut(self.state.allocator, @tagName(key));
    if (getOrPut.found_existing) {
        const oldValue = getOrPut.value_ptr;
        oldValue.type_id = comptime pl.TypeId.of(@TypeOf(newValue).pointer.child);
        oldValue.pointer = @ptrCast(newValue);
        return @ptrCast(@alignCast(oldValue.pointer));
    } else {
        getOrPut.value_ptr = @ptrCast(newValue);
        return null;
    }
}

/// Writes a slice of bytes to the formatter.
pub fn write(self: Formatter, bytes: []const u8) anyerror!usize {
    for (bytes) |byte| {
        try self.writeByte(byte);
    }

    return bytes.len;
}

/// Writes all bytes from a slice to the formatter.
///
/// This function repeatedly calls `write` until all bytes have been written.
pub fn writeAll(self: Formatter, bytes: []const u8) anyerror!void {
    var index: usize = 0;
    while (index != bytes.len) {
        index += try self.write(bytes[index..]);
    }
}

/// Writes a single byte to the formatter.
pub fn writeByte(self: Formatter, byte: u8) anyerror!void {
    if (self.state.line_ended) {
        if (byte != '\n') {
            try self.state.writer.writeBytesNTimes(self.state.indent_str, self.state.block_style.items.len);
        }

        self.state.line_ended = false;
    }

    try self.state.writer.writeByte(byte);

    if (byte == '\n') {
        self.state.line_ended = true;
    }
}

/// Writes a byte to the formatter `n` times.
pub fn writeByteNTimes(self: Formatter, byte: u8, n: usize) anyerror!void {
    for (0..n) |_| try self.writeByte(byte);
}

/// Writes a slice of bytes to the formatter `n` times.
pub fn writeBytesNTimes(self: Formatter, bytes: []const u8, n: usize) anyerror!void {
    for (0..n) |_| try self.writeAll(bytes);
}

/// Prints a formatted string to the formatter, followed by a newline.
pub fn printLn(self: Formatter, comptime fmtStr: []const u8, args: anytype) anyerror!void {
    try self.print(fmtStr ++ "\n", args);
    try self.endLine(false);
}

/// Prints a formatted string to the formatter.
pub fn print(self: Formatter, comptime fmtStr: []const u8, args: anytype) anyerror!void {
    _ = pl.typeInfo(@TypeOf(args), .@"struct");

    comptime var i = 0;
    comptime var a = 0;

    inline while (i < fmtStr.len) {
        const ch = comptime fmtStr[i];
        const nextCh = comptime if (i < fmtStr.len - 1) fmtStr[i + 1] else 0;

        if (comptime ch == '{') {
            i += 1;

            if (comptime nextCh == '{') {
                i += 1;

                try self.writeByte('{');
            } else if (comptime nextCh == '}') {
                i += 1;

                if (comptime a == args.len) {
                    @compileError("Not enough arguments for format string \"" ++ fmtStr ++ "\"");
                }

                try self.fmt(args[a]);

                a += 1;
            } else {
                const fmtSub = comptime fmtSub: {
                    var j = i;

                    const k: ?comptime_int = while (j < fmtStr.len) : (j += 1) {
                        if (fmtStr[j] == '}') {
                            break j;
                        }
                    } else null;

                    if (k) |endIndex| {
                        const startIndex = i;
                        i = endIndex + 1;
                        const str = fmtStr[startIndex..endIndex];
                        break :fmtSub str;
                    } else {
                        @compileError("Expected '}' after '{', indicating an argument, or an additional '{' to escape the brace");
                    }
                };

                const placeholder = comptime std.fmt.Placeholder.parse(fmtSub.*);

                const specifier = placeholder.specifier_arg[0];

                if (comptime std.mem.indexOfScalar(u8, "ubcdxX", specifier) != null) {
                    const extractSpecifier = struct {
                        pub fn fun(out: anytype, in: std.fmt.Specifier) void {
                            const T: type = pl.typeInfo(@TypeOf(out), .pointer).child;

                            switch (in) {
                                .number => |n| {
                                    out.* = @as(T, @intCast(n));
                                },

                                else => {},
                            }
                        }
                    }.fun;

                    const intStyle = self.state.int_style;
                    defer self.state.int_style = intStyle;

                    const floatStyle = self.state.float_style;
                    defer self.state.float_style = floatStyle;

                    self.state.int_style.base = comptime switch (specifier) {
                        'b' => .binary,
                        'u' => .character,
                        'c' => .character,
                        'd' => .decimal,
                        'x' => .{ .hexadecimal = .{ .case = .lower } },
                        'X' => .{ .hexadecimal = .{ .case = .upper } },
                        else => unreachable,
                    };

                    self.state.float_style.base = self.state.int_style.base;

                    extractSpecifier(&self.state.int_style.options.precision, placeholder.precision);
                    extractSpecifier(&self.state.int_style.options.width, placeholder.width);
                    self.state.int_style.options.alignment = placeholder.alignment;
                    self.state.int_style.options.fill = placeholder.fill;

                    extractSpecifier(&self.state.float_style.options.precision, placeholder.precision);
                    extractSpecifier(&self.state.float_style.options.width, placeholder.width);
                    self.state.float_style.options.alignment = placeholder.alignment;
                    self.state.float_style.options.fill = placeholder.fill;

                    try self.fmt(args[a]);
                } else {
                    if (!std.mem.eql(u8, fmtSub, "s")) { // don't warn for s
                        log.warn("format specifier {s} is ignored here", .{fmtSub});
                    }
                    try self.fmt(args[a]);
                }

                a += 1;
            }
        } else if (comptime ch == '}') {
            i += 1;

            if (comptime nextCh == '}') {
                i += 1;

                try self.writeByte('}');
            } else {
                @compileError("Expected '{' before '}', indicating an argument, or an additional '}' to escape the brace");
            }
        } else {
            i += 1;
            try self.writeByte(ch);
        }
    }

    if (comptime a != args.len) {
        @compileError("Too many arguments for format string");
    }
}

/// Ends a line in the formatter.
///
/// If `separator` is true, a line ending will be written if the current block has a line ending defined.
/// If the formatter is not already at the end of a line, a newline character will be written.
pub fn endLine(self: Formatter, separator: bool) anyerror!void {
    if (separator) {
        if (self.state.block_style.items.len > 0) {
            const blockStyle = self.state.block_style.items[self.state.block_style.items.len - 1];

            if (blockStyle.line_ending) |lineEnding| {
                try self.writeAll(lineEnding);
            }
        }
    }

    if (!self.state.line_ended) {
        try self.writeByte('\n');
    }
}

/// Begins a block in the formatter.
///
/// If the block has an opening tag, it will be written to the writer.
/// A new line will be started, and the block will be added to the stack of blocks.
pub fn beginBlock(self: Formatter, blockStyle: BlockStyle) anyerror!void {
    if (blockStyle.opening_tag) |tag| {
        std.debug.assert(std.mem.indexOfScalar(u8, tag, '\n') == null);

        try self.state.writer.writeAll(tag);
    }

    try self.endLine(false);

    try self.state.block_style.append(self.state.allocator, blockStyle);
}

/// Ends a block in the formatter.
///
/// A new line will be started, and if the block has a closing tag, it will be written to the writer.
/// The block will be removed from the stack of blocks.
pub fn endBlock(self: Formatter) anyerror!void {
    const blockStyle = self.state.block_style.pop() orelse return error.FormatterBlockStackUnderflow;

    try self.endLine(false);

    if (blockStyle.closing_tag) |tag| {
        std.debug.assert(std.mem.indexOfScalar(u8, tag, '\n') == null);

        try self.state.writer.writeAll(tag);
    }
}

/// Formats a value using the formatter.
///
/// If the value has an `onFormat` method, this is equivalent to calling `value.onFormat(formatter)`.
///
/// Otherwise, the value will be formatted using `std.fmt.format`, and:
/// + if the value has a `format` method, this is equivalent to calling `value.format("any", .{}, formatter)`;
/// + otherwise, zig will use type reflection to print the value as best it can.
pub fn fmt(self: Formatter, value: anytype) anyerror!void {
    // TODO: we should pass in the format options we have

    const T = @TypeOf(value);

    self.state.depth += 1;
    defer self.state.depth -= 1;

    if (comptime pl.hasDerefDecl(T, .onFormat)) {
        try value.onFormat(self);
    } else {
        try std.fmt.format(self, "{any}", .{value});
    }
}

// From zig's std.fmt, modified to support case selection
fn formatFloatHexadecimal(
    value: anytype,
    case: std.fmt.Case,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    // The MIT License (Expat)
    //
    // Copyright (c) Zig contributors
    //
    // Permission is hereby granted, free of charge, to any person obtaining a copy
    // of this software and associated documentation files (the "Software"), to deal
    // in the Software without restriction, including without limitation the rights
    // to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    // copies of the Software, and to permit persons to whom the Software is
    // furnished to do so, subject to the following conditions:
    //
    // The above copyright notice and this permission notice shall be included in
    // all copies or substantial portions of the Software.
    if (std.math.signbit(value)) {
        try writer.writeByte('-');
    }
    if (std.math.isNan(value)) {
        return writer.writeAll("nan");
    }
    if (std.math.isInf(value)) {
        return writer.writeAll("inf");
    }

    const T = @TypeOf(value);
    const TU = std.meta.Int(.unsigned, @bitSizeOf(T));

    const mantissa_bits = std.math.floatMantissaBits(T);
    const fractional_bits = std.math.floatFractionalBits(T);
    const exponent_bits = std.math.floatExponentBits(T);
    const mantissa_mask = (1 << mantissa_bits) - 1;
    const exponent_mask = (1 << exponent_bits) - 1;
    const exponent_bias = (1 << (exponent_bits - 1)) - 1;

    const as_bits = @as(TU, @bitCast(value));
    var mantissa = as_bits & mantissa_mask;
    var exponent: i32 = @as(u16, @truncate((as_bits >> mantissa_bits) & exponent_mask));

    const is_denormal = exponent == 0 and mantissa != 0;
    const is_zero = exponent == 0 and mantissa == 0;

    if (is_zero) {
        // Handle this case here to simplify the logic below.
        try writer.writeAll("0x0");
        if (options.precision) |precision| {
            if (precision > 0) {
                try writer.writeAll(".");
                try writer.writeByteNTimes('0', precision);
            }
        } else {
            try writer.writeAll(".0");
        }
        try writer.writeAll("p0");
        return;
    }

    if (is_denormal) {
        // Adjust the exponent for printing.
        exponent += 1;
    } else {
        if (fractional_bits == mantissa_bits)
            mantissa |= 1 << fractional_bits; // Add the implicit integer bit.
    }

    const mantissa_digits = (fractional_bits + 3) / 4;
    // Fill in zeroes to round the fraction width to a multiple of 4.
    mantissa <<= mantissa_digits * 4 - fractional_bits;

    if (options.precision) |precision| {
        // Round if needed.
        if (precision < mantissa_digits) {
            // We always have at least 4 extra bits.
            var extra_bits = (mantissa_digits - precision) * 4;
            // The result LSB is the Guard bit, we need two more (Round and
            // Sticky) to round the value.
            while (extra_bits > 2) {
                mantissa = (mantissa >> 1) | (mantissa & 1);
                extra_bits -= 1;
            }
            // Round to nearest, tie to even.
            mantissa |= @intFromBool(mantissa & 0b100 != 0);
            mantissa += 1;
            // Drop the excess bits.
            mantissa >>= 2;
            // Restore the alignment.
            mantissa <<= @as(std.math.Log2Int(TU), @intCast((mantissa_digits - precision) * 4));

            const overflow = mantissa & (1 << 1 + mantissa_digits * 4) != 0;
            // Prefer a normalized result in case of overflow.
            if (overflow) {
                mantissa >>= 1;
                exponent += 1;
            }
        }
    }

    // +1 for the decimal part.
    var buf: [1 + mantissa_digits]u8 = undefined;
    _ = std.fmt.formatIntBuf(&buf, mantissa, 16, case, .{ .fill = '0', .width = 1 + mantissa_digits });

    try writer.writeAll("0x");
    try writer.writeByte(buf[0]);
    const trimmed = std.mem.trimRight(u8, buf[1..], "0");
    if (options.precision) |precision| {
        if (precision > 0) try writer.writeAll(".");
    } else if (trimmed.len > 0) {
        try writer.writeAll(".");
    }
    try writer.writeAll(trimmed);
    // Add trailing zeros if explicitly requested.
    if (options.precision) |precision| if (precision > 0) {
        if (precision > trimmed.len)
            try writer.writeByteNTimes('0', precision - trimmed.len);
    };
    try writer.writeAll("p");
    try std.fmt.formatInt(exponent - exponent_bias, 10, case, .{}, writer);
}
