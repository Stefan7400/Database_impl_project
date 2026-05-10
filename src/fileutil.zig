const std = @import("std");
const FramePtr = @import("constants.zig").FramePtr;

pub fn writePageAt(
    io: std.Io,
    file: std.Io.File,
    offset: u64,
    page: FramePtr,
) !void {
    try file.writePositionalAll(io, std.mem.asBytes(page), offset);
}

pub fn readPageAt(
    io: std.Io,
    file: std.Io.File,
    offset: u64,
    page: FramePtr,
) !void {
    const n = try file.readPositionalAll(io, page, offset);
    if (n != page.len) {
        @panic("Did not read full page from disk");
    }
}