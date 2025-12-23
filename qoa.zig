const std = @import("std");

const magic = "qoaf";
const endianess = std.builtin.Endian.big;
const dequant_tab = [_]f32{ 0.75, -0.75, 2.5, -2.5, 4.5, -4.5, 7, -7 };
const max_decode_channels = 8;

inline fn dequant(scale_factor_quant: f32) f32 {
    return @round(std.math.pow(f32, scale_factor_quant + 1, 2.75));
}

/// A decoded qoa file
pub const QOA = struct {
    sample_rate: u32,
    channels: u32,

    samples: []i16,

    pub fn deinit(
        self: *QOA,
        alloc: std.mem.Allocator,
    ) void {
        alloc.free(self.samples);
    }
};

/// A decoded QOA file (raw pcm data)
pub const decode = struct {
    /// QOA file header
    pub const Header = extern struct {
        magic: [magic.len]u8,
        samples: u32,

        /// Returns the number of frames in this QOA file
        pub inline fn countFrames(self: Header) usize {
            return std.math.divCeil(u32, self.samples, 256 * 20) catch unreachable;
        }
    };

    pub const Frame = struct {
        /// This header is before each frame. All values expect `size` need to match frame to frame.
        pub const Header = packed struct(u64) {
            num_channels: u8,
            /// In hertz
            sample_rate: u24,
            /// Samples per channel in this frame
            samples_per_channel: u16,
            /// Frame size (including this header)
            size: u16,

            inline fn take(
                reader: *std.Io.Reader,
            ) error{ ReadFailed, EndOfStream }!Frame.Header {
                return Frame.Header{
                    .num_channels = try reader.takeByte(),
                    .sample_rate = try reader.takeInt(u24, endianess),
                    .samples_per_channel = try reader.takeInt(u16, endianess),
                    .size = try reader.takeInt(u16, endianess),
                };
            }

            // Checks that these frame headers match up for the decoder
            pub inline fn matches(
                self: Frame.Header,
                other: Frame.Header,
            ) bool {
                return self.num_channels == other.num_channels and self.sample_rate == other.sample_rate;
            }
        };
    };

    pub const Error = error{
        InvalidFileFormat,
        ReadFailed,
        EndOfStream,
        OutOfMemory,
        TooManyChannelsInFrame,
    };

    /// Parses bytes from reader into `QOA`.
    pub fn fromReader(
        alloc: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) Error!QOA {
        const file_header = try reader.takeStruct(Header, endianess);
        if (!std.mem.eql(u8, magic, &file_header.magic)) return error.InvalidFileFormat;

        std.debug.print("file header: {any}\n", .{file_header});

        // Peak a frame header (any valid qoa file must have at least one frame)
        var frame_header = try Frame.Header.take(reader);

        if (file_header.samples == 0) return error.InvalidFileFormat;
        if (frame_header.sample_rate == 0) return error.InvalidFileFormat;
        if (frame_header.num_channels == 0) return error.InvalidFileFormat;

        const total_samples = file_header.samples * frame_header.num_channels;

        var decoded_qoa_file = QOA{
            .samples = try alloc.alloc(i16, total_samples),
            .sample_rate = frame_header.sample_rate,
            .channels = frame_header.num_channels,
        };
        errdefer decoded_qoa_file.deinit(alloc);

        std.log.debug("decoded_qoa_file.samples.len {}", .{decoded_qoa_file.samples.len});
        std.log.debug("decoded_qoa_file.sample_rate {any}", .{decoded_qoa_file.sample_rate});
        std.log.debug("decoded_qoa_file.channels {any}", .{decoded_qoa_file.channels});

        var samples = std.ArrayList(i16).initBuffer(decoded_qoa_file.samples);
        frame: for (0..file_header.countFrames()) |_| {
            const finished = try frameSamplesFromReader(frame_header, &samples, reader);
            if (finished) break :frame;

            const next_frame_header = try Frame.Header.take(reader);
            if (!frame_header.matches(next_frame_header)) {
                return error.InvalidFileFormat;
            } else {
                frame_header = next_frame_header;
            }
        }

        std.debug.assert(samples.items.len == samples.capacity);
        std.debug.assert(samples.items.len == decoded_qoa_file.samples.len);

        return decoded_qoa_file;
    }

    /// Should be called once on a fresh reader on a *`QOA`* file (before `decodeFrameReader`!)
    pub fn headerFromReader(
        reader: *std.Io.Reader,
    ) Error!Header {
        const header = try reader.takeStruct(Header, endianess);
        if (!std.mem.eql(u8, magic, &header.magic)) return error.InvalidFileFormat;
        return header;
    }

    /// Grabs the samples from the reader.
    ///
    /// Does not check that header matches the previous header. Caller must check this before calling this function. (use `Frame.Header.matches` on the previous frame header)
    ///
    /// returns whether we reached the end of the file or not
    pub fn frameSamplesFromReader(
        header: Frame.Header,
        samples: *std.ArrayList(i16),
        reader: *std.Io.Reader,
    ) Error!bool {
        // Parse all the lms states from the file
        if (header.num_channels > max_decode_channels) return error.TooManyChannelsInFrame;
        var lms_states: [max_decode_channels]LMSState = undefined;
        for (lms_states[0..header.num_channels]) |*lms_state| {
            lms_state.* = try .take(reader);
        }

        for (0..256) |_| {
            for (0..header.num_channels) |channel| {
                // If we error here then this is the last frame.
                const slice = Slice.take(reader) catch |err| {
                    if (err == error.EndOfStream) return true;
                    return err;
                };

                const sf: f32 = dequant(@floatFromInt(slice.scale_factor));

                inline for (@typeInfo(Slice.Residuals).@"struct".fields) |field| {
                    const qr: u3 = @field(slice.residuals, field.name);
                    const r = @as(i16, @intFromFloat(@round(sf * dequant_tab[qr])));
                    const s = r +| lms_states[channel].predict();

                    samples.appendBounded(s) catch return true;

                    lms_states[channel].updateWeights(r);
                    lms_states[channel].updateHistory(s);
                }
            }
        }

        return false;
    }

    pub fn deinit(
        self: *decode,
        alloc: std.mem.Allocator,
    ) void {
        for (self.frames) |*frame| frame.deinit(alloc);
        alloc.free(self.frames);
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

        inline fn updateHistory(
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
};
