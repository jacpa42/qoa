const std = @import("std");
const consts = @import("src/constants.zig");
const log = std.log.scoped(.qoa);

pub const decode = @import("src/decode.zig");
pub const multithread = @import("src/multithread.zig");
pub const Frame = @import("src/Frame.zig");
pub const Header = @import("src/Header.zig");

test {
    std.testing.refAllDecls(@This());
}

const qoa = @This();

num_channels: u8,
sample_rate_hz: u24,
sample_list: std.ArrayList(i16),

pub fn deinit(
    self: *qoa,
    alloc: std.mem.Allocator,
) void {
    self.sample_list.deinit(alloc);
}
