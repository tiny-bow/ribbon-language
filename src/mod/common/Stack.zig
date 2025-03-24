//! A minimal, low-level pre-increment stack data structure in three pointers,
//! performing no error checking.
const Stack = @This();

const std = @import("std");
const log = std.log.scoped(.stack);

test {
    std.testing.refAllDeclsRecursive(@This());
}

/// Creates a new `Stack` type with a specified element type and size.
pub fn new(comptime T: type, comptime STACK_SIZE: comptime_int) type {
    return extern struct {
        const Self = @This();

        /// A pointer to the top of the stack.
        top_ptr: [*]T,
        /// The start of the stack's memory.
        base: [*]T,
        /// Maximum value of top_ptr + 1.
        limit: [*]T,

        /// Used by internal apis to determine if types were constructed with `Stack.new`.
        pub const IS_RIBBON_STACK = true;

        pub const mem = struct {
            /// The total number of bytes required to store the full stack's data
            /// * does not include the stack structure itself (which is 2 words)
            pub const SIZE = @sizeOf(T) * STACK_SIZE;

            /// The alignment required for the stack's data.
            /// * this is the alignment of the element type, not the stack structure itself (which is word-aligned)
            pub const ALIGNMENT = @alignOf(T);
        };

        /// Initializes a stack from a memory pointer.
        pub fn init(memory: [*]align(mem.ALIGNMENT) u8) Self {
            const ptr: [*]T = @ptrCast(memory);
            log.debug("initializing {s} stack at {d} to {d}\n", .{ @typeName(T), @intFromPtr(ptr), @intFromPtr(ptr + STACK_SIZE) });
            return Self {
                .top_ptr = ptr - 1,
                .base = ptr,
                // TODO: are we off by one between here and the assembly code?
                .limit = ptr + STACK_SIZE,
            };
        }

        /// Creates room for `n` values on the top of the stack.
        /// * does not test if the stack has space for the values
        pub fn increment(self: *Self, n: usize) void {
            self.top_ptr += n;
        }

        /// Removes `n` values from the top of the stack.
        /// * does not test if the stack is deep enough
        pub fn decrement(self: *Self, n: usize) void {
            self.top_ptr -= n;
        }

        /// Creates room for a new value on the stack, returning a pointer to the location.
        /// * does not test if the stack has space for the value
        pub fn allocPtr(self: *Self) *T {
            self.increment(1);
            return @ptrCast(self.top_ptr);
        }

        /// Creates room for `n` values on the stack, returning a slice of their location.
        /// * does not test if the stack has space for the values
        pub fn allocSlice(self: *Self, n: usize) []T {
            self.increment(n);
            return self.top_ptr[0..n];
        }

        /// Pushes a value onto the stack.
        /// * does not test if the stack has space for the value
        pub fn push(self: *Self, value: T) void {
            const ptr = self.allocPtr();
            ptr.* = value;
        }

        /// Copies a slice onto the stack.
        /// * does not test if the stack has space for the values
        pub fn pushSlice(self: *Self, src: []const T) void {
            const dst = self.allocSlice(src.len);
            @memcpy(dst, src);
        }

        /// Copies a slice onto the stack and returns the new stack version of it.
        /// * does not test if the stack has space for the values
        pub fn createSlice(self: *Self, src: []const T) []T {
            const newSlice = self.allocSlice(src.len);
            @memcpy(newSlice, src);
            return newSlice;
        }

        /// Pushes a copy of a value onto the stack and returns a pointer to the pushed value.
        /// * does not test if the stack has space for the value
        pub fn create(self: *Self, value: T) *T {
            const ptr = self.allocPtr();
            ptr.* = value;
            return ptr;
        }

        /// Pops a value from the stack and returns a pointer to it.
        /// * does not test if the stack is empty
        /// * the pointer returned is a view into the stack's memory,
        /// therefore it is only valid until the next vm operation
        pub fn popMultiPtr(self: *Self, n: usize) [*]T {
            const ptr = (self.top_ptr - n + 1);
            self.top_ptr -= n;
            return ptr;
        }

        /// Pops `n` values from the stack and returns a slice of the popped values.
        /// * does not test if the stack is deep enough
        /// * slice is a view into the stack's memory,
        /// therefore it is only valid until the next vm operation;
        /// * resulting slice will be in first-in order
        /// * See `popInto` for copying, last-in version.
        pub fn popSlice(self: *Self, n: usize) []T {
            const multi = self.popMultiPtr(n);
            return multi[0..n];
        }

        /// Pops `out.len` values from the stack and copies them into `out`.
        /// * does not test if the stack is deep enough
        /// * resulting slice will be in last-in order
        /// * See `popSlice` for non-copying, first-in version.
        pub fn popInto(self: *Self, out: []T) void {
            const slice = self.popSlice(out.len);
            for (out, 0..) |*value, i| {
                value.* = slice[slice.len - i - 1];
            }
        }

        /// Pops a value from the stack and returns a pointer to it.
        /// * does not test if the stack is empty
        /// * the pointer returned is a view into the stack's memory,
        /// therefore it is only valid until the next vm operation
        pub fn popPtr(self: *Self) *T {
            const ptr = self.top();
            self.top_ptr -= 1;
            return ptr;
        }

        /// Pops a value from the stack and returns it by value.
        /// * does not test if the stack is empty
        pub fn popValue(self: *Self) T {
            return self.popPtr().*;
        }

        /// Pops a value from the stack.
        /// * does not test if the stack is empty
        pub fn pop(self: *Self) void {
            self.top_ptr -= 1;
        }

        /// Returns a pointer to the value on the top of the stack.
        /// * does not test if the stack is empty
        pub fn top(self: *Self) *T {
            return @ptrCast(self.top_ptr);
        }

        /// Checks if the stack has space for a specified number of elements.
        pub fn hasSpace(self: *Self, additionalCount: usize) bool {
            return @intFromPtr(self.top_ptr + additionalCount) < @intFromPtr(self.limit);
        }

        /// Checks if the stack has no values
        pub fn isEmpty(self: *Self) bool {
            return @intFromPtr(self.top_ptr) < @intFromPtr(self.base);
        }

        /// Returns the number of values on the stack
        pub fn count(self: *Self) usize {
            const a = @intFromPtr(self.base);
            const b = @intFromPtr(self.top_ptr);
            return if (b < a) 0
            else b - a + 1;
        }
    };
}
