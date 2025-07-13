//! Common utilities used throughout the Ribbon pipeline
const common = @This();

pub const Buffer = @import("common/Buffer.zig");
pub const Id = @import("common/Id.zig");
pub const Stack = @import("common/Stack.zig");
pub const AllocWriter = @import("common/AllocWriter.zig");
pub const VirtualWriter = @import("common/VirtualWriter.zig");

pub const PeekableIteratorMode = union(enum) {
    error_type: type,
    direct_call: void,

    pub fn use_try(comptime T: type) PeekableIteratorMode {
        return .{
            .error_type = T,
        };
    }
};

/// Any `Iterator` that has a next() method which returns `Element` can be peeked with this iterator.
/// This is useful for iterators that are not peekable themselves or already peekable in another capacity.
pub fn PeekableIterator(comptime Iterator: type, comptime Element: type, comptime mode: PeekableIteratorMode) type {
    return struct {
        const Self = @This();

        inner: Iterator,
        peek_cache: ?Element = null,

        pub const Result: type = if (mode == .error_type) (mode.error_type!?Element) else (?Element);

        pub fn deinit(self: *Self) void {
            if (comptime @hasDecl(Iterator, "deinit")) {
                self.inner.deinit();
            }
        }

        pub fn from(inner: Iterator) (if (mode == .error_type) (mode.error_type!Self) else Self) {
            var self = Self{
                .inner = inner,
                .peek_cache = null,
            };

            _ = if (comptime mode == .error_type) try self.peek() else self.peek();

            return self;
        }

        pub fn isEof(self: *const Self) bool {
            return self.peek_cache == null;
        }

        pub fn peek(self: *Self) Result {
            if (self.peek_cache) |v| {
                return v;
            }

            const it = if (comptime mode == .error_type) try self.inner.next() else self.inner.next();

            self.peek_cache = it;

            return it;
        }

        pub fn next(self: *Self) Result {
            if (self.peek_cache) |v| {
                if (comptime mode == .error_type) try self.advance() else self.advance();

                return v;
            }

            return null;
        }

        pub fn advance(self: *Self) (if (mode == .error_type) (mode.error_type!void) else void) {
            self.peek_cache = null;

            _ = if (comptime mode == .error_type) try self.peek() else self.peek();
        }
    };
}
