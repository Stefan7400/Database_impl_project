const std = @import("std");
const PageDirectory = @import("pagedirectory.zig").PageDirectory;
const PageTable = @import("pagetable.zig").PageTable;
const PageTableEntry = @import("pagetable.zig").PageTableEntry;
const BufferPool = @import("bufferpool.zig").BufferPool;
const api = @import("api.zig");
const Page = @import("api.zig").Page;
const file_util = @import("fileutil.zig");


//TODO sync maybe via reader/writer lock in the pagetable entry???

pub const BufferManager = struct {

    io: std.Io,
    file: std.Io.File,

    page_directory : PageDirectory,
    page_table : PageTable,
    buffer_pool: BufferPool,

    // for now pfn = page_number
    pfn_counter: std.atomic.Value(u64),


    pub fn init(io : std.Io) !@This() {
        const page_directory = PageDirectory.init(io);
        const page_table: PageTable = try PageTable.init();
        const buffer_pool: BufferPool = try BufferPool.init();

        return .{
              .io = io,
              .page_directory = page_directory,
              .page_table = page_table,
              .buffer_pool = buffer_pool,
              .pfn_counter = std.atomic.Value(u64).init(0),
              .file = try createStorageFile(io,"storage.db"),
        };
    }

    fn createStorageFile(std_io: std.Io, file_name: []const u8) !std.Io.File{
        return try std.Io.Dir.cwd().createFile(std_io, file_name, .{ .read = true, .truncate = true });
    }

    pub fn AllocPageFrame(self: *BufferManager) !struct { pfn: u64, page: *Page} {
        const current_pfn = self.pfn_counter.fetchAdd(1, .monotonic);

        // find suited place in the bufferpool

        if(self.page_table.isBufferPoolFull()) {
            //if this is the case we need to evict
            const evict_result = self.page_table.findEvictableFrame();

            if(evict_result.evicted_is_dirty){
                //flush the frame which should be evicted
                try FlushPage(self, evict_result.evicted_pfn);
            }

            self.page_table.freePageFrame(evict_result.evicted_pfn);
            //add the new one
            self.page_table.addFramePage(current_pfn, evict_result.evicted_page_table_entry.frame_ptr, true);
            return .{
                .pfn = current_pfn,
                .page = @ptrCast(evict_result.evicted_page_table_entry.frame_ptr),
            };
        }

        // not full there should be free space for a frame
        const free_frame_ptr_opt = self.buffer_pool.findFreeFramePtr();

        if(free_frame_ptr_opt == null) {
            @panic("No free frame found");
        }

        const free_frame_ptr = free_frame_ptr_opt.?;

        self.page_table.addFramePage(current_pfn, free_frame_ptr, true);
        self.buffer_pool.markFrameAsUsed(free_frame_ptr);

        return .{
            .pfn = current_pfn,
            .page = @ptrCast(free_frame_ptr),
        };
    }

    pub fn PFNToPage(self: *BufferManager, pfn : u64) !*Page {
        if(self.page_table.getPageTableEntry(pfn)) |entry| {
            entry.pin_count += 1;
            return @ptrCast(entry.frame_ptr);
        }

        const disk_offset_opt = self.page_directory.getDiskOffsetForPNF(pfn);

        if(disk_offset_opt == null) {
            @panic("Disk_Offset not found");
        }

        const disk_offset = disk_offset_opt.?;

        if(self.page_table.isBufferPoolFull()) {
            const evict_result = self.page_table.findEvictableFrame();

            if(evict_result.evicted_is_dirty){
                try FlushPage(self, evict_result.evicted_pfn);
            }

            self.page_table.freePageFrame(evict_result.evicted_pfn);
            try file_util.readPageAt(self.io, self.file, disk_offset, evict_result.evicted_page_table_entry.frame_ptr);
            self.page_table.addFramePage(pfn, evict_result.evicted_page_table_entry.frame_ptr, false);
            return @ptrCast(evict_result.evicted_page_table_entry.frame_ptr);
        }

        const frame_ptr_opt = self.buffer_pool.findFreeFramePtr();

        if(frame_ptr_opt == null) {
            @panic("No found frame_ptr");
        }

        const frame_ptr = frame_ptr_opt.?;

        try file_util.readPageAt(self.io, self.file, disk_offset, frame_ptr);
        self.page_table.addFramePage(pfn, frame_ptr, false);
        self.buffer_pool.markFrameAsUsed(frame_ptr);

        return @ptrCast(frame_ptr);
    }

    pub fn FreePageFrame(self: *BufferManager, pfn: u64) !void {
        //TODO: does this also flush??? (for now yes)


        //TODO duplicate code with FlushPage
        const frame_entry_opt = self.page_table.getPageTableEntry(pfn);

        if(frame_entry_opt == null) {
            // no data
            @panic("No Page-Frame for given pfn, is this wanted?");
        }

        const frame_entry = frame_entry_opt.?;
        const frame_ptr = frame_entry.frame_ptr;

        if(!frame_entry.dirty) {
            // not dirty -> no need to flush
            self.page_table.freePageFrame(pfn);
            self.buffer_pool.markFrameAsFree(frame_ptr);
            return;
        }


        const disk_offset = try fetchOrStoreOffsetForPFN(self, pfn);

        try file_util.writePageAt(self.io, self.file, disk_offset, frame_ptr);
        self.buffer_pool.markFrameAsFree(frame_ptr);
    }

    pub fn FlushPage(self : *BufferManager, pfn : u64) !void {
        const frame_entry_opt = self.page_table.getPageTableEntry(pfn);

        if(frame_entry_opt == null) {
            // no data
            @panic("No Page-Frage for given, is this wanted?");
        }

        const frame_entry = frame_entry_opt.?;

        if(!frame_entry.dirty) {
            // not dirty -> no need to flush
            return;
        }

        const frame_ptr = frame_entry.frame_ptr;
        const disk_offset = try fetchOrStoreOffsetForPFN(self, pfn);

        try self.page_directory.storePNFtoDiskOffset(pfn, disk_offset);

        try file_util.writePageAt(self.io, self.file, disk_offset, frame_ptr);
    }

    fn fetchOrStoreOffsetForPFN(self : *BufferManager, pfn : u64) !u64 {
        if(self.page_directory.getDiskOffsetForPNF(pfn)) |offset| {
            return offset;
        }

        const disk_offset: u64 = pfn * api.page_size;
        try self.page_directory.storePNFtoDiskOffset(pfn, disk_offset);

        return disk_offset;
    }


    pub fn DecrementPinCount(self: *BufferManager, pfn : u64) void {
        self.page_table.decrementPinCount(pfn);
    }

    pub fn MarkDirty(self: *BufferManager, pfn : u64) void {
        self.page_table.markAsDirty(pfn);
    }

    pub fn deinit(self : *BufferManager) void {
        //TODO
        _ = self;
    }

};

const testing = std.testing;

const TestCtx = struct {
    threaded: *std.Io.Threaded,
    io: std.Io,
    bm: BufferManager,

    fn deinit(self: *TestCtx) void {
        self.bm.deinit();
        std.Io.Dir.cwd().deleteFile(self.io, "storage.db") catch {};
        self.threaded.deinit();
        std.testing.allocator.destroy(self.threaded);
    }
};

fn setupTempBM() !TestCtx {
    const threaded = try std.testing.allocator.create(std.Io.Threaded);
    errdefer std.testing.allocator.destroy(threaded);
    threaded.* = .init(std.testing.allocator, .{});
    errdefer threaded.deinit();

    const t_io = threaded.io();

    // Pre-clean any leftover from a prior run
    std.Io.Dir.cwd().deleteFile(t_io, "storage.db") catch {};

    const bm = try BufferManager.init(t_io);

    return .{
        .threaded = threaded,
        .io = t_io,
        .bm = bm,
    };
}

test "AllocPageFrame: returns distinct PFNs" {
    var ctx = try setupTempBM();
    defer ctx.deinit();

    const a = try ctx.bm.AllocPageFrame();
    ctx.bm.DecrementPinCount(a.pfn);
    const b = try ctx.bm.AllocPageFrame();
    ctx.bm.DecrementPinCount(b.pfn);
    const c = try ctx.bm.AllocPageFrame();
    ctx.bm.DecrementPinCount(c.pfn);

    try testing.expect(a.pfn != b.pfn);
    try testing.expect(b.pfn != c.pfn);
    try testing.expect(a.pfn != c.pfn);
}

test "AllocPageFrame: returns writable page pointers" {
    var ctx = try setupTempBM();
    defer ctx.deinit();

    const r = try ctx.bm.AllocPageFrame();
    defer ctx.bm.DecrementPinCount(r.pfn);

    r.page.mem[0] = 0xAB;
    r.page.mem[api.page_size - 1] = 0xCD;
    try testing.expectEqual(@as(u8, 0xAB), r.page.mem[0]);
    try testing.expectEqual(@as(u8, 0xCD), r.page.mem[api.page_size - 1]);
}

test "PFNToPage: returns same data as written" {
    var ctx = try setupTempBM();
    defer ctx.deinit();

    const r = try ctx.bm.AllocPageFrame();
    for (0..api.page_size) |i| {
        r.page.mem[i] = @truncate(i & 0xFF);
    }
    ctx.bm.MarkDirty(r.pfn);
    ctx.bm.DecrementPinCount(r.pfn);

    const same = try ctx.bm.PFNToPage(r.pfn);
    defer ctx.bm.DecrementPinCount(r.pfn);

    for (0..api.page_size) |i| {
        try testing.expectEqual(@as(u8, @truncate(i & 0xFF)), same.mem[i]);
    }
}

test "Pin counting: PFNToPage increments, DecrementPinCount balances" {
    var ctx = try setupTempBM();
    defer ctx.deinit();

    const r = try ctx.bm.AllocPageFrame();
    _ = try ctx.bm.PFNToPage(r.pfn);
    _ = try ctx.bm.PFNToPage(r.pfn);
    ctx.bm.DecrementPinCount(r.pfn);
    ctx.bm.DecrementPinCount(r.pfn);
    ctx.bm.DecrementPinCount(r.pfn); // balance the alloc's pin too
}

test "Eviction: dirty pages survive round-trip to disk" {
    var ctx = try setupTempBM();
    defer ctx.deinit();

    const overcommit = 6;
    var pfns: [overcommit]u64 = undefined;

    for (0..overcommit) |i| {
        const r = try ctx.bm.AllocPageFrame();
        pfns[i] = r.pfn;
        @memset(&r.page.mem, @truncate(r.pfn & 0xFF));
        ctx.bm.MarkDirty(r.pfn);
        ctx.bm.DecrementPinCount(r.pfn);
    }

    for (pfns) |pfn| {
        const p = try ctx.bm.PFNToPage(pfn);
        defer ctx.bm.DecrementPinCount(pfn);

        const expected: u8 = @truncate(pfn & 0xFF);
        try testing.expectEqual(expected, p.mem[0]);
        try testing.expectEqual(expected, p.mem[api.page_size / 2]);
        try testing.expectEqual(expected, p.mem[api.page_size - 1]);
    }
}

test "Eviction: clean pages don't crash on eviction" {
    var ctx = try setupTempBM();
    defer ctx.deinit();

    const overcommit = 6;
    var pfns: [overcommit]u64 = undefined;
    for (0..overcommit) |i| {
        const r = try ctx.bm.AllocPageFrame();
        pfns[i] = r.pfn;
        ctx.bm.DecrementPinCount(r.pfn);
    }

    for (pfns) |pfn| {
        _ = try ctx.bm.PFNToPage(pfn);
        ctx.bm.DecrementPinCount(pfn);
    }
}

test "MarkDirty before eviction: sentinel byte survives" {
    var ctx = try setupTempBM();
    defer ctx.deinit();

    const r1 = try ctx.bm.AllocPageFrame();
    const sentinel: u8 = 0x42;
    r1.page.mem[100] = sentinel;
    ctx.bm.MarkDirty(r1.pfn);
    ctx.bm.DecrementPinCount(r1.pfn);

    var others: [5]u64 = undefined;
    for (&others) |*slot| {
        const r = try ctx.bm.AllocPageFrame();
        slot.* = r.pfn;
        ctx.bm.DecrementPinCount(r.pfn);
    }

    const reloaded = try ctx.bm.PFNToPage(r1.pfn);
    defer ctx.bm.DecrementPinCount(r1.pfn);

    try testing.expectEqual(sentinel, reloaded.mem[100]);
}

test "Repeated PFNToPage on cached PFN returns same pointer" {
    var ctx = try setupTempBM();
    defer ctx.deinit();

    const r = try ctx.bm.AllocPageFrame();
    r.page.mem[200] = 0x77;
    ctx.bm.MarkDirty(r.pfn);

    const a = try ctx.bm.PFNToPage(r.pfn);
    const b = try ctx.bm.PFNToPage(r.pfn);

    try testing.expectEqual(@intFromPtr(a), @intFromPtr(b));
    try testing.expectEqual(@as(u8, 0x77), a.mem[200]);

    ctx.bm.DecrementPinCount(r.pfn);
    ctx.bm.DecrementPinCount(r.pfn);
    ctx.bm.DecrementPinCount(r.pfn);
}

test "FreePageFrame: page can be freed after use" {
    var ctx = try setupTempBM();
    defer ctx.deinit();

    const r = try ctx.bm.AllocPageFrame();
    r.page.mem[0] = 0x99;
    ctx.bm.MarkDirty(r.pfn);
    ctx.bm.DecrementPinCount(r.pfn);

    try ctx.bm.FreePageFrame(r.pfn);
}