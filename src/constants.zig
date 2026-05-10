const api = @import("api.zig");


pub const BUFFER_POOL_SIZE_IN_PAGES : u64 = 2;
pub const BUFFER_POOL_SIZE_IN_BYTES : u64 = BUFFER_POOL_SIZE_IN_PAGES * api.page_size;

pub const FramePtr = *align(api.page_size) [api.page_size]u8;