const std = @import("std");
const consts = @import("constants.zig");
const Header = @This();

/// Checks the magic and returns the SamplesPerChannel for this file
pub fn decode(
    reader: *std.Io.Reader,
) DecodeError!SamplesPerChannel {
    try checkMagic(reader);
    return SamplesPerChannel.decode(reader);
}

pub const SamplesPerChannel = enum(u32) {
    streaming = 0,
    _,

    pub fn decode(
        reader: *std.Io.Reader,
    ) DecodeError!SamplesPerChannel {
        var samples_per_channel: u32 = @bitCast((try reader.takeArray(@sizeOf(SamplesPerChannel))).*);

        if (consts.native_endian != .big) {
            samples_per_channel = @byteSwap(samples_per_channel);
        }

        return @enumFromInt(samples_per_channel);
    }

    /// Returns the number of frames per channel in the whole file rounded up.
    /// Not known if streaming.
    const max_samples_per_frame = consts.num_samples_in_slice * consts.max_slices_per_frame;
    pub fn numFramesPerChannel(self: SamplesPerChannel) ?u32 {
        return switch (self) {
            .streaming => null,
            else => 1 + @divFloor(@as(u32, @intFromEnum(self)) - 1, max_samples_per_frame),
        };
    }
};

pub const DecodeError = error{
    InvalidFileFormat,
    ReadFailed,
    EndOfStream,
};

pub fn checkMagic(
    reader: *std.Io.Reader,
) DecodeError!void {
    const magic: [4]u8 = (try reader.takeArray(4)).*;

    if (@as(u32, @bitCast(magic)) !=
        @as(u32, @bitCast(consts.magic)))
    {
        return error.InvalidFileFormat;
    }
}
