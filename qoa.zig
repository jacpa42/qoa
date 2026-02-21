const std = @import("std");

const qoa = @This();

const magic = "qoaf";
const max_decode_channels = 32;
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

pub const Header = packed struct(u64) {
    padding: u32 = undefined,
    samples: Samples,

    pub const Samples = enum(u32) {
        streaming = 0,
        _,
    };

    pub const DecodeError = error{InvalidFileFormat};

    pub fn decode(
        reader: *std.Io.Reader,
    ) Header.DecodeError!Header {
        const header_magic = reader.takeArray(magic.len) catch
            return error.InvalidFileFormat;

        if (!std.mem.eql(u8, header_magic, magic)) {
            return error.InvalidFileFormat;
        }

        const samples = reader.takeInt(u32, .big) catch
            return error.InvalidFileFormat;

        return Header{ .samples = @enumFromInt(samples) };
    }
};

pub const Frame = struct {
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
        history: [4]i32,
        weights: [4]i32,

        pub const DecodeError = error{ ReadFailed, EndOfStream };

        pub fn update(
            self: *LmsState,
            reconstructed: i32,
            dequantized: i32,
        ) void {
            const delta = dequantized >> 4;
            for (self.history, &self.weights) |h, *w| {
                w.* +%= if (h < 0) -delta else delta;
            }

            {
                self.history[0] = self.history[1];
                self.history[1] = self.history[2];
                self.history[2] = self.history[3];
                self.history[3] = reconstructed;
            }
        }

        pub fn predict(self: LmsState) i32 {
            var predicted: i32 = 0;
            for (self.history, self.weights) |h, w| {
                predicted +%= h *% w;
            }
            return predicted >> 13;
        }

        /// Decodes as many `LmsState` values as requested.
        pub fn decodeAll(
            reader: *std.Io.Reader,
            lms_states: []LmsState,
        ) LmsState.DecodeError!void {
            std.debug.assert(lms_states.len <= max_decode_channels);

            for (lms_states) |*lms_state| {
                lms_state.* = try LmsState.decode(reader);
            }
        }

        pub fn decode(
            reader: *std.Io.Reader,
        ) LmsState.DecodeError!LmsState {
            const Lms16 = extern struct {
                history: [4]i16,
                weights: [4]i16,
            };
            var lms16: Lms16 = @bitCast((try reader.takeArray(@sizeOf(Lms16))).*);

            if (native_endian != .big) {
                std.mem.byteSwapAllFields(Lms16, &lms16);
            }

            var state: LmsState = undefined;
            for (0.., lms16.history, lms16.weights) |i, h, w| {
                state.history[i] = h;
                state.weights[i] = w;
            }
            return state;
        }
    };

    pub const DecodeError = error{
        ReadFailed,
        EndOfStream,
    };

    pub fn decode(
        reader: *std.Io.Reader,
        lms_states: []LmsState,
        sample_list: *std.ArrayList(i16),
    ) Frame.DecodeError!void {
        // read the frame header
        const frame_header = try Frame.Header.decode(reader);

        std.debug.assert(lms_states.len == frame_header.num_channels);

        var samples_computed: u32 = 0;
        const total_samples_in_frame: u32 = std.math.mulWide(
            u16,
            frame_header.samples_per_channel,
            frame_header.num_channels,
        );

        std.debug.assert(sample_list.capacity - sample_list.items.len > total_samples_in_frame);

        // read the LMS history & weights for this channel
        try Frame.LmsState.decodeAll(reader, lms_states);

        while (samples_computed < total_samples_in_frame) {
            defer samples_computed += num_samples_in_slice * frame_header.num_channels;

            for (0..frame_header.num_channels) |ch| {
                var slice = try Slice.decode(reader);
                const sf_quant: u4 = blk: {
                    defer slice <<= 4;
                    break :blk @truncate(slice >> 60);
                };

                for (0..num_samples_in_slice) |_| {
                    const predicted = lms_states[ch].predict();
                    const quantized = slice >> 61;
                    const dequantized = @as(i32, dequant_tab[sf_quant][quantized]);
                    const reconstructed = clamp(predicted + dequantized);

                    sample_list.appendAssumeCapacity(reconstructed);

                    slice <<= 3;
                    lms_states[ch].update(reconstructed, dequantized);
                }
            }
        }
    }
};

pub const Slice = struct {
    pub const DecodeError = error{ ReadFailed, EndOfStream };
    pub fn decode(reader: *std.Io.Reader) Slice.DecodeError!u64 {
        return @bitCast(try reader.takeInt(u64, .big));
    }
};

const DecodeError = error{
    OutOfMemory,
    ExceededMaxDecodeChannels,
} ||
    Header.DecodeError ||
    Frame.Header.DecodeError;

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

    var num_frames: usize = 1 + @divFloor(
        @as(usize, @intFromEnum(samples)) - 1,
        num_samples_in_slice * max_slices_per_frame,
    );

    if (num_channels > max_decode_channels) return error.ExceededMaxDecodeChannels;
    var buf: [max_decode_channels]Frame.LmsState = undefined;
    const lms_states = buf[0..num_channels];

    // This overshoots by a small amount depending on how many are in the final frame
    const estimated_total_samples = num_frames * max_slices_per_frame * num_channels * num_samples_in_slice;
    var sample_list = try std.ArrayList(i16).initCapacity(alloc, estimated_total_samples);
    errdefer sample_list.deinit(alloc);

    while (num_frames > 0) : (num_frames -= 1) {
        try Frame.decode(reader, lms_states, &sample_list);
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
