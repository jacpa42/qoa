const std = @import("std");

const qoa = @This();

const magic: [4]u8 = "qoaf".*;
const max_decode_channels = 8;
const max_slices_per_frame = 256;
const num_samples_in_slice = 20;
const max_samples_in_frame = max_slices_per_frame * num_samples_in_slice * max_decode_channels;
const native_endian = @import("builtin").cpu.arch.endian();
const dequant_tab: [16][8]i16 = blk: {
    // PERF: Pre-compute the de-quant tab for epic speed-ups :)
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

num_channels: u8,
sample_rate_hz: u24,
samples: []i16,

pub const Header = extern struct {
    magic: [4]u8 = undefined,
    samples: Samples,

    pub const Samples = enum(u32) {
        streaming = 0,
        _,
    };

    pub const DecodeError = error{
        InvalidFileFormat,
        ReadFailed,
        EndOfStream,
    };

    pub fn decode(
        reader: *std.Io.Reader,
    ) Header.DecodeError!Header {
        var header: Header = @bitCast((try reader.takeArray(@sizeOf(Header))).*);

        if (@as(u32, @bitCast(header.magic)) !=
            @as(u32, @bitCast(magic)))
        {
            return error.InvalidFileFormat;
        }

        if (native_endian != .big) {
            header.samples = @enumFromInt(@byteSwap(@intFromEnum(header.samples)));
        }

        return header;
    }
};

pub const Frame = struct {
    pub const DecodeError = error{
        ReadFailed,
        EndOfStream,
        ExceededMaxDecodeChannels,
    };

    fn decode(
        reader: *std.Io.Reader,
        lms_state_buf: *[max_decode_channels]Frame.LmsState,
        sample_list: *std.ArrayList(i16),
    ) Frame.DecodeError!void {
        // read the frame header
        const frame_header = try Frame.Header.decode(reader);

        if (frame_header.num_channels > max_decode_channels) {
            @branchHint(.unlikely);
            return error.ExceededMaxDecodeChannels;
        }

        const lms_states = lms_state_buf[0..frame_header.num_channels];

        var samples_computed: u32 = 0;
        const total_samples_in_frame: u32 = std.math.mulWide(
            u16,
            frame_header.samples_per_channel,
            frame_header.num_channels,
        );

        std.debug.assert(sample_list.capacity - sample_list.items.len > total_samples_in_frame);
        const samples = sample_list.addManyAsSliceAssumeCapacity(total_samples_in_frame);

        // read the LMS history & weights for this channel
        for (lms_states) |*lms_state| lms_state.* = try .decode(reader);

        const samples_per_frame = num_samples_in_slice * frame_header.num_channels;

        while (samples_computed < total_samples_in_frame) {
            defer samples_computed += samples_per_frame;

            for (0..frame_header.num_channels) |channel_no| {
                var slice = try Slice.decode(reader);
                const sf_quant: u4 = @truncate(slice >> 60);
                slice <<= 4;

                var sample_index = samples_computed + channel_no;
                const slice_end = @min(sample_index + samples_per_frame, total_samples_in_frame);

                while (sample_index < slice_end) : (sample_index += frame_header.num_channels) {
                    const predicted = lms_states[channel_no].predict();
                    const quantized: u3 = @truncate(slice >> 61);
                    const dequantized = @as(i32, dequant_tab[sf_quant][quantized]);
                    const reconstructed = clamp(predicted + dequantized);

                    samples[sample_index] = reconstructed;

                    slice <<= 3;
                    lms_states[channel_no].update(reconstructed, dequantized);
                }
            }
        }
    }

    pub const Header = packed struct(u64) {
        num_channels: u8,
        sample_rate_hz: u24,
        samples_per_channel: u16,
        frame_size: u16,

        pub const DecodeError = error{ ReadFailed, EndOfStream };

        pub fn decode(
            reader: *std.Io.Reader,
        ) Frame.Header.DecodeError!Frame.Header {
            var header: Frame.Header =
                @bitCast((try reader.takeArray(@sizeOf(Frame.Header))).*);

            if (native_endian != .big) {
                std.mem.byteSwapAllFields(Frame.Header, &header);
            }

            return header;
        }

        pub fn peek(
            reader: *std.Io.Reader,
        ) Frame.Header.DecodeError!Frame.Header {
            var header: Frame.Header =
                @bitCast((try reader.peekArray(@sizeOf(Frame.Header))).*);

            if (native_endian != .big) {
                std.mem.byteSwapAllFields(Frame.Header, &header);
            }

            return header;
        }
    };

    pub const LmsState = struct {
        history: [lms_len]i32,
        weights: [lms_len]i32,

        const lms_len = 4;

        pub const DecodeError = error{ ReadFailed, EndOfStream };

        pub fn update(
            self: *LmsState,
            reconstructed_sample: i32,
            dequantized_residual: i32,
        ) void {
            const delta = dequantized_residual >> 4;
            for (0..lms_len) |i| {
                self.weights[i] +%= if (self.history[i] < 0) -delta else delta;
            }

            {
                self.history[0] = self.history[1];
                self.history[1] = self.history[2];
                self.history[2] = self.history[3];
                self.history[3] = reconstructed_sample;
            }
        }

        pub fn predict(self: LmsState) i32 {
            var predicted: i32 = 0;
            for (self.history, self.weights) |h, w| {
                predicted +%= h *% w;
            }
            return predicted >> 13;
        }

        pub fn decode(
            reader: *std.Io.Reader,
        ) LmsState.DecodeError!LmsState {
            var state: LmsState = undefined;
            for (0..lms_len) |i| {
                state.history[i] = try reader.takeInt(i16, .big);
            }
            for (0..lms_len) |i| {
                state.weights[i] = try reader.takeInt(i16, .big);
            }
            return state;
        }
    };
};

pub const Slice = struct {
    pub const DecodeError = error{ ReadFailed, EndOfStream };
    pub fn decode(reader: *std.Io.Reader) Slice.DecodeError!u64 {
        return @bitCast(try reader.takeInt(u64, .big));
    }
};

pub const DecodeError = error{
    EndOfStream,
    ExceededMaxDecodeChannels,
    InvalidFileFormat,
    OutOfMemory,
    ReadFailed,
};

pub fn decodeSlice(
    alloc: std.mem.Allocator,
    slice: []const u8,
) DecodeError!qoa {
    var reader = std.Io.Reader.fixed(slice);
    return decodeReader(alloc, &reader);
}

pub fn decodeReader(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
) DecodeError!qoa {
    const header = try Header.decode(reader);
    return switch (header.samples) {
        .streaming => @panic("TODO: Implement streaming decoder"),
        else => |samples| decodeReaderStatic(alloc, reader, samples),
    };
}

pub fn decodeReaderStatic(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
    samples: Header.Samples,
) DecodeError!qoa {
    std.debug.assert(samples != .streaming);
    std.debug.assert(@as(usize, @intFromEnum(samples)) >= 1); // same as above :)

    // Peek to get the sample rate
    const num_channels, const sample_rate_hz = blk: {
        const header_data = try Frame.Header.peek(reader);

        break :blk .{ header_data.num_channels, header_data.sample_rate_hz };
    };

    const num_frames: usize = 1 + @divFloor(
        @as(usize, @intFromEnum(samples)) - 1,
        num_samples_in_slice * max_slices_per_frame,
    );

    if (num_channels > max_decode_channels) return error.ExceededMaxDecodeChannels;
    var lms_states: [max_decode_channels]Frame.LmsState = undefined;

    // This overshoots by a small amount depending on how many are in the final frame
    const estimated_total_samples = num_frames * max_slices_per_frame * num_channels * num_samples_in_slice;
    var sample_list = try std.ArrayList(i16).initCapacity(alloc, estimated_total_samples);
    errdefer sample_list.deinit(alloc);

    for (0..num_frames) |_| {
        try Frame.decode(reader, &lms_states, &sample_list);
    }

    return qoa{
        .num_channels = num_channels,
        .sample_rate_hz = sample_rate_hz,
        .samples = try sample_list.toOwnedSlice(alloc),
    };
}

pub fn deinit(
    self: qoa,
    alloc: std.mem.Allocator,
) void {
    alloc.free(self.samples);
}

// Special clamp
pub fn clamp(v: i32) i16 {
    if (@as(u32, @bitCast(v + 32768)) > 65535) {
        @branchHint(.unlikely);
        if (v < -32768) return -32768;
        if (v > 32767) return 32767;
    }
    return @intCast(v);
}

test {
    std.testing.refAllDecls(@This());
}
