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
        const page_table: PageTable = PageTable.init();
        const buffer_pool: BufferPool = BufferPool.init();

        return .{
              .io = io,
              .page_directory = page_directory,
              .page_table = page_table,
              .buffer_pool = buffer_pool,
              .pfn_counter = std.atomic.Value(u64).init(0),
              .file = try createStorageFile(io,"storage.db"),
        };
    }

    fn createStorageFile(std_io: std.Io, file_name: []const u8) !std.Io.File {
        try std.Io.Dir.cwd().createFile(std_io, file_name, .{ .read = true, .truncate = true });
    }

    pub fn AllocPageFrame(self: *BufferManager) !struct { pfn: u64, page: *Page} {
        const current_pfn = self.pfn_counter.fetchAdd(1, .monotonic);

        // find suited place in the bufferpool

        if(self.page_table.isBufferPoolFull()) {
            //if this is the case we need to evict
            const evict_result = self.page_table.findEvictableFrame();

            if(evict_result.evicted_is_dirty){
                //flush the frame which should be evicted
                FlushPage(self, evict_result.evicted_pfn);
            }

            self.page_table.freePageFrame(evict_result.evicted_pfn);
            //add the new one
            self.page_table.addFramePage(current_pfn, evict_result.evicted_page_table_entry.frame_ptr, true);
            return .{
                current_pfn,
                @ptrCast(evict_result.evicted_page_table_entry.frame_ptr),
            };
        }

        // not full there should be free space for a frame
        const free_frame_ptr = self.buffer_pool.findFreeFramePtr();
        self.page_table.addFramePage(current_pfn, free_frame_ptr, true);

        return .{
            current_pfn,
            @ptrCast(free_frame_ptr),
        };
    }

    pub fn PFNToPage(self: *BufferManager, pfn : u64) !*Page {
        if(self.page_table.getPageTableEntry(pfn)) |entry| {
            return @ptrCast(entry.frame_ptr);
        }


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

        if(!frame_entry.dirty) {
            // not dirty -> no need to flush
            self.page_table.freePageFrame(pfn);
            return;
        }

        const frame_ptr = frame_entry.frame_ptr;
        const disk_offset = fetchOrStoreOffsetForPFN(self, pfn);

        try self.page_directory.storePNFtoDiskOffset(pfn, disk_offset);

        try file_util.writePageAt(self.io, self.file, disk_offset, frame_ptr);
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
        const disk_offset = fetchOrStoreOffsetForPFN(self, pfn);

        try self.page_directory.storePNFtoDiskOffset(pfn, disk_offset);

        try file_util.writePageAt(self.io, self.file, disk_offset, frame_ptr);
    }

    fn fetchOrStoreOffsetForPFN(self : *BufferManager, pfn : u64) u64 {
        if(self.page_directory.getDiskOffsetForPNF(pfn)) |offset| {
            return offset;
        }

        const disk_offset: u64 = pfn * api.page_size;
        self.page_directory.storePNFtoDiskOffset(pfn, disk_offset);

        return disk_offset;
    }


    pub fn DecrementPinCount(self: *BufferManager, pfn : u64) void {
        self.page_table.decrementPinCount(pfn);
    }

    pub fn MarkDirty(self: *BufferManager, pfn : u64) void {
        self.page_table.markAsDirty(pfn);
    }

};