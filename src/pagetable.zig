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

    pub fn isBufferPoolFull(self : *PageTable) bool {
        return self.table.count() == BUFFER_POOL_SIZE_IN_PAGES;
    }


    pub fn markAsDirty(self : *PageTable, pfn : u64) void {
        if(self.table.getPtr(pfn)) |entry| {
            entry.dirty = true;
        }
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

const PageTableEntry = struct {
    pin_count: u16,
    dirty: bool,
    frame_ptr: FramePtr,
};