const std = @import("std");
const qoa = @This();

pub const stack_size = 64 * 1024;
pub const default_num_workers = 8;
pub const max_workers = 256;
pub const native_endian = @import("builtin").cpu.arch.endian();
pub const magic: [4]u8 = "qoaf".*;
pub const max_decode_channels = 8;
pub const max_slices_per_frame = 256;
pub const num_samples_in_slice = 20;
pub const max_samples_in_frame = max_slices_per_frame * num_samples_in_slice * max_decode_channels;
pub const dequant_tab: [16][8]i16 = blk: {
    const dt = [_]comptime_float{ 0.75, -0.75, 2.5, -2.5, 4.5, -4.5, 7, -7 };
    var array: [16][8]i16 = @splat(@splat(0));
    var sf = 0;
    while (sf < 16) : (sf += 1) {
        @setEvalBranchQuota(1500);
        const scale_factor = @round(std.math.pow(f32, @as(f32, sf + 1), 2.75));
        var qr = 0;
        while (qr < 8) : (qr += 1) {
            array[sf][qr] = @round(scale_factor * dt[qr]);
        }
    }

    break :blk array;
};
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

comptime {
    if (default_num_workers <= 0) {
        @compileError("default_num_workers must be > 0");
    }
}

/// Returns the `num_channels` and `sample_rate_hz` from the first frame header
pub fn peekMeta(
    reader: *std.Io.Reader,
) error{ ReadFailed, EndOfStream }!struct { u8, u24 } {
    const F = packed struct(u32) { num_channels: u8, sample_rate_hz: u24 };
    var header_data: F = @bitCast((try reader.peekArray(@sizeOf(F))).*);

    if (native_endian != .big) {
        std.mem.byteSwapAllFields(F, &header_data);
    }

    return .{ header_data.num_channels, header_data.sample_rate_hz };
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
