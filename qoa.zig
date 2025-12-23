const std = @import("std");

pub const DecodeError = error{
    InvalidFileFormat,
    ReadFailed,
    EndOfStream,
    OutOfMemory,
};

const magic = "qoaf";
const endianess = std.builtin.Endian.big;
const dequant_tab = [_]f32{ 0.75, -0.75, 2.5, -2.5, 4.5, -4.5, 7, -7 };
const max_decode_channels = 8;
const num_samples_in_slice = 20;

inline fn dequant(scale_factor_quant: f32) f32 {
    return @round(std.math.pow(f32, scale_factor_quant + 1, 2.75));
}

/// A decoded qoa file
pub const QOA = struct {
    sample_rate: u32,
    channels: u32,
    /// `sample_count = QOA.samples.len / QOA.channels`
    samples: []i16,

    pub fn deinit(
        self: *QOA,
        alloc: std.mem.Allocator,
    ) void {
        alloc.free(self.samples);
    }
};

/// Wraps a standard Io.Reader for a qoa file and decodes and returns the sample slices of size 20
pub const QOASliceIter = struct {
    reader: *std.Io.Reader,
    lms_states: [max_decode_channels]LMSState,
    slice_no: u8,
    channel_no: u3,
    bytes_remaining_in_frame: i32,

    // some useful data for reencoding or using the data in some way
    sample_count: u32,
    sample_rate: u32,
    channels: u32,

    /// Returns the total samples the iterator will produce.
    /// NOTE: `QOAFrameIter.sample_count * QOAFrameIter.channels`.
    pub inline fn totalSamples(self: *const QOASliceIter) usize {
        return @as(usize, self.sample_count) * @as(usize, self.channels);
    }

    /// Returns some data about the file which can be stored by the caller ensure correctness for decoding and encoding.
    pub fn init(
        reader: *std.Io.Reader,
    ) error{ ReadFailed, EndOfStream, InvalidFileFormat }!QOASliceIter {
        const file_header = try reader.takeStruct(Header, endianess);
        if (!std.mem.eql(u8, magic, &file_header.magic)) return error.InvalidFileFormat;

        // Take one frame header (any valid qoa file must have at least one frame)
        const frame_header = try FrameHeader.peek(reader);

        if (frame_header.num_channels == 0 or
            frame_header.sample_rate == 0 or
            file_header.samples == 0)
        {
            return error.InvalidFileFormat;
        }

        return QOASliceIter{
            .reader = reader,
            .lms_states = undefined,
            .slice_no = 0,
            .channel_no = 0,
            .bytes_remaining_in_frame = 0,

            .sample_count = file_header.samples,
            .sample_rate = frame_header.sample_rate,
            .channels = frame_header.num_channels,
        };
    }

    /// Grabs the next slice and decodes them.
    ///
    /// This just reads the next slice
    pub fn next(
        self: *QOASliceIter,
    ) DecodeError!?[num_samples_in_slice]i16 {
        var samples: [num_samples_in_slice]i16 = undefined;
        const slice = (try self.nextSlice()) orelse return null;

        std.debug.print(
            "{:3} {:3}: {x}\n",
            .{ self.slice_no, self.channel_no, @as(u64, @bitCast(slice)) },
        );

        const sf: f32 = dequant(@floatFromInt(slice.scale_factor));
        inline for (0.., @typeInfo(Slice.Residuals).@"struct".fields) |i, field| {
            const qr: u3 = @field(slice.residuals, field.name);
            const r = @as(i16, @intFromFloat(@round(sf * dequant_tab[qr])));
            const s = r +| self.lms_states[self.channel_no].predict();

            samples[i] = s;

            self.lms_states[self.channel_no].update(r, s);
        }

        return samples;
    }

    fn nextSlice(
        self: *QOASliceIter,
    ) DecodeError!?Slice {
        if (self.bytes_remaining_in_frame <= 0) {
            // NOTE: This might not be 0 if the file was encoded incorrectly and the bytes in
            // the frame is not divisible by 8 (after parsing the header that is).
            std.debug.assert(self.bytes_remaining_in_frame == 0);
            self.nextFrame() catch |err| {
                // we must be at the end of the file.
                if (err == error.EndOfStream) return null;
                return err;
            };
        } else {
            // Assert that u3 actually overflow as expected

            if (self.channel_no == self.channels - 1) {
                self.channel_no = 0;
                self.slice_no +%= 1;
            } else {
                self.channel_no += 1;
            }
        }

        const slice = try Slice.take(self.reader);
        self.bytes_remaining_in_frame -= @sizeOf(@TypeOf(slice));

        return slice;
    }

    fn nextFrame(self: *QOASliceIter) DecodeError!void {
        const header = try FrameHeader.take(self.reader);

        if (header.num_channels != self.channels or
            header.sample_rate != self.sample_rate)
        {
            std.log.err(
                "Found invalid frame header:\n{any}\nExpected num_channels=={} and sample_rate=={}",
                .{ header, self.channel_no, self.sample_rate },
            );
            return error.InvalidFileFormat;
        }

        self.slice_no = 0;
        self.channel_no = 0;

        // Parse all the lms states from the file
        var lms_states: [max_decode_channels]LMSState = undefined;
        for (lms_states[0..header.num_channels]) |*lms_state| {
            lms_state.* = try .take(self.reader);
        }

        self.bytes_remaining_in_frame =
            @as(i32, header.size) -
            @sizeOf(FrameHeader) -
            @as(i32, header.num_channels) * @sizeOf(LMSState);
    }
};

pub const Header = extern struct {
    magic: [magic.len]u8,
    samples: u32,
};

/// This header is before each frame. All values expect `size` need to match frame to frame.
pub const FrameHeader = packed struct(u64) {
    num_channels: u8,
    /// In hertz
    sample_rate: u24,
    /// Samples per channel in this frame
    samples_per_channel: u16,
    /// Frame size (including this header)
    size: u16,

    inline fn take(
        reader: *std.Io.Reader,
    ) error{ ReadFailed, EndOfStream }!FrameHeader {
        return FrameHeader{
            .num_channels = try reader.takeByte(),
            .sample_rate = try reader.takeInt(u24, endianess),
            .samples_per_channel = try reader.takeInt(u16, endianess),
            .size = try reader.takeInt(u16, endianess),
        };
    }

    /// Does not modify the reader
    inline fn peek(
        reader: *std.Io.Reader,
    ) error{ ReadFailed, EndOfStream }!FrameHeader {
        const next_header_slice: *[8]u8 = try reader.peekArray(
            comptime @sizeOf(@typeInfo(FrameHeader).@"struct".backing_integer.?),
        );

        if (endianess != .big) @compileError("bruh");
        const btn = std.mem.bigToNative;

        return FrameHeader{
            .num_channels = next_header_slice[0],
            .sample_rate = btn(u24, @bitCast(next_header_slice[1..4].*)),
            .samples_per_channel = btn(u16, @bitCast(next_header_slice[4..6].*)),
            .size = btn(u16, @bitCast(next_header_slice[6..8].*)),
        };
    }
};

/// Parses bytes from reader into `QOA`.
pub fn fromReader(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
) DecodeError!QOA {
    var iter = try QOASliceIter.init(reader);
    const sample_buf = try alloc.alloc(i16, iter.totalSamples());
    errdefer alloc.free(sample_buf);

    var samples = std.ArrayList(i16).initBuffer(sample_buf);

    while (try iter.next()) |new_samples| {
        try samples.appendSliceBounded(&new_samples);
    }

    return QOA{
        .sample_rate = iter.sample_rate,
        .channels = iter.channels,
        .samples = sample_buf,
    };
}

const Slice = packed struct(u64) {
    scale_factor: u4,
    residuals: Residuals,

    const Residuals = packed struct(u60) {
        // zig fmt: off
            qr01: u3, qr02: u3, qr03: u3, qr04: u3,
            qr05: u3, qr06: u3, qr07: u3, qr08: u3,
            qr09: u3, qr10: u3, qr11: u3, qr12: u3,
            qr13: u3, qr14: u3, qr15: u3, qr16: u3,
            qr17: u3, qr18: u3, qr19: u3, qr20: u3,
            // zig fmt: on
    };

    inline fn take(
        reader: *std.Io.Reader,
    ) error{ ReadFailed, EndOfStream }!Slice {
        return @bitCast(try reader.takeInt(u64, endianess));
    }
};

const LMSState = extern struct {
    history: vec(i16),
    weights: vec(i16),

    inline fn take(
        reader: *std.Io.Reader,
    ) error{ ReadFailed, EndOfStream }!LMSState {
        return reader.takeStruct(LMSState, endianess);
    }

    fn vec(comptime T: type) type {
        return @Vector(4, T);
    }

    inline fn predict(self: LMSState) i16 {
        const prod = @as(vec(i32), self.history) * @as(vec(i32), self.weights);
        return @intCast(@reduce(.Add, prod) >> 13);
    }

    inline fn update(
        self: *LMSState,
        dequant_scaled_residual: i16,
        output_sample: i16,
    ) void {
        self.updateWeights(dequant_scaled_residual);
        self.updateHistory(output_sample);
    }

    inline fn updateWeights(
        self: *LMSState,
        dequant_scaled_residual: i16,
    ) void {
        const delta = dequant_scaled_residual >> 4;
        self.weights = @select(
            i16,
            self.history < @as(vec(i16), @splat(0)),
            @as(vec(i16), @splat(-delta)),
            @as(vec(i16), @splat(delta)),
        );
    }

    fn updateHistory(
        self: *LMSState,
        output_sample: i16,
    ) void {
        self.history = @shuffle(
            i16,
            self.history,
            @Vector(1, i16){output_sample},
            @Vector(4, i32){ 1, 2, 3, -1 },
        );
    }
};
