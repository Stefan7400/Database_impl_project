const std = @import("std");
const PageDirectory = @import("pagedirectory.zig").PageDirectory;
const PageTable = @import("pagetable.zig").PageTable;

pub const BufferManager = struct {

    io: std.Io,

    page_directory : PageDirectory,
    page_table : PageTable,


    pub fn init(io : std.Io) !@This() {
        const page_directory = PageDirectory.init(io);
        const page_table: PageTable = PageTable.init();

        return .{
              .io = io,
              .page_directory = page_directory,
              .page_table = page_table,
        };
    }


    pub fn DecrementPinCount(self: *BufferManager, pfn : u64) void {
        self.page_table.decrementPinCount(pfn);
    }

    pub fn MarkDirty(self: *BufferManager, pfn : u64) void {
        self.page_table.markAsDirty(pfn);
    }

};