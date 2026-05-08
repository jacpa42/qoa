const std = @import("std");
const qoa = @This();

pub const encode_endian = std.builtin.Endian.big;
pub const native_endian = std.builtin.Endian.native;
pub const max_decode_channels = 8;
pub const max_slices_per_frame = 256;
pub const num_samples_in_slice = 20;
pub const max_samples_per_frame = max_slices_per_frame * num_samples_in_slice * max_decode_channels;
const max = std.math.maxInt(i16);
const min = std.math.minInt(i16);

// Special clamp from the reference impl in c
pub fn clamp(v: i32) i16 {
    if (@as(u32, @bitCast(v + max + 1)) > 2 * max + 1) {
        @branchHint(.unlikely);
        return @intCast(std.math.clamp(v, min, max));
    }
    return @intCast(v);
}

/// Overestimates the total samples in the file to alloc once
pub fn overEstimateTotalSamples(
    num_channels: u8,
    num_frames_per_channel: u32,
) usize {
    return @as(usize, num_frames_per_channel) *
        @as(usize, num_channels) *
        max_slices_per_frame *
        num_samples_in_slice;
}
