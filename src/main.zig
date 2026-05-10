const std = @import("std");
const Io = std.Io;
const BufferManager = @import("buffermanager.zig").BufferManager;

const db_project_new = @import("db_project_new");

pub fn main(init: std.process.Init) !void {
    const bm = try BufferManager.init(init.io);
    _ = bm.AllocPageFrame();


}
