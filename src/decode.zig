const std = @import("std");
const consts = @import("constants.zig");
const qoa = @import("../qoa.zig");

const log = std.log.scoped(.qoa);
const Header = @import("Header.zig");
const Frame = @import("Frame.zig");

test {
    std.testing.refAllDecls(@This());
}

pub const Error = error{
    EndOfStream,
    ExceededMaxDecodeChannels,
    InvalidFileFormat,
    OutOfMemory,
    ReadFailed,
};

/// Decodes directly from the file reader allocating once only for the sample data
pub fn fromPath(
    alloc: std.mem.Allocator,
    sub_path: [:0]const u8,
) (Error || std.fs.File.OpenError)!qoa {
    var file = try std.fs.cwd().openFile(sub_path, .{});
    var iobuf: [1024]u8 = undefined;
    var reader = file.reader(&iobuf);
    return fromReader(alloc, &reader.interface);
}

pub fn fromSlice(
    alloc: std.mem.Allocator,
    slice: []const u8,
) Error!qoa {
    var reader = std.Io.Reader.fixed(slice);
    return fromReader(alloc, &reader);
}

pub fn fromReader(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
) Error!qoa {
    const samples_per_channel = try Header.decode(reader);
    return switch (samples_per_channel) {
        .streaming => @panic("TODO: Implement streaming decoder"),
        else => |samples| fromReaderStatic(alloc, reader, samples),
    };
}

/// Asserts that the file is not in streaming mode (`samples_per_channel==.streaming`)
pub fn fromReaderStatic(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
    samples_per_channel: Header.SamplesPerChannel,
) Error!qoa {
    std.debug.assert(samples_per_channel != .streaming);
    std.debug.assert(@as(usize, @intFromEnum(samples_per_channel)) >= 1); // same as above :)

    // Calculate some info about the file
    const num_frames_per_channel = samples_per_channel.numFramesPerChannel() orelse unreachable;
    const num_channels, const sample_rate_hz = try consts.peekMeta(reader);
    const estimated_total_samples = consts.overEstimateTotalSamples(
        num_channels,
        num_frames_per_channel,
    );

    // Create lms buf
    if (num_channels > consts.max_decode_channels) return error.ExceededMaxDecodeChannels;
    var lms_state_buf: [consts.max_decode_channels]Frame.LmsState = undefined;

    log.debug(
        "Estimated memory: {:.4}MiB",
        .{@as(f32, @floatFromInt(estimated_total_samples * @sizeOf(i16))) / (1024 * 1024)},
    );

    var sample_list = try std.ArrayList(i16).initCapacity(alloc, estimated_total_samples);
    errdefer sample_list.deinit(alloc);

    for (0..num_frames_per_channel) |_| {
        // read the frame header
        const header = try Frame.Header.decode(reader);

        // Decode the lms states
        const lms_states = lms_state_buf[0..header.num_channels];
        for (lms_states) |*lms| lms.* = try .decode(reader);

        // Get sample output slice
        const frame_sample_count = header.getSampleSlice();
        const samples = try sample_list.addManyAsSliceBounded(frame_sample_count);

        try Frame.decodeSlices(reader, lms_states, header.num_channels, samples);
    }

    log.debug(
        "Filled {:.3}% of arraylist ({:.4}MiB left)",
        .{
            @as(f32, @floatFromInt(100 * sample_list.items.len)) / @as(f32, @floatFromInt(sample_list.capacity)),
            @as(f32, @floatFromInt(
                (sample_list.capacity - sample_list.items.len) * @sizeOf(i16),
            )) / (1024 * 1024),
        },
    );

    return .{
        .num_channels = num_channels,
        .sample_rate_hz = sample_rate_hz,
        .sample_list = sample_list,
    };
}
