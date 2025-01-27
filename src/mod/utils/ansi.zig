const utils = @import("../utils.zig");

const ansi = @This();

const std = @import("std");

pub const Scl = struct {
    pub const Bell: u8 = 0x07;
    pub const Backspace: u8 = 0x08;
    pub const Tab: u8 = 0x09;
    pub const LineFeed: u8 = 0x0A;
    pub const VerticalTab: u8 = 0x0B;
    pub const FormFeed: u8 = 0x0C;
    pub const CarriageReturn: u8 = 0x0D;
    pub const Esc: u8 = 0x1B;
    pub const EscEnd: u8 = 'm';
    pub const Delete: u8 = 0x7F;
};

pub const Seq = struct {
    pub const Bell = "\x07";
    pub const Backspace = "\x08";
    pub const Tab = "\x09";
    pub const LineFeed = "\x0A";
    pub const VerticalTab = "\x0B";
    pub const FormFeed = "\x0C";
    pub const CarriageReturn = "\x0D";
    pub const Esc = "\x1B";
    pub const EscEnd = "m";
    pub const Delete = "\x7F";
};

pub const Cursor = struct {
    pub const DataStart = "\x1b[";
    pub const MoveHome = "\x1b[H";
    pub const Hide = "\x1b[?25l";
    pub const Show = "\x1b[?25h";
    pub const Ct = struct {
        pub fn MoveTo(comptime line: usize, comptime column: usize) *const [std.fmt.count("\x1b[{};{}H", .{ line, column }):0]u8 {
            return std.fmt.comptimePrint("\x1b[{};{}H", .{ line, column });
        }
        pub fn MoveUp(comptime count: usize) *const [std.fmt.count("\x1b[{}A", .{count}):0]u8 {
            return std.fmt.comptimePrint("\x1b[{}A", .{count});
        }
        pub fn MoveDown(comptime count: usize) *const [std.fmt.count("\x1b[{}B", .{count}):0]u8 {
            return std.fmt.comptimePrint("\x1b[{}B", .{count});
        }
        pub fn MoveRight(comptime count: usize) *const [std.fmt.count("\x1b[{}C", .{count}):0]u8 {
            return std.fmt.comptimePrint("\x1b[{}C", .{count});
        }
        pub fn MoveLeft(comptime count: usize) *const [std.fmt.count("\x1b[{}D", .{count}):0]u8 {
            return std.fmt.comptimePrint("\x1b[{}D", .{count});
        }
        pub fn MoveDownToLineStart(comptime count: usize) *const [std.fmt.count("\x1b[{}E", .{count}):0]u8 {
            return std.fmt.comptimePrint("\x1b[{}E", .{count});
        }
        pub fn MoveUpToLineStart(comptime count: usize) *const [std.fmt.count("\x1b[{}F", .{count}):0]u8 {
            return std.fmt.comptimePrint("\x1b[{}F", .{count});
        }
        pub fn MoveToColumn(comptime column: usize) *const [std.fmt.count("\x1b[{}G", .{column}):0]u8 {
            return std.fmt.comptimePrint("\x1b[{}G", .{column});
        }
    };
    pub const W = struct {
        pub fn MoveTo(writer: anytype, line: usize, column: usize) !void {
            try writer.print("\x1b[{};{}H", .{ line, column });
        }
        pub fn MoveUp(writer: anytype, count: usize) !void {
            try writer.print("\x1b[{}A", .{count});
        }
        pub fn MoveDown(writer: anytype, count: usize) !void {
            try writer.print("\x1b[{}B", .{count});
        }
        pub fn MoveRight(writer: anytype, count: usize) !void {
            try writer.print("\x1b[{}C", .{count});
        }
        pub fn MoveLeft(writer: anytype, count: usize) !void {
            try writer.print("\x1b[{}D", .{count});
        }
        pub fn MoveDownToLineStart(writer: anytype, count: usize) !void {
            try writer.print("\x1b[{}E", .{count});
        }
        pub fn MoveUpToLineStart(writer: anytype, count: usize) !void {
            try writer.print("\x1b[{}F", .{count});
        }
        pub fn MoveToColumn(writer: anytype, column: usize) !void {
            try writer.print("\x1b[{}G", .{column});
        }
    };
    pub const IO = struct {
        pub fn RequestPosition(writer: anytype, reader: anytype) !Answer {
            try writer.writeAll(Cursor.RequestPosition);
            return try readAnswer(reader);
        }

        pub fn GetColumns(writer: anytype, reader: anytype) !usize {
            const previous = try Cursor.IO.RequestPosition(writer, reader);
            try W.MoveRight(writer, 999);

            const answer = try Cursor.IO.RequestPosition(writer, reader);

            try W.MoveToColumn(writer, previous.x);

            return answer.x;
        }
    };
    /// (reports as `ESC[#;#R`)
    pub const RequestPosition = "\x1b[6n";
    pub const MoveUp1 = "\x1b M";
    pub const SaveCursorPositionDEC = "\x1b 7";
    pub const RestoreCursorPositionDEC = "\x1b 8";
    pub const SaveCursorPositionSCO = "\x1b[s";
    pub const RestoreCursorPositionSCO = "\x1b[u";
    pub const Answer = struct { x: usize, y: usize };
    pub fn readAnswer(reader: anytype) !Answer {
        var buf = [1]u8{0} ** 32;
        const answer = (try reader.readUntilDelimiterOrEof(&buf, 'R')) orelse return error.CursorPos;
        return try parseAnswer(answer);
    }
    pub fn parseAnswer(answer: []const u8) !Answer {
        if (!std.mem.startsWith(u8, DataStart, answer)) {
            return error.CursorPos;
        }
        var iter = std.mem.splitSequence(u8, answer[2..], ";");
        const y = iter.next() orelse return error.CursorPos;
        const x = iter.next() orelse return error.CursorPos;
        return .{ .x = try std.fmt.parseInt(usize, x, 10), .y = try std.fmt.parseInt(usize, y, 10) };
    }
};

/// Note: erasing entire line doesn't reset cursor, append `\r` in these cases
pub const Erase = struct {
    pub const CursorToEndOfScreen = "\x1b[0J";
    pub const CursorToBeginningOfScreen = "\x1b[1J";
    pub const EntireScreen = "\x1b[2J";
    pub const SavedLines = "\x1b[3J";
    pub const CursorToEndOfLine = "\x1b[0K";
    pub const CursorToBeginningOfLine = "\x1b[1K";
    pub const EntireLine = "\x1b[2K";
};

pub const Style: StyleT = .{
    .Reset = "\x1b[0m",
    .Decoration = .{
        .StartBold = "\x1b[1m",
        .StartDim = "\x1b[2m",
        .EndBoldDim = "\x1b[22m",
        .StartItalic = "\x1b[3m",
        .EndItalic = "\x1b[23m",
        .StartUnderline = "\x1b[4m",
        .EndUnderline = "\x1b[24m",
        .StartBlink = "\x1b[5m",
        .EndBlink = "\x1b[25m",
        .StartInvert = "\x1b[7m",
        .EndInvert = "\x1b[27m",
        .StartHidden = "\x1b[8m",
        .EndHidden = "\x1b[28m",
        .StartStrike = "\x1b[9m",
        .EndStrike = "\x1b[29m",
    },
    .Color = .{ .Foreground = .{
        .Black = "\x1b[30m",
        .Red = "\x1b[31m",
        .Green = "\x1b[32m",
        .Yellow = "\x1b[33m",
        .Blue = "\x1b[34m",
        .Magenta = "\x1b[35m",
        .Cyan = "\x1b[36m",
        .White = "\x1b[37m",
        .Default = "\x1b[39m",
    }, .Background = .{
        .Black = "\x1b[40m",
        .Red = "\x1b[41m",
        .Green = "\x1b[42m",
        .Yellow = "\x1b[43m",
        .Blue = "\x1b[44m",
        .Magenta = "\x1b[45m",
        .Cyan = "\x1b[46m",
        .White = "\x1b[47m",
        .Default = "\x1b[49m",
    } },
};

pub const NoStyle: StyleT = .{
    .Reset = "",
    .Decoration = .{
        .StartBold = "",
        .StartDim = "",
        .EndBoldDim = "",
        .StartItalic = "",
        .EndItalic = "",
        .StartUnderline = "",
        .EndUnderline = "",
        .StartBlink = "",
        .EndBlink = "",
        .StartInvert = "",
        .EndInvert = "",
        .StartHidden = "",
        .EndHidden = "",
        .StartStrike = "",
        .EndStrike = "",
    },
    .Color = .{ .Foreground = .{
        .Black = "",
        .Red = "",
        .Green = "",
        .Yellow = "",
        .Blue = "",
        .Magenta = "",
        .Cyan = "",
        .White = "",
        .Default = "",
    }, .Background = .{
        .Black = "",
        .Red = "",
        .Green = "",
        .Yellow = "",
        .Blue = "",
        .Magenta = "",
        .Cyan = "",
        .White = "",
        .Default = "",
    } },
};

pub const StyleT = struct { Reset: []const u8, Decoration: struct {
    StartBold: []const u8,
    StartDim: []const u8,
    EndBoldDim: []const u8,
    StartItalic: []const u8,
    EndItalic: []const u8,
    StartUnderline: []const u8,
    EndUnderline: []const u8,
    StartBlink: []const u8,
    EndBlink: []const u8,
    StartInvert: []const u8,
    EndInvert: []const u8,
    StartHidden: []const u8,
    EndHidden: []const u8,
    StartStrike: []const u8,
    EndStrike: []const u8,
}, Color: struct {
    Foreground: SetT,
    Background: SetT,
    const SetT = struct {
        Black: []const u8,
        Red: []const u8,
        Green: []const u8,
        Yellow: []const u8,
        Blue: []const u8,
        Magenta: []const u8,
        Cyan: []const u8,
        White: []const u8,
        Default: []const u8,
    };
} };

test {
    std.testing.refAllDeclsRecursive(@This());
}
