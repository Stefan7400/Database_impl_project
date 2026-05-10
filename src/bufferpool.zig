const std = @import("std");
const constants = @import("constants.zig");
const FramePtr = @import("constants.zig").FramePtr;
const api = @import("api.zig");

pub const BufferPool = struct {

    free_list: []bool,
    buffer: []align(api.page_size) u8,

    pub fn init() !@This() {
        const buffer = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(api.page_size), constants.BUFFER_POOL_SIZE_IN_BYTES);
        std.debug.print("Created Buffer-Pool for {d} Page-Frames\n", .{constants.BUFFER_POOL_SIZE_IN_PAGES});

        const free_list = try std.heap.page_allocator.alloc(bool, constants.BUFFER_POOL_SIZE_IN_PAGES);
        @memset(free_list, true);

        return .{
            .buffer = buffer,
            .free_list = free_list,
        };
    }

    pub fn findFreeFramePtr(self: *BufferPool) ?FramePtr {
        for (self.free_list, 0..) |is_free, i| {
            if (is_free) {
                self.free_list[i] = false;
                const start = i * api.page_size;
                const frame_slice = self.buffer[start..][0..api.page_size];
                return @alignCast(frame_slice);
            }
        }
        return null;
    }

    pub fn markFrameAsUsed(self : *BufferPool, frame_ptr: FramePtr) void {
        markFrameAs(self, frame_ptr, false);
    }

    pub fn markFrameAsFree(self : *BufferPool, frame_ptr: FramePtr) void {
        markFrameAs(self, frame_ptr, true);
    }

    fn markFrameAs(self : *BufferPool, frame_ptr: FramePtr, marker : bool) void {
        const byte_offset = @intFromPtr(frame_ptr) - @intFromPtr(self.buffer.ptr);
        const frame_idx = byte_offset / api.page_size;
        self.free_list[frame_idx] = marker;
    }


    pub fn deinit(self : *BufferPool) void {
        std.heap.smp_allocator.free(self.buffer);
        std.heap.page_allocator.free(self.free_list);
    }
};

const testing = std.testing;

test "init: buffer is page-aligned and free_list all true" {
    var pool = try BufferPool.init();
    defer pool.deinit();

    try testing.expectEqual(@as(usize, 0), @intFromPtr(pool.buffer.ptr) % api.page_size);
    try testing.expectEqual(constants.BUFFER_POOL_SIZE_IN_BYTES, pool.buffer.len);
    try testing.expectEqual(constants.BUFFER_POOL_SIZE_IN_PAGES, pool.free_list.len);

    for (pool.free_list) |is_free| try testing.expect(is_free);
}

test "findFreeFramePtr returns first frame and marks it used" {
    var pool = try BufferPool.init();
    defer pool.deinit();

    const frame = pool.findFreeFramePtr() orelse return error.UnexpectedNull;

    // Should be the very first frame in the buffer.
    try testing.expectEqual(@intFromPtr(pool.buffer.ptr), @intFromPtr(frame));
    try testing.expect(!pool.free_list[0]);
    try testing.expect(pool.free_list[1]); // others untouched
}

test "findFreeFramePtr hands out consecutive frames" {
    var pool = try BufferPool.init();
    defer pool.deinit();

    const f0 = pool.findFreeFramePtr().?;
    const f1 = pool.findFreeFramePtr().?;
    const f2 = pool.findFreeFramePtr().?;

    try testing.expectEqual(
        @intFromPtr(pool.buffer.ptr) + 0 * api.page_size,
        @intFromPtr(f0),
    );
    try testing.expectEqual(
        @intFromPtr(pool.buffer.ptr) + 1 * api.page_size,
        @intFromPtr(f1),
    );
    try testing.expectEqual(
        @intFromPtr(pool.buffer.ptr) + 2 * api.page_size,
        @intFromPtr(f2),
    );

    // free_list reflects the claims
    try testing.expect(!pool.free_list[0]);
    try testing.expect(!pool.free_list[1]);
    try testing.expect(!pool.free_list[2]);
    try testing.expect(pool.free_list[3]);
}

test "markFrameAsFree releases the frame and it can be reclaimed" {
    var pool = try BufferPool.init();
    defer pool.deinit();

    const f0 = pool.findFreeFramePtr().?;
    pool.markFrameAsFree(f0);
    try testing.expect(pool.free_list[0]);

    // Next find should return the same address (first free again).
    const f0_again = pool.findFreeFramePtr().?;
    try testing.expectEqual(@intFromPtr(f0), @intFromPtr(f0_again));
}

test "markFrameAs computes the correct index for arbitrary frames" {
    var pool = try BufferPool.init();
    defer pool.deinit();

    // Claim frames 0, 1, 2.
    const f0 = pool.findFreeFramePtr().?;
    const f1 = pool.findFreeFramePtr().?;
    const f2 = pool.findFreeFramePtr().?;

    // Free the middle one.
    pool.markFrameAsFree(f1);
    try testing.expect(!pool.free_list[0]);
    try testing.expect(pool.free_list[1]);
    try testing.expect(!pool.free_list[2]);

    // Reclaiming should hand back f1, not f3.
    const reclaimed = pool.findFreeFramePtr().?;
    try testing.expectEqual(@intFromPtr(f1), @intFromPtr(reclaimed));

    _ = f0;
    _ = f2;
}

test "exhausting the pool returns null" {
    var pool = try BufferPool.init();
    defer pool.deinit();

    var i: usize = 0;
    while (i < constants.BUFFER_POOL_SIZE_IN_PAGES) : (i += 1) {
        _ = pool.findFreeFramePtr() orelse return error.RanOutEarly;
    }
    try testing.expectEqual(@as(?constants.FramePtr, null), pool.findFreeFramePtr());
}

test "writing to a frame doesn't disturb neighbors" {
    var pool = try BufferPool.init();
    defer pool.deinit();

    const f0 = pool.findFreeFramePtr().?;
    const f1 = pool.findFreeFramePtr().?;

    @memset(f0, 0xAA);
    @memset(f1, 0xBB);

    for (f0) |b| try testing.expectEqual(@as(u8, 0xAA), b);
    for (f1) |b| try testing.expectEqual(@as(u8, 0xBB), b);
}