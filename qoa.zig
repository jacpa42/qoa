const std = @import("std");

const QOA = @This();

const max_decode_channels = 32;
const max_slices = 256;
const num_samples_in_slice = 20;
const max_samples_in_frame = max_slices * num_samples_in_slice * max_decode_channels;
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

num_samples: u8,
sample_rate_hz: u24,
data: []i16,

pub const Header = packed struct(u64) {
    magic: [4]u8, // = "qoaf";
    samples: Samples,

    const Samples = enum(u32) {
        streaming = 0,
        _,
    };

    pub const DecodeError = error{InvalidFileFormat};

    pub fn decode(
        reader: *std.Io.Reader,
    ) Header.DecodeError!Header {
        const expected_magic = "qoaf";
        const magic = reader.takeArray(expected_magic.len) catch
            return error.InvalidFileFormat;

        if (!std.mem.eql(u8, expected_magic, magic)) return error.InvalidFileFormat;

        const samples = reader.takeInt(u32, .big) catch
            return error.InvalidFileFormat;

        return Header{ .magic = expected_magic, .samples = samples };
    }

    test decode {
        const assertEq = std.testing.expectEqualDeep;
        var prng = std.Random.DefaultPrng.init(0);
        const rng = prng.random();

        var samples: u32 = undefined;
        var header_buf: []const u8 = undefined;
        var reader: std.Io.Reader = undefined;
        var decoded: Header = undefined;

        { // happy path
            samples = rng.int(@TypeOf(samples));
            header_buf = "qoaf" ++ std.mem.toBytes(std.mem.nativeToBig(@TypeOf(samples), samples));
            reader = .fixed(header_buf);
            decoded = try Header.decode(&reader);
            assertEq(decoded, Header{ .magic = "qoaf", .samples = samples });

            samples = rng.int(@TypeOf(samples));
            header_buf = "qoaf" ++ std.mem.toBytes(std.mem.nativeToBig(@TypeOf(samples), samples));
            reader = .fixed(header_buf);
            decoded = try Header.decode(&reader);
            assertEq(decoded, Header{ .magic = "qoaf", .samples = samples });

            samples = rng.int(@TypeOf(samples));
            header_buf = "qoaf" ++ std.mem.toBytes(std.mem.nativeToBig(@TypeOf(samples), samples));
            reader = .fixed(header_buf);
            decoded = try Header.decode(&reader);
            assertEq(decoded, Header{ .magic = "qoaf", .samples = samples });
        }

        { // unhappy path
            var buf: []u8 = undefined;

            // too small
            samples = rng.int(@TypeOf(samples));
            buf = &([_]u8{0} ** 7);
            header_buf = rng.bytes(buf);
            reader = .fixed(header_buf);
            assertEq(Header.decode(&reader), error.InvalidFileFormat);

            // too small
            samples = rng.int(@TypeOf(samples));
            buf = &([_]u8{0} ** 2);
            header_buf = rng.bytes(buf);
            reader = .fixed(header_buf);
            assertEq(Header.decode(&reader), error.InvalidFileFormat);

            // no magic
            samples = rng.int(@TypeOf(samples));
            header_buf = "qafo" ++ std.mem.toBytes(std.mem.nativeToBig(@TypeOf(samples), samples));
            reader = .fixed(header_buf);
            assertEq(Header.decode(&reader), error.InvalidFileFormat);
        }
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
                @bitCast(try reader.takeArray(@sizeOf(Frame.Header)));

            if (std.mem.native_endian != .big) {
                std.mem.byteSwapAllFields(Frame.Header, &header);
            }

            return header;
        }

        pub fn peek(
            reader: *std.Io.Reader,
        ) Frame.Header.DecodeError!Frame.Header {
            var header: Frame.Header =
                @bitCast(try reader.peekArray(@sizeOf(Frame.Header)));

            if (std.mem.native_endian != .big) {
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
        ) LmsState.DecodeError!Frame.Header {
            const Lms16 = extern struct {
                history: [4]i16,
                weights: [4]i16,
            };
            var lms16: Lms16 = @bitCast(try reader.takeArray(@sizeOf(Lms16)));

            if (std.mem.native_endian != .big) {
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
            defer samples_computed += num_samples_in_slice;

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

                    try sample_list.appendBounded(reconstructed);

                    slice <<= 3;
                    lms_states[ch].update(reconstructed, dequantized);
                }
            }
        }
    }

    pub fn decodeAlloc(
        alloc: std.mem.Allocator,
        reader: *std.Io.Reader,
        lms_states: []LmsState,
        sample_list: *std.ArrayList(i16),
    ) (error{OutOfMemory} || Frame.DecodeError)!void {
        // read the frame header
        const frame_header = try Frame.Header.decode(reader);
        var samples_computed: u32 = 0;
        const total_samples_in_frame: u32 = std.math.mulWide(
            u16,
            frame_header.samples_per_channel,
            frame_header.num_channels,
        );

        try sample_list.ensureUnusedCapacity(alloc, total_samples_in_frame);

        // read the LMS history & weights for this channel
        try Frame.LmsState.decodeAll(reader, lms_states);

        while (samples_computed < total_samples_in_frame) {
            defer samples_computed += num_samples_in_slice;

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

                    try sample_list.appendBounded(reconstructed);

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
} || Header.DecodeError;

pub fn decodeSlice(
    alloc: std.mem.Allocator,
    slice: []const u8,
) DecodeError!QOA {
    var reader = std.Io.Reader.fixed(slice);
    return decodeReader(alloc, &reader);
}

pub fn decodeReader(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
) DecodeError!QOA {
    const header = try Header.decode(reader);
    return switch (header.samples) {
        .streaming => @panic("TODO: Implement streaming decoder"),
        else => |samples| decodeReaderStatic(alloc, reader, samples),
    };
}

pub fn decodeReaderStatic(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
    header: Header,
) DecodeError!QOA {
    std.debug.assert(header.samples != .streaming);
    std.debug.assert(@as(usize, header.samples) >= 1); // same as above :)

    const num_frames: usize = 1 + @divFloor(@as(usize, header.samples) - 1, num_samples_in_slice);

    // Peek to get the sample rate
    const num_channels, const sample_rate_hz = blk: {
        const header_data = try Frame.Header.peek(reader);
        break :blk .{ header_data.num_channels, header_data.sample_rate_hz };
    };

    if (num_channels > max_decode_channels) return error.ExceededMaxDecodeChannels;
    var buf: [max_decode_channels]Frame.LmsState = undefined;
    const lms_states = buf[0..num_channels];

    // This overshoots by a small amount depending on how many are in the final frame
    const estimated_total_samples = num_frames * max_slices * num_channels;
    var sample_list = try std.ArrayList(i16).initCapacity(alloc, estimated_total_samples);
    errdefer sample_list.deinit(alloc);

    for (0..num_frames) |_| {
        try Frame.decode(reader, lms_states, &sample_list);
    }

    return QOA{
        .num_samples = num_channels,
        .sample_rate_hz = sample_rate_hz,
        .data = try sample_list.toOwnedSlice(alloc),
    };
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
