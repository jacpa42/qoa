const std = @import("std");
const qoa = @import("../qoa.zig");
const consts = @import("constants.zig");
const Header = @import("Header.zig");
const Frame = @import("Frame.zig");

pub const Stream = union(enum) {
    fixed: Fixed,
    variable: Variable,
};

/// This is a streamer which has an known number of channels and samples per channel each frame. Used when reading a file/slice in streaming mode.
pub const Fixed = struct {
    /// Reader for the source bytes
    reader: std.Io.Reader,

    num_channels: u8,
    sample_rate_hz: u24,
    /// We know exactly the size of each frame, so when initializing we allocate once.
    frame_samples: []i16,

    pub const Error = error{
        /// Returned when we expected to find a frame with the same number
        /// of channels and the same sample rate in a frame, but didn't.
        InvalidFileFormat,
        ReadFailed,
        ExceededMaxDecodeChannels,
    } || std.Io.Reader.Error;

    /// Memory for qoa_file_bytes is externally managed
    pub fn init(
        gpa: std.mem.Allocator,
        qoa_file_bytes: []const u8,
    ) (Error || error{OutOfMemory})!Fixed {
        var reader = std.Io.Reader.fixed(qoa_file_bytes);
        const header = try Header.decode(&reader);
        if (header.samples_per_channel == .streaming) return error.InvalidFileFormat;

        const frame_header = try Frame.Header.peek(&reader);
        const frame_samples = try gpa.alloc(i16, frame_header.frameSampleCount());
        return .{
            .num_channels = frame_header.num_channels,
            .sample_rate_hz = frame_header.sample_rate_hz,
            .reader = reader,
            .frame_samples = frame_samples,
        };
    }

    pub fn deinit(
        self: *Fixed,
        gpa: std.mem.Allocator,
    ) void {
        gpa.free(self.frame_samples);
    }

    /// Decodes and returns the next frame samples.
    pub fn next(self: *Fixed) Error!?[]i16 {
        // No header means we are done with the stream?
        const header = Frame.Header.decode(&self.reader) catch |e| {
            if (e == error.EndOfStream) return null else return e;
        };

        if (header.num_channels > consts.max_decode_channels) return error.ExceededMaxDecodeChannels;
        var lms_state_buf: [consts.max_decode_channels]Frame.LmsState = undefined;

        // Decode the lms states
        const lms_states = lms_state_buf[0..header.num_channels];
        for (lms_states) |*lms| lms.* = try .decode(&self.reader);

        // Get sample output slice
        const num_samples = header.frameSampleCount();
        if (num_samples > self.frame_samples.len or
            header.num_channels != self.num_channels or
            header.sample_rate_hz != self.sample_rate_hz)
            return error.InvalidFileFormat;

        const frame_samples = self.frame_samples[0..num_samples];
        try Frame.decodeSlices(&self.reader, lms_states, header.num_channels, frame_samples);

        return frame_samples;
    }
};

/// This is a streamer which has an unknown number of channels and samples per channel each frame.
pub const Variable = struct {
    /// Where we pull data from to stream
    src: std.Io.Reader,

    /// We decode a frame at a time. The decoded samples from the frame live here
    frame_samples: std.ArrayList(i16),

    pub const Error = error{
        OutOfMemory,
        ReadFailed,
        ExceededMaxDecodeChannels,
    };

    /// NOTE: The reader must be at the start of the first frame!
    /// i.e. it must have just read the file header
    pub fn init(
        reader: std.Io.Reader,
    ) Variable {
        return .{ .src = reader, .frame_samples = .empty };
    }

    pub fn deinit(
        self: *Variable,
        gpa: std.mem.Allocator,
    ) void {
        self.frame_samples.deinit(gpa);
    }

    /// Decodes the next slice returning the slice of the next samples.
    ///
    /// The sound lasts until this is called again.
    pub fn next(
        self: *Variable,
        gpa: std.mem.Allocator,
    ) Error!qoa {
        // No header means we are done with the stream?
        const header = Frame.Header.decode(self.src) catch |e| {
            if (e == error.EndOfStream) return null else return e;
        };

        if (header.num_channels > consts.max_decode_channels) return error.ExceededMaxDecodeChannels;
        var lms_state_buf: [consts.max_decode_channels]Frame.LmsState = undefined;

        // Decode the lms states
        const lms_states = lms_state_buf[0..header.num_channels];
        for (lms_states) |*lms| lms.* = try .decode(self.src);

        // Get sample output slice
        try self.frame_samples.resize(gpa, header.frameSampleCount());
        try Frame.decodeSlices(self.src, lms_states, header.num_channels, self.frame_samples.items);

        return qoa{
            .num_channels = header.num_channels,
            .sample_rate_hz = header.sample_rate_hz,
            .sample_list = self.frame_samples,
        };
    }
};
