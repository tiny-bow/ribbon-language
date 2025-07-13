//! Byte writer for memory that requires stable addressing.
//!
//! Allocates a page-aligned `USABLE_ADDRESS_SPACE`-byte address space, but does not commit any pages until they are used.
//!
//! Allocates 1 page at a time using sys-calls, and supports finalization to executable or read-only memory.
//!
//! Implements the writer interface.
//!
//! Allows access to the memory while it is being used as a writer. Use with care.
const VirtualWriter = @This();

const common = @import("../common.zig");

const std = @import("std");
const log = std.log.scoped(.@"paged-writer");

test {
    std.testing.refAllDeclsRecursive(@This());
}

/// The initial state of the virtual address space acquired by an `VirtualWriter`.
///
/// In other words, we mark a sequence of addresses `MAX_BLOB_SIZE` in length as something we
/// may be using in the future, so that we can have a stable base pointer as we grow the memory,
/// but we do not actually allocate any memory up front.
pub const NO_PROTECTION = std.posix.PROT.NONE;

/// The state of a page in the virtual address space acquired by an `VirtualWriter`, during and after writing, until finalization.
pub const READ_WRITE = std.posix.PROT.READ | std.posix.PROT.WRITE;

pub const Access = enum(u32) {
    /// The state of a page in the virtual address space acquired by an `VirtualWriter`, after finalization.
    read_execute = std.posix.PROT.READ | std.posix.PROT.EXEC,

    /// The state of a page in the virtual address space acquired by an `VirtualWriter`, after finalization.
    read_only = std.posix.PROT.READ,
};

/// Creates a new `VirtualWriter` type with the given max address space.
pub fn new(comptime USABLE_ADDRESS_SPACE: comptime_int) type {
    return struct {
        const Self = @This();

        /// The memory buffer used by the encoder.
        memory: common.MutVirtualMemory,
        /// The current cursor position in the memory buffer.
        cursor: usize = 0,
        /// The top of the allocated memory region.
        top: usize = 0,

        const MAX_BLOB_SIZE = common.alignTo(common.PAGE_SIZE, USABLE_ADDRESS_SPACE);

        /// Represents an error that can occur during a write to an `VirtualWriter`.
        ///
        /// The only error is `OutOfMemory`,
        /// which is a generalization of several different kinds of syscall errors,
        /// that all have the same end result for the purposes of writing to memory.
        ///
        /// This is provided here for use by the zig std writer api.
        pub const Error = error{
            /// The system ran out of memory, or otherwise did not allow page acquisition.
            OutOfMemory,
        };

        /// Acquire the virtual address space for the writer.
        pub fn init() error{OutOfMemory}!Self {
            const buf = std.posix.mmap(
                null,
                MAX_BLOB_SIZE,
                NO_PROTECTION,
                std.posix.MAP{
                    .TYPE = .PRIVATE,
                    .ANONYMOUS = true,
                },
                -1,
                0,
            ) catch |err| {
                log.err("mmap failed: {s}", .{@errorName(err)});
                return error.OutOfMemory;
            };

            return Self{
                .memory = @alignCast(buf),
            };
        }

        /// De-initializes the writer, freeing any allocated memory it still owns.
        pub fn deinit(self: Self) void {
            if (self.memory.len != 0) std.posix.munmap(self.memory);
        }

        /// Returns the current address of the writer.
        pub fn getCurrentAddress(self: *Self) [*]u8 {
            return self.memory.ptr + self.cursor;
        }

        /// Finalizes the writer, returning the generated code as a byte slice,
        /// and marking the memory with the provided access.
        ///
        /// After calling this function, the writer will be in its default uninitialized state.
        /// In other words, it is safe but not necessary to call `deinit` on it, and it must be re-initialized before use.
        ///
        /// The resulting byte slice needs to be freed with `std.posix.munmap`.
        /// Leaks will not be detected.
        ///
        /// ### Errors
        /// + `BadEncoding` if a zero-length buffer is passed.
        ///
        /// ### Panics
        /// + If the OS does not allow `mprotect` with `access`.
        ///   Under normal circumstances, this should be known to be safe in advance.
        pub fn finalize(self: *Self, access: Access) error{BadEncoding}![]align(common.PAGE_SIZE) const u8 {
            const out = self.memory[0..self.cursor];

            if (out.len == 0) {
                @branchHint(.cold);
                return error.BadEncoding;
            }

            self.cursor += common.alignDelta(self.cursor, common.PAGE_SIZE);

            std.posix.munmap(@alignCast((self.memory.ptr + self.cursor)[0 .. self.memory.len - self.cursor]));

            std.posix.mprotect(out, @intFromEnum(access)) catch |err| {
                std.debug.panic("mprotect rejected `{}`: {s}", .{ @intFromEnum(access), @errorName(err) });
            };

            self.cursor = 0;
            self.top = 0;
            self.memory = &.{};

            return out;
        }

        /// Returns the size of the uncommitted region of memory.
        pub fn uncommittedRegion(self: *Self) usize {
            return self.memory.len - self.top;
        }

        /// Returns the available capacity in the current page.
        pub fn availableCapacity(self: *Self) []u8 {
            return self.memory[self.cursor..self.top];
        }

        fn nextPage(self: *Self) error{OutOfMemory}![]align(common.PAGE_SIZE) u8 {
            std.debug.assert(self.cursor == self.top);

            const committable = self.uncommittedRegion();

            if (committable == 0) return error.OutOfMemory;

            const toCommit = @min(committable, common.PAGE_SIZE);

            std.posix.mprotect(@alignCast((self.memory.ptr + self.top)[0..toCommit]), READ_WRITE) catch {
                return error.OutOfMemory;
            };

            self.top += toCommit;

            return @alignCast(self.memory[self.cursor..self.top]);
        }

        /// Same as `std.mem.Allocator.create`, but allocates from the virtual address space of the writer.
        pub fn create(self: *Self, comptime T: type) Error!*T {
            return &(try self.alloc(T, 1))[0];
        }

        /// Same as `std.mem.Allocator.alloc`, but allocates from the virtual address space of the writer.
        pub fn alloc(self: *Self, comptime T: type, len: usize) Error![]T {
            const byte_len = len * @sizeOf(T);
            const padding = common.alignDelta(self.getCurrentAddress(), @alignOf(T));
            const total_size = byte_len + padding;

            var avail = self.availableCapacity();
            while (avail.len < total_size) avail = try self.nextPage();

            const bytes = avail[padding..total_size];
            self.cursor += bytes.len;

            return @alignCast(@ptrCast(bytes));
        }

        /// Same as `std.mem.Allocator.dupe`, but copies a slice into the virtual address space of the writer.
        pub fn dupe(self: *Self, comptime T: type, slice: []const T) Error![]T {
            const dest = try self.alloc(T, slice.len);
            @memcpy(dest, slice);
            return dest;
        }

        /// Writes as much of a slice of bytes to the writer as will fit without an allocation.
        /// Returns the number of bytes written.
        pub fn write(self: *Self, noalias bytes: []const u8) Error!usize {
            var avail = self.availableCapacity();

            if (avail.len == 0) avail = try self.nextPage();

            const sub = if (bytes.len > avail.len) bytes[0..avail.len] else bytes;

            @memcpy(avail[0..sub.len], sub);

            self.cursor += sub.len;

            return sub.len;
        }

        /// Writes all bytes from a slice to the writer.
        pub fn writeAll(self: *Self, bytes: []const u8) Error!void {
            var index: usize = 0;

            while (index < bytes.len) {
                const written = try self.write(bytes[index..]);
                index += written;
            }
        }

        /// Writes a single byte to the writer.
        pub fn writeByte(self: *Self, byte: u8) Error!void {
            try self.writeAll(&.{byte});
        }

        /// Writes a byte to the writer `n` times.
        pub fn writeByteNTimes(self: *Self, byte: u8, n: usize) Error!void {
            for (0..n) |_| try self.writeByte(byte);
        }

        /// Writes a slice of bytes to the writer `n` times.
        pub fn writeBytesNTimes(self: *Self, bytes: []const u8, n: usize) Error!void {
            for (0..n) |_| try self.writeAll(bytes);
        }

        /// Writes an integer to the writer.
        pub fn writeInt(
            self: *Self,
            comptime T: type,
            value: T,
            comptime _: enum { little }, // allows backward compat with writer code in r64; but only in provably compatible use-cases
        ) Error!void {
            // We do not encode abi padding bytes here; only get the bytes that are actually used.
            const bytes = std.mem.asBytes(&value)[0..common.bytesFromBits(@bitSizeOf(T))];
            try self.writeAll(bytes);
        }
    };
}
