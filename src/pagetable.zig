const std = @import("std");
const FramePtr = @import("constants.zig").FramePtr;
const BUFFER_POOL_SIZE_IN_PAGES  = @import("constants.zig").BUFFER_POOL_SIZE_IN_PAGES;

pub const PageTable = struct {

    table: std.AutoHashMap(u64, PageTableEntry),

    pub fn init() !@This() {
        var table = std.AutoHashMap(u64, PageTableEntry).init(std.heap.smp_allocator);
        try table.ensureTotalCapacity(BUFFER_POOL_SIZE_IN_PAGES);


        return .{
            .table = table,
        };
    }

    pub fn addFramePage(self : *PageTable, pfn : u64, frame_ptr : FramePtr, dirty : bool) void {
        const pageTableEntry: PageTableEntry = .{
            .pin_count = 1,
            .dirty = dirty,
            .frame_ptr = frame_ptr,
        };

        self.table.putAssumeCapacity(pfn, pageTableEntry);
    }

    pub fn getPageTableEntry(self : *PageTable, pfn : u64) ?*PageTableEntry {
        return self.table.getPtr(pfn);
    }

    pub fn isBufferPoolFull(self : *PageTable) bool {
        return self.table.count() == BUFFER_POOL_SIZE_IN_PAGES;
    }

    pub fn findEvictableFrame(self : *PageTable) EvictResult {
        var iter = self.table.iterator();
        while(iter.next()) |e| {
            if(e.value_ptr.pin_count != 0) {
                continue;
            }

            return .{
              .evicted_pfn = e.key_ptr.*,
              .evicted_page_table_entry = e.value_ptr.*,
              .evicted_is_dirty = e.value_ptr.dirty
            };
        }

        @panic("Eviction not possible bc no entry_pin_count == 0");
    }


    pub fn markAsDirty(self : *PageTable, pfn : u64) void {
        if(self.table.getPtr(pfn)) |entry| {
            entry.dirty = true;
        }
    }

    pub fn freePageFrame(self : *PageTable, pfn : u64) void {
        _ = self.table.remove(pfn);
    }


    pub fn decrementPinCount(self : *PageTable, pfn : u64) void {
        if(self.table.getPtr(pfn)) |entry| {
            if(entry.pin_count > 0) {
                entry.pin_count -= 1;
            }
        }
    }

    pub fn increasePinCount(self : *PageTable, pfn : u64) void {
        if(self.table.getPtr(pfn)) |entry| {
            entry.pin_count += 1;
        }
    }

};

pub const PageTableEntry = struct {
    pin_count: u16,
    dirty: bool,
    frame_ptr: FramePtr,
};

pub const EvictResult = struct {
    evicted_pfn : u64,
    evicted_page_table_entry: PageTableEntry,
    evicted_is_dirty: bool
};