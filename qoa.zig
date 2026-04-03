const std = @import("std");
const assert = std.debug.assert;

pub const consts = @import("src/constants.zig");
pub const Frame = @import("src/Frame.zig");
pub const Header = @import("src/Header.zig");

test {
    std.testing.refAllDecls(@This());
}

// For most use cases I want to be able to feed samples to a sink. For qoa the
// logical design then is to have a structure which wraps `std.Io.Reader` and
// allows you to extract some number of samples at a time until the end of
// sound.
//
// You might want to read decode the whole file into memory to say, convert it
// to another file format or store it in this state. This should be function
// which takes in a reader and spits out all relevant data.
//
// TODO: Implement streaming mode.

const qoa = @This();

/// Iterates over the audio frames of a `qoa` file.
///
/// Can also be used to decode the entire audio stream into memory. See
/// `FrameIter.decodeRemaining`
pub const FrameIter = struct {
    reader: *std.Io.Reader,
    /// Total samples decoded from reader so far
    samples_decoded: u32,
    total_samples_per_channel: Header.SamplesPerChannel,

    const InitError = Header.DecodeError || Frame.Header.DecodeError;
    const DecodeError = error{ ExceededMaxDecodeChannels, ReadFailed, EndOfStream };

    /// NOTE: Reader must be at the start of the file.
    ///
    /// Initializes the iterator and returns the first frame header which will
    /// come in handy when decoding.
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
        assert(@intFromEnum(self.total_samples_per_channel) >= 1); // same as
        // above :)

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
        assert(@intFromEnum(self.total_samples_per_channel) >= 1); // same as
        // above :)

        const header = Frame.Header.decode(self.reader) catch |e| {
            if (e == error.EndOfStream) return &.{}; // This must be the end of
            // the file
            return e; // Else some nefarious error occurred.
        };

        // Initialize the lms states
        if (header.num_channels > consts.max_decode_channels) return error.ExceededMaxDecodeChannels;
        var lms: [consts.max_decode_channels]Frame.LmsState = undefined;
        for (lms[0..header.num_channels]) |*state| state.* = try .decode(self.reader);

        // Get sample output slice
        const samples = list.addManyAsSliceAssumeCapacity(header.frameSampleCount());

        try Frame.decodeSlices(self.reader, lms[0..header.num_channels], header.num_channels, samples);
        self.samples_decoded += header.frameSampleCount();

        return samples;
    }

    /// Decodes all the remaining frames and appends them to the array list.
    ///
    /// The reason this doesn't accept an allocator is because you should
    /// probably reserve `Iter.overestimateSamplesRemaining` extra samples.
    ///
    /// Returns the slice of decoded samples.
    ///
    /// The slice is empty if we are at the end of the stream.
    pub fn decodeRemaining(
        self: *FrameIter,
        list: *std.ArrayList(i16),
    ) DecodeError![]i16 {
        assert(self.total_samples_per_channel != .streaming);
        assert(@intFromEnum(self.total_samples_per_channel) >= 1); // same as
        // above :)

        var header = Frame.Header.peek(self.reader) catch |e| {
            if (e == error.EndOfStream) return &.{}; // This must be the end of
            // the file
            return e; // Else some nefarious error occurred.
        };

        // Create lms buf
        if (header.num_channels > consts.max_decode_channels) return error.ExceededMaxDecodeChannels;
        var lms_state_buf: [consts.max_decode_channels]Frame.LmsState = undefined;

        // Check that we have enough capacity to hold all the frames
        assert(list.capacity - list.items.len >= self.overestimateSamplesRemaining(header.num_channels));

        const num_frames_per_channel_remaining =
            (self.total_samples_per_channel.totalFramesPerChannel() orelse unreachable) -
            @divFloor(self.samples_decoded, consts.max_samples_per_frame);

        const new_samples_start_idx = list.items.len;

        for (0..num_frames_per_channel_remaining) |_| {
            // read the frame header
            header = try Frame.Header.decode(self.reader);

            // Decode the lms states
            const lms_states = lms_state_buf[0..header.num_channels];
            for (lms_states) |*lms| lms.* = try .decode(self.reader);

            // Get sample output slice
            const samples = list.addManyAsSliceAssumeCapacity(header.frameSampleCount());

            try Frame.decodeSlices(self.reader, lms_states, header.num_channels, samples);
            self.samples_decoded += header.frameSampleCount();
        }

        return list.items[new_samples_start_idx..];
    }

    /// NOTE: This will probably fail if the frame iter was initialized with a
    /// reader that has a shared buffer. This function copies the reader to each
    /// thread which means that they will overwrite each others data and cause
    /// all sorts of weirdness. I recommend `std.Io.Reader.fixed`.
    ///
    /// Decodes all the remaining frames and appends them to the array list.
    ///
    /// The reason this doesn't accept an allocator is because you should
    /// probably reserve `Iter.overestimateSamplesRemaining` extra samples.
    ///
    /// Returns the slice of decoded samples.
    ///
    /// The slice is empty if we are at the end of the stream.
    pub fn decodeRemainingMultiThread(
        self: *FrameIter,
        list: *std.ArrayList(i16),
        worker_thread_count: ?usize,
    ) DecodeError![]i16 {
        const file_header = try qoa.Header.decode(self.reader);

        // Calculate some info about the file
        const num_frames_per_channel_remaining =
            (self.total_samples_per_channel.totalFramesPerChannel() orelse
                @panic("Cannot decode via multithread if the total number of frames cannot be estimated")) -
            @divFloor(self.samples_decoded, consts.max_samples_per_frame);

        const header = Frame.Header.peek(self.reader) catch |e| {
            if (e == error.EndOfStream) return &.{}; // This must be the end of
            // the file
            return e; // Else some nefarious error occurred.
        };

        const num_workers = worker_thread_count orelse (std.Thread.getCpuCount() catch consts.fallback_num_workers);

        // Check that we have enough capacity to hold all the frames
        assert(list.capacity - list.items.len >= self.overestimateSamplesRemaining(file_header.num_channels));

        var thread_buffer: [consts.max_workers]std.Thread = undefined;
        if (num_workers > thread_buffer.len) return error.OutOfMemory;

        const sample_start = list.items.len;

        {
            const workers = thread_buffer[0..num_workers];
            try multithread.spawnWorkerThreads(
                workers,
                self.reader,
                header.num_channels,
                num_frames_per_channel_remaining,
                list,
            );
            for (workers) |worker| worker.join();
        }

        return list.items[sample_start..];
    }

    const multithread = struct {
        pub const Error = error{
            ExceededMaxDecodeChannels,
            InvalidFileFormat,
            OutOfMemory,

            /// When the decoder expected a file and finds a streamer then it
            /// can't decode as if it where decoding a file.
            ExpectedFileFoundStream,
        } || std.Io.Reader.Error;

        fn spawnWorkerThreads(
            workers: []std.Thread,
            reader: *std.Io.Reader,
            num_channels: u8,
            num_frames_per_channel_remaining: u32,
            sample_list: *std.ArrayList(i16),
        ) std.Thread.SpawnError!void {
            std.debug.assert(workers.len > 0);
            const frames_per_worker_per_channel = num_frames_per_channel_remaining / workers.len;
            var frames_per_worker_per_channel_remainder = num_frames_per_channel_remaining - workers.len * frames_per_worker_per_channel;

            const bytes_per_frame: usize =
                @sizeOf(qoa.Frame.Header) +
                @sizeOf(qoa.Frame.LmsState16) * @as(usize, num_channels) +
                @sizeOf(qoa.Frame.Slice) * @as(usize, num_channels) * consts.max_slices_per_frame;

            for (0..workers.len) |worker_id| {
                const add_one = @intFromBool(frames_per_worker_per_channel_remainder > 0);
                frames_per_worker_per_channel_remainder -= add_one;

                const samples_per_worker =
                    (frames_per_worker_per_channel + add_one) *
                    consts.max_slices_per_frame * consts.num_samples_in_slice * // ->
                    // max
                    // samples
                    // per frame
                    num_channels; // 1 i16 per channel -> total length of output
                // slice

                const output_slice = try sample_list.addManyAsSliceBounded(samples_per_worker);
                workers[worker_id] = try std.Thread.spawn(
                    .{ .allocator = null, .stack_size = consts.stack_size },
                    decodeFrames,
                    .{ worker_id, reader.*, frames_per_worker_per_channel, output_slice },
                );

                // I don't need to call toss on the final frame
                if (worker_id < workers.len - 1) {
                    reader.toss(frames_per_worker_per_channel * bytes_per_frame);
                }
            }
        }

        fn decodeFrames(
            worker_id: usize,
            initial_reader: std.Io.Reader,
            num_frames: usize,
            output_slice: []i16,
        ) Error!void {
            var reader = initial_reader;
            var lms_state_buf: [consts.max_decode_channels]qoa.Frame.LmsState = undefined;
            var list = std.ArrayList(i16).initBuffer(output_slice);

            for (0..num_frames) |frame_no| {
                // Read the frame header
                const header = try qoa.Frame.Header.decode(&reader);

                // Decode the lms states
                const lms_states = lms_state_buf[0..header.num_channels];
                for (lms_states) |*lms| lms.* = try .decode(&reader);

                // Get sample output slice
                const samples = list.addManyAsSliceAssumeCapacity(header.frameSampleCount());

                qoa.Frame.decodeSlices(&reader, lms_states, header.num_channels, samples) catch |e| {
                    std.log.scoped(.qoa_worker).err(
                        "(id={}) failed to decode frame {} with {} frames left: {s}",
                        .{ worker_id, frame_no, num_frames - frame_no, @errorName(e) },
                    );
                    return e;
                };
            }
        }
    };
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
    /// Allocator is used to allocate a buffer for the samples. Allocation is
    /// done once.
    ///
    /// Initializes the iterator and returns the first frame header which will
    /// come in handy when decoding.
    pub fn init(
        reader: std.Io.Reader,
        gpa: std.mem.Allocator,
    ) InitError!SampleIter {
        const frame_header, const frame_iter = try FrameIter.init(reader);

        // NOTE: as we are *not* in streaming mode, we can use the number of
        // samples in the first frame as the upper bound for samples in the
        // whole file.
        const buf = try gpa.alloc(i16, frame_header.frameSampleCount());

        return SampleIter.initFrameIter(frame_iter, buf);
    }

    pub fn initFrameIter(
        frame_iter: FrameIter,
        buf: []i16,
    ) SampleIter {
        return SampleIter{
            .frame_iter = frame_iter,
            .buf = buf,
            .buf_pos = 0,
            .buf_size = 0,
        };
    }

    pub fn deinit(self: SampleIter, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
    }

    pub fn take(self: *SampleIter) NextError!?i16 {
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

    /// Tries to read `size` into `self.buf`, returning the slice which is the
    /// closest size to `size` that it can achieve without rebasing.
    ///
    /// Returns an empty slice *only* when at the end of the stream!
    pub fn takeSlice(self: *SampleIter, size: usize) NextError![]i16 {
        // If we are at the end of the buffer, try advance
        if (self.buf_pos >= self.buf_size) {
            @branchHint(.unlikely);
            var list = std.ArrayList(i16).initBuffer(self.buf);
            const next_frame_samples = try self.frame_iter.nextFrame(&list);
            // If we have reached the end of the stream, return the empty buffer
            if (next_frame_samples.len == 0) return &.{};

            self.buf_size = @intCast(next_frame_samples.len);
            self.buf_pos = 0;
        }

        const contents = self.buf[self.buf_pos..self.buf_size];
        const advance_len: usize = @min(contents.len, size);

        if (advance_len + self.buf_pos > consts.max_samples_per_frame) unreachable;
        defer self.buf_pos += @intCast(advance_len);

        return self.buf[self.buf_pos .. self.buf_pos + advance_len];
    }
};

/// Walks over a decoded sound rather than an encoded one.
pub const StaticSampleIter = struct {
    sample_list: std.ArrayList(i16),

    /// Just an index into the `sample_list`. Can be modified directly to change
    /// the position of the sound
    pos: usize,

    pub const InitError = FrameIter.InitError || FrameIter.DecodeError || error{OutOfMemory};

    /// NOTE: Reader must be at the start of the file.
    ///
    /// Initializes the iterator and returns the first frame header which will
    /// come in handy when decoding.
    pub fn initPath(
        sub_path: []const u8,
        gpa: std.mem.Allocator,
    ) (std.fs.File.OpenError || InitError)!StaticSampleIter {
        const file = try std.fs.cwd().openFile(sub_path, .{});
        defer file.close();

        var iobuf: [1024]u8 = undefined;
        var reader = file.reader(&iobuf);

        return .initReader(&reader.interface, gpa);
    }

    /// NOTE: Reader must be at the start of the file.
    ///
    /// Initializes the iterator and returns the first frame header which will
    /// come in handy when decoding.
    pub fn initReader(
        reader: std.Io.Reader,
        gpa: std.mem.Allocator,
    ) InitError!StaticSampleIter {
        const frame_header, var frame_iter = try FrameIter.init(reader);

        const sample_list_size = frame_iter.overestimateSamplesRemaining(frame_header.num_channels);
        const buf = try gpa.alloc(i16, sample_list_size);

        return StaticSampleIter.initFrameIter(&frame_iter, buf);
    }

    /// Uses the frame iter to decode the rest of the samples into the buffer.
    ///
    /// See `FrameIter.overestimateSamplesRemaining` for the expected buffer
    /// size.
    pub fn initFrameIter(frame_iter: *FrameIter, buf: []i16) FrameIter.DecodeError!StaticSampleIter {
        var sample_list = std.ArrayList(i16).initBuffer(buf);
        try frame_iter.decodeRemaining(&sample_list);
        return StaticSampleIter{ .sample_list = sample_list, .pos = 0 };
    }

    pub fn deinit(self: StaticSampleIter, gpa: std.mem.Allocator) void {
        self.sample_list.deinit(gpa);
    }

    /// Tries to read `size` into `self.buf`, returning the slice which is the
    /// closest size to `size` that it can achieve without rebasing.
    ///
    /// Returns an empty slice *only* when at the end of the stream!
    pub fn takeSlice(self: *StaticSampleIter, size: usize) []i16 {
        if (self.pos >= self.sample_list.items.len) {
            @branchHint(.unlikely);
            return &.{};
        }

        const contents = self.sample_list.items[self.pos..];
        const advance_len: usize = @min(contents.len, size);
        std.debug.assert(advance_len > 0);

        defer self.pos += advance_len;
        return self.buf[self.pos .. self.pos + advance_len];
    }
};
