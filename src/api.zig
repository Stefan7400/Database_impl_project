const std = @import("std");

const BufferManager = @import("buffermanager.zig").BufferManager;

pub const page_size = 1 << 12;
pub const Page = struct {
    mem: [page_size]u8 align(page_size),
};


// // Allocates a page frame. Also allocates and returns a corresponding page
fn AllocPageFrame(bfr_mngr: *BufferManager) !struct { pfn: u64, page: *Page} {
    return bfr_mngr.AllocPageFrame();
}
// // Final free of a page frame
// fn FreePageFrame(pfn: u64, bfr_mngr: *BufferManager) !void {}
// // Get the page of a pfn either from memory or disk. Incremenst the pin count by
// // one. The pin count is needed to not evict pages that are currently in use
// fn PFNToPage(pfn: u64, bfr_mngr: *BufferManager) !*Page {}
// // Marks the page as dirty (e.g. by setting its dirty bit)
// fn MarkDirty(pfn: u64, bfr_mngr: *BufferManager) void {}
// // Flush a dirty page to disk and clear its dirty bit
// fn FlushPage(pfn: u64, bfr_mngr: *BufferManager) !void {}
// // Releases a page by decrementing the pin count. Further acceses must first
// // call PFNToPage() again.
// fn DecrementPinCount(pfn: u64, bfr_mngr: *BufferManager) void {}
// // Optional
// fn PFNToPageAsync(pfn: u64, bfr_mngr: *BufferManager) !?*Page {}