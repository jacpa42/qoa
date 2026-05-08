const std = @import("std");
const consts = @import("constants.zig");

pub const DecodeError = error{
    OutOfMemory,
    ReadFailed,
    EndOfStream,
    ExceededMaxDecodeChannels,
};

const Frame = @This();

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

/// Called after decoding the header and LmsStates
pub fn decodeSlices(
    reader: *std.Io.Reader,
    lms_states: []LmsState,
    num_channels: u8,
    samples: []i16,
) Slice.DecodeError!void {
    var samples_computed: u32 = 0;
    const values_per_slice = consts.num_samples_in_slice * num_channels;

    while (samples_computed < samples.len) {
        // each frame we compute num_channels * num_samples_in_slice total samples
        defer samples_computed += values_per_slice;

        for (0..num_channels) |channel_no| {
            var slice = try Slice.take(reader);
            const sf_quant: u4 = @truncate(slice.data >> 60);
            slice.data <<= 4;

            var sample_index = samples_computed + channel_no;
            const slice_end = @min(sample_index + values_per_slice, samples.len);

            while (sample_index < slice_end) : (sample_index += num_channels) {
                const predicted = lms_states[channel_no].predict();
                const quantized: u3 = @truncate(slice.data >> 61);
                const dequantized = @as(i32, dequant_tab[sf_quant][quantized]);
                const reconstructed = consts.clamp(predicted + dequantized);

                samples[sample_index] = reconstructed;

                slice.data <<= 3;
                lms_states[channel_no].update(reconstructed, dequantized);
            }
        }
    }
}

pub const Slice = packed struct {
    data: u64,

    pub const DecodeError = error{ ReadFailed, EndOfStream };
    pub fn take(reader: *std.Io.Reader) Slice.DecodeError!Slice {
        return @bitCast(try reader.takeInt(u64, consts.encode_endian));
    }
};

pub const Header = packed struct(u64) {
    num_channels: u8,
    sample_rate_hz: u24,
    samples_per_channel: u16,
    frame_size: u16,

    pub const DecodeError = error{
        ReadFailed,
        EndOfStream,
    };

    pub fn take(reader: *std.Io.Reader) Header.DecodeError!Header {
        var header: Header = @bitCast((try reader.takeArray(@sizeOf(Header))).*);
        maybeByteSwap(&header);
        return header;
    }

    pub fn peek(reader: *std.Io.Reader) Header.DecodeError!Header {
        var header: Header = @bitCast((try reader.peekArray(@sizeOf(Header))).*);
        maybeByteSwap(&header);
        return header;
    }

    pub inline fn maybeByteSwap(header: *Header) void {
        if (consts.native_endian != consts.encode_endian) {
            header.sample_rate_hz = @byteSwap(header.sample_rate_hz);
            header.samples_per_channel = @byteSwap(header.samples_per_channel);
            header.frame_size = @byteSwap(header.frame_size);
        }
    }

    /// Gets the size of the buffer required to allocate all the samples for the frame
    pub fn frameSampleCount(self: Header) u16 {
        const num_samples_per_frame = self.samples_per_channel * self.num_channels;
        std.debug.assert(num_samples_per_frame < consts.max_samples_per_frame);
        return num_samples_per_frame;
    }
};

const lms_len = 4;

/// This is how lms is stored in the file
pub const LmsState16 = extern struct {
    history: [lms_len]i16,
    weights: [lms_len]i16,
};

pub const LmsState = struct {
    history: @Vector(lms_len, i32),
    weights: @Vector(lms_len, i32),

    pub const DecodeError = error{ ReadFailed, EndOfStream };

    comptime {
        if (@sizeOf(LmsState16) != lms_len * 2 * @sizeOf(i16)) {
            @compileError("There can't be padding in the" ++ @typeName(LmsState16) ++ "struct!");
        }
    }

    pub fn update(
        self: *LmsState,
        reconstructed_sample: i32,
        dequantized_residual: i32,
    ) void {
        const V = @Vector(lms_len, i32);

        const delta = dequantized_residual >> 4;
        self.weights +%= @select(
            i32,
            self.history < @as(V, @splat(0)),
            @as(V, @splat(-delta)),
            @as(V, @splat(delta)),
        );

        self.history = @shuffle(
            i32,
            self.history,
            @Vector(1, i32){reconstructed_sample},
            @TypeOf(self.history){ 1, 2, 3, -1 },
        );
    }

    pub fn predict(self: LmsState) i32 {
        return @reduce(.Add, self.history *% self.weights) >> 13;
    }

    pub fn take(reader: *std.Io.Reader) LmsState.DecodeError!LmsState {
        const t = try reader.takeStruct(LmsState16, consts.encode_endian);
        return .{ .history = t.history, .weights = t.weights };
    }
};
