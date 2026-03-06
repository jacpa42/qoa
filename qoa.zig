const std = @import("std");
const consts = @import("src/constants.zig");
const assert = std.debug.assert;

pub const streaming = @import("src/streaming.zig");
pub const Frame = @import("src/Frame.zig");
pub const Header = @import("src/Header.zig");
pub const decode = @import("src/decode.zig");

test {
    std.testing.refAllDecls(@This());
}

// For most applications you want to be able to feed samples to a sink. For qoa the logical design then is to have a structure which wraps `std.Io.Reader` and allows you to extract some number of samples at a time until the end of sound.
//
// You might want to read decode the whole file into memory to say, convert it to another file format or store it in this state. This should be function which takes in a reader and spits out all relevant data.
//
// I will ignore streaming mode for now.

const qoa = @This();

pub const FrameIter = struct {
    reader: *std.Io.Reader,
    /// Total samples decoded from reader so far
    samples_decoded: u32,
    total_samples_per_channel: Header.SamplesPerChannel,

    const InitError = Header.DecodeError || Frame.Header.DecodeError;
    const DecodeError = error{ ExceededMaxDecodeChannels, ReadFailed, EndOfStream };

    /// NOTE: Reader must be at the start of the file.
    ///
    /// Initializes the iterator and returns the first frame header which will come in handy when decoding.
    pub fn init(reader: *std.Io.Reader) InitError!struct { Frame.Header, FrameIter } {
        const header = try Header.decode(reader);

        if (header.samples_per_channel == .streaming) {
            @panic("Streaming files is not supported at the moment :)");
        }

        const iter = FrameIter{
            .reader = reader,
            .samples_decoded = 0,
            .total_samples_per_channel = header.samples_per_channel,
        };
        const first_frame_header = try Frame.Header.peek(reader);

        return .{ first_frame_header, iter };
    }

    pub fn overestimateSamplesRemaining(self: *const FrameIter, num_channels: u8) usize {
        assert(self.total_samples_per_channel != .streaming);
        assert(@intFromEnum(self.total_samples_per_channel) >= 1); // same as above :)

        const total_frames_per_channel = self.total_samples_per_channel.totalFramesPerChannel() orelse unreachable;
        const overestimated_total_samples_in_whole_file =
            consts.overEstimateTotalSamples(num_channels, total_frames_per_channel);

        return overestimated_total_samples_in_whole_file -| self.samples_decoded;
    }

    /// Decodes a single frame and appends the samples to the array list.
    ///
    /// Returns the slice of decoded samples.
    ///
    /// The slice is empty if we are at the end of the stream.
    pub fn nextFrame(
        self: *FrameIter,
        list: *std.ArrayList(i16),
    ) DecodeError![]i16 {
        assert(self.total_samples_per_channel != .streaming);
        assert(@intFromEnum(self.total_samples_per_channel) >= 1); // same as above :)

        const header = Frame.Header.decode(self.reader) catch |e| {
            if (e == error.EndOfStream) return &.{}; // This must be the end of the file
            return e; // Else some nefarious error occurred.
        };

        // Initialize the lms states
        if (header.num_channels > consts.max_decode_channels) return error.ExceededMaxDecodeChannels;
        var lms: [consts.max_decode_channels]Frame.LmsState = undefined;
        for (lms[0..header.num_channels]) |*state| state.* = try .decode(self.reader);

        // Get sample output slice
        const num_samples_in_frame = header.frameSampleCount();
        const samples = list.addManyAsSliceAssumeCapacity(num_samples_in_frame);

        try Frame.decodeSlices(self.reader, lms[0..header.num_channels], header.num_channels, samples);
        self.samples_decoded += num_samples_in_frame;

        return samples;
    }

    /// Decodes all the remaining frames and appends them to the array list.
    ///
    /// The reason this doesn't accept an allocator is because you should probably reserve
    /// `Iter.overestimateSamplesRemaining` extra samples.
    ///
    /// Returns the slice of decoded samples.
    ///
    /// The slice is empty if we are at the end of the stream.
    pub fn decodeRemaining(
        self: *FrameIter,
        list: *std.ArrayList(i16),
    ) DecodeError![]i16 {
        assert(self.total_samples_per_channel != .streaming);
        assert(@intFromEnum(self.total_samples_per_channel) >= 1); // same as above :)

        var header = Frame.Header.peek(self.reader) catch |e| {
            if (e == error.EndOfStream) return &.{}; // This must be the end of the file
            return e; // Else some nefarious error occurred.
        };
        const num_frames_per_channel = self.total_samples_per_channel.totalFramesPerChannel() orelse unreachable;

        // Create lms buf
        if (header.num_channels > consts.max_decode_channels) return error.ExceededMaxDecodeChannels;
        var lms_state_buf: [consts.max_decode_channels]Frame.LmsState = undefined;

        // Check that we have enough capacity to hold all the frames
        assert(list.capacity - list.items.len >= self.overestimateSamplesRemaining(header.num_channels));

        const frames_decoded = @divFloor(self.samples_decoded, consts.max_samples_per_frame);
        const new_samples_start_idx = list.items.len;

        for (frames_decoded..num_frames_per_channel) |_| {
            // read the frame header
            header = try Frame.Header.decode(self.reader);

            defer self.samples_decoded += header.frameSampleCount();

            // Decode the lms states
            const lms_states = lms_state_buf[0..header.num_channels];
            for (lms_states) |*lms| lms.* = try .decode(self.reader);

            // Get sample output slice
            const samples = list.addManyAsSliceAssumeCapacity(header.frameSampleCount());

            try Frame.decodeSlices(self.reader, lms_states, header.num_channels, samples);
        }

        return list.items[new_samples_start_idx..];
    }
};

pub const SampleIter = struct {
    frame_iter: FrameIter,
    buf: []i16,
    buf_pos: u16, // See below for why this is u16
    buf_size: u16, // See below for why this is u16

    // Little comptime test :)
    comptime {
        if (consts.max_samples_per_frame > std.math.maxInt(@FieldType(SampleIter, "buf_pos"))) {
            @compileError(
                @typeName(@FieldType(SampleIter, "buf_pos")) ++
                    " cannot fit max buffer " ++
                    std.fmt.comptimePrint("{}", .{consts.max_samples_per_frame}),
            );
        }

        if (consts.max_samples_per_frame > std.math.maxInt(@FieldType(SampleIter, "buf_size"))) {
            @compileError(
                @typeName(@FieldType(SampleIter, "buf_pos")) ++
                    " cannot fit max buffer " ++
                    std.fmt.comptimePrint("{}", .{consts.max_samples_per_frame}),
            );
        }
    }

    pub const InitError = FrameIter.InitError || error{OutOfMemory};
    pub const NextError = FrameIter.DecodeError;

    /// NOTE: Reader must be at the start of the file.
    ///
    /// Initializes the iterator and returns the first frame header which will come in handy when decoding.
    pub fn init(
        reader: *std.Io.Reader,
        gpa: std.mem.Allocator,
    ) InitError!SampleIter {
        const frame_header, const frame_iter = try FrameIter.init(reader);

        // NOTE: as we are *not* in streaming mode, we can use the number of samples in the first frame as the upper bound for samples in the whole file.
        const buf = try gpa.alloc(i16, frame_header.frameSampleCount());

        return SampleIter{
            .frame_iter = frame_iter,
            .buf = buf,
            .buf_pos = 0,
            .buf_size = 0,
        };
    }

    pub fn next(self: *SampleIter) NextError!?i16 {
        if (self.buf_pos >= self.buf_size) {
            var list = std.ArrayList(i16).initBuffer(self.buf);
            const next_frame_samples = try self.frame_iter.nextFrame(&list);
            if (next_frame_samples.len == 0) return null;

            self.buf_size = @intCast(next_frame_samples.len);
            self.buf_pos = 0;
        }

        defer self.buf_pos += 1;
        return self.buf[self.buf_pos];
    }

    /// Reads samples until the slice is full or `EndOfStream`
    pub fn nextSlice(
        self: *SampleIter,
        output: []i16,
    ) (error{EndOfStream} || NextError)!void {
        var buffer = output;

        while (buffer.len > 0) {
            const contents = self.buf[self.buf_pos..self.buf_size];
            const copy_len = @min(buffer.len, contents.len);
            @memcpy(buffer[0..copy_len], contents[0..copy_len]);
            self.buf_pos += copy_len;

            if (buffer.len == copy_len) {
                @branchHint(.likely);
                return;
            } else { // Advance the frame position
                var list = std.ArrayList(i16).initBuffer(self.buf);
                const next_frame_samples = try self.frame_iter.nextFrame(&list);
                if (next_frame_samples.len == 0) return error.EndOfStream;

                buffer = buffer[copy_len..];
                self.buf_size = @intCast(next_frame_samples.len);
                self.buf_pos = 0;
            }
        }
    }
};
