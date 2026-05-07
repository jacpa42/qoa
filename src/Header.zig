const std = @import("std");
const consts = @import("constants.zig");
const Header = @This();

pub const magic = "qoaf";

samples_per_channel: SamplesPerChannel,

pub const DecodeError = error{
    InvalidFileFormat,
    ReadFailed,
    EndOfStream,
};

/// Checks the magic and returns the SamplesPerChannel for this file
pub fn decode(
    reader: *std.Io.Reader,
) DecodeError!Header {
    try checkMagic(reader);
    return .{ .samples_per_channel = try .decode(reader) };
}

pub const SamplesPerChannel = enum(u32) {
    streaming = 0,
    _,

    pub fn decode(
        reader: *std.Io.Reader,
    ) DecodeError!SamplesPerChannel {
        return @enumFromInt(try reader.takeInt(u32, .big));
    }

    const max_samples_per_frame = consts.num_samples_in_slice * consts.max_slices_per_frame;

    /// Returns the number of frames per channel in the whole file rounded up.
    /// `null` iff streaming.
    pub fn totalFramesPerChannel(self: SamplesPerChannel) ?u32 {
        return switch (self) {
            .streaming => null,
            else => 1 + @divFloor(
                @as(u32, @intFromEnum(self)) - 1,
                max_samples_per_frame,
            ),
        };
    }
};

pub fn checkMagic(reader: *std.Io.Reader) DecodeError!void {
    if (!std.mem.eql(u8, try reader.takeArray(4), magic)) {
        return error.InvalidFileFormat;
    }
}
