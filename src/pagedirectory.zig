const std = @import("std");

pub const PageDirectory = struct {

    //mapping pfn to disk_offset
    table: std.AutoHashMap(u64, u64),
    io: std.Io,

    pub fn init(io : std.Io) @This() {
        const table = std.AutoHashMap(u64, u64).init(std.heap.smp_allocator);

        return .{
            .table = table,
            .io = io,
        };
    }

    pub fn storePNFtoDiskOffset(self : *PageDirectory, pnf: u64, offset: u64) error{OutOfMemory}!void {
        try self.table.put(pnf, offset);
    }

    pub fn getDiskOffsetForPNF(self : *PageDirectory, pnf: u64) ?u64 {
        return self.table.get(pnf);
    }

    pub fn deinit(self : *PageDirectory) void {
        std.heap.smp_allocator.free(self.table);
    }

};