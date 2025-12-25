const std = @import("std");

pub const DecodeError = error{
    InvalidFileFormat,
    ReadFailed,
    EndOfStream,
    OutOfMemory,
};

const magic = "qoaf";
const endianess = std.builtin.Endian.big;
const max_decode_channels = 8;
const num_samples_in_slice = 20;
const max_samples_in_frame = 256 * num_samples_in_slice * max_decode_channels;
const dequant_tab: [16][8]i16 = blk: {
    // PERF: Precompute the dequant tab for epic speedups :)
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

fn dequant(scale_factor_quant: u4) f32 {
    const scale_factor: f32 = @floatFromInt(@as(u8, scale_factor_quant) + 1);
    return @round(std.math.pow(f32, scale_factor, 2.75));
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
pub const Iter = struct {
    reader: *std.Io.Reader,
    decoded_sample_buffer: [num_samples_in_slice]i16,
    lms_states: [max_decode_channels]LMSState,
    slice_no: u8,
    channel_no: u8,
    samples_remaining_in_frame: i32,

    // Some useful data for reencoding or using the data in some way

    sample_count: u32,
    sample_rate: u24,
    channel_count: u8,

    /// Returns the total 16bit samples the iterator will produce.
    pub fn totalSamples(self: *const Iter) usize {
        return @as(usize, self.sample_count) * @as(usize, self.channel_count);
    }

    /// Returns some data about the file which can be stored by the caller ensure correctness for decoding and encoding.
    /// Retains a pointer to the reader.
    pub fn init(
        reader: *std.Io.Reader,
    ) error{ ReadFailed, EndOfStream, InvalidFileFormat }!Iter {
        const file_header = try reader.takeStruct(Header, endianess);
        if (!std.mem.eql(u8, magic, &file_header.magic)) return error.InvalidFileFormat;

        // Take one frame header (any valid qoa file must have at least one frame)
        const frame_header = try FrameHeader.peek(reader);

        if (frame_header.channel_count == 0 or
            frame_header.sample_rate == 0 or
            file_header.samples == 0)
        {
            return error.InvalidFileFormat;
        }

        std.log.info("QOA iter size   {}b align={}", .{ @sizeOf(Iter), @alignOf(Iter) });
        std.log.info("QOA samples     {}", .{file_header.samples});
        std.log.info("QOA sample rate {}", .{frame_header.sample_rate});
        std.log.info("QOA channels    {}", .{frame_header.channel_count});

        return Iter{
            .reader = reader,
            .decoded_sample_buffer = @splat(0),
            .lms_states = @splat(.{}),
            .slice_no = 0,
            .channel_no = 0,
            .samples_remaining_in_frame = 0,

            .sample_count = file_header.samples,
            .sample_rate = frame_header.sample_rate,
            .channel_count = frame_header.channel_count,
        };
    }

    /// Grabs the next slice and decodes it.
    ///
    /// NOTE: For the last slice in the file, it might contain some zeroed out samples.
    pub fn next(
        self: *Iter,
    ) DecodeError!?[]i16 {
        var slice = (try self.nextSlice()) orelse return null;
        const lms = &self.lms_states[self.channel_no];

        decodeSlice(&slice, lms, &self.decoded_sample_buffer);

        if (self.samples_remaining_in_frame >= 0) {
            @branchHint(.likely);
            return &self.decoded_sample_buffer;
        } else {
            const valid_sample_len = self.samples_remaining_in_frame + num_samples_in_slice;

            std.debug.assert(0 < valid_sample_len);
            std.debug.assert(valid_sample_len < self.decoded_sample_buffer.len);

            return self.decoded_sample_buffer[0..@as(usize, @intCast(valid_sample_len))];
        }
    }

    fn nextSlice(
        self: *Iter,
    ) DecodeError!?u64 {
        if (self.samples_remaining_in_frame < 0) {
            return null;
        } else if (self.samples_remaining_in_frame == 0) {
            const byte_stream_finished = try self.nextFrame();
            if (byte_stream_finished) return null;
        } else {
            if (self.channel_no == self.channel_count - 1) {
                self.channel_no = 0;
                self.slice_no +%= 1;
            } else {
                self.channel_no += 1;
            }
        }

        const slice = try self.reader.takeInt(u64, endianess);
        self.samples_remaining_in_frame -= num_samples_in_slice;

        return slice;
    }

    const StreamFinished = bool;

    fn nextFrame(
        self: *Iter,
    ) error{
        ReadFailed,
        EndOfStream,
        InvalidFileFormat,
    }!StreamFinished {
        const header = FrameHeader.take(self.reader) catch |err| {
            if (err == error.EndOfStream) return true else return err;
        };

        if (header.channel_count != self.channel_count or
            header.sample_rate != self.sample_rate)
        {
            std.log.err(
                \\Found invalid frame header: {any}
                \\Expected num_channels=={} and sample_rate=={}
            ,
                .{ header, self.channel_no, self.sample_rate },
            );
            return error.InvalidFileFormat;
        }

        for (0..self.channel_count) |i| {
            self.lms_states[i] = try .take(self.reader);
        }

        const Int = @TypeOf(self.samples_remaining_in_frame);
        if (max_samples_in_frame > std.math.maxInt(Int) or
            max_samples_in_frame < std.math.minInt(Int))
        {
            @compileError("Casting num samples might overflow for " ++ @typeName(Int));
        }

        const total_samples = std.math.mulWide(u16, header.samples_per_channel, header.channel_count);
        if (total_samples > max_samples_in_frame) {
            std.debug.panic("sample per channel is too wide: {}", .{total_samples});
        }

        self.samples_remaining_in_frame = @as(Int, header.samples_per_channel) * header.channel_count;
        self.slice_no = 0;
        self.channel_no = 0;

        return false;
    }
};

pub const Header = extern struct {
    magic: [magic.len]u8,
    samples: u32,
};

/// This header is before each frame. All values expect `size` need to match frame to frame.
pub const FrameHeader = packed struct(u64) {
    channel_count: u8,
    /// In hertz
    sample_rate: u24,
    /// Samples per channel in this frame
    samples_per_channel: u16,
    /// Frame size (including this header)
    size: u16,

    const backing_size = @sizeOf(@typeInfo(FrameHeader).@"struct".backing_integer.?);

    fn take(
        reader: *std.Io.Reader,
    ) error{ ReadFailed, EndOfStream }!FrameHeader {
        const next_header_slice: [8]u8 = (try reader.takeArray(backing_size)).*;
        return .fromBytes(next_header_slice);
    }

    fn peek(
        reader: *std.Io.Reader,
    ) error{ ReadFailed, EndOfStream }!FrameHeader {
        const next_header_slice: [8]u8 = (try reader.peekArray(backing_size)).*;
        return .fromBytes(next_header_slice);
    }

    fn fromBytes(bytes: [8]u8) FrameHeader {
        if (endianess != .big) @compileError("bruh");
        const btn = std.mem.bigToNative;

        return FrameHeader{
            .channel_count = bytes[0],
            .sample_rate = btn(u24, @bitCast(bytes[1..4].*)),
            .samples_per_channel = btn(u16, @bitCast(bytes[4..6].*)),
            .size = btn(u16, @bitCast(bytes[6..8].*)),
        };
    }
};

/// Parses bytes from reader into `QOA`.
///
/// Contains at most 19 invalid samples (which are zeroed out according to the spec);
pub fn fromReader(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
) DecodeError!QOA {
    var iter = try Iter.init(reader);
    const sample_buf = try alloc.alloc(i16, iter.totalSamples());
    errdefer alloc.free(sample_buf);

    std.log.err(
        "sizeof iterator size={} (bytes) align={}",
        .{ @sizeOf(Iter), @alignOf(Iter) },
    );

    var samples = std.ArrayList(i16).initBuffer(sample_buf);

    while (try iter.next()) |new_samples| {
        try samples.appendSliceBounded(new_samples);
    }

    std.debug.assert(samples.capacity == samples.items.len);

    return QOA{
        .sample_rate = iter.sample_rate,
        .channels = iter.channel_count,
        .samples = sample_buf,
    };
}

const LMSState = struct {
    history: @Vector(4, i32) = zero,
    weights: @Vector(4, i32) = zero,

    const zero: @Vector(4, i32) = @splat(0);

    fn take(
        reader: *std.Io.Reader,
    ) error{ ReadFailed, EndOfStream }!LMSState {
        const LMSStateEncoded = extern struct {
            history: [4]i16,
            weights: [4]i16,
        };
        const lms = try reader.takeStruct(LMSStateEncoded, endianess);

        return .{
            .history = @as(@Vector(4, i32), lms.history),
            .weights = @as(@Vector(4, i32), lms.weights),
        };
    }

    fn predict(self: LMSState) i32 {
        return @reduce(.Add, self.history *% self.weights) >> 13;
    }

    fn update(
        self: *LMSState,
        dequantized: i32,
        reconstructed: i16,
    ) void {
        const dlta: @Vector(4, i32) = @splat(dequantized >> 4);
        self.weights = @select(
            i32,
            self.history < zero,
            self.weights - dlta,
            self.weights + dlta,
        );

        self.history = @shuffle(
            i32,
            self.history,
            @Vector(1, i32){reconstructed},
            @Vector(4, i32){ 1, 2, 3, -1 },
        );
    }
};

fn clamp(value: i32) i16 {
    const u16max = std.math.maxInt(u16);
    const i16max = std.math.maxInt(i16);
    const i16min = std.math.minInt(i16);

    std.debug.assert(value < std.math.maxInt(@TypeOf(value)) - i16max);

    // NOTE: this check is the same as checking that the value is out of range
    // for an i16:
    // 1. When value < i16min then the bitcast for value + i16max underflows and thus is > u16max
    // 2. When value > i16max then value + i16max > 2*i16max and u16max=2*i16max
    if (@as(u32, @bitCast((value + i16max))) > u16max) {
        @branchHint(.unlikely);
        if (value < i16min) return i16min;
        if (value > i16max) return i16max;
    }

    return @intCast(value);
}

/// Requires the buffer to have size at of at least `20`.
/// NOTE: Always overwrites the entire `sample_buf`.
pub fn decodeSlice(
    slice: *u64,
    lms: *LMSState,
    sample_buf: *[num_samples_in_slice]i16,
) void {
    const sf: u4 = @truncate(slice.* >> 60);
    slice.* <<= @bitSizeOf(@TypeOf(sf));

    // PERF: Inline? needs a test
    for (0..num_samples_in_slice) |i| {
        const qr: u3 = @truncate(slice.* >> 61);
        const dequantized = dequant_tab[sf][qr];
        const predicted = lms.predict();
        const reconstructed = clamp(dequantized + predicted);

        sample_buf[i] = reconstructed;
        slice.* <<= @bitSizeOf(@TypeOf(qr));
        lms.update(dequantized, reconstructed);
    }
}
