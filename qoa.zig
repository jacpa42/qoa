const std = @import("std");

/// A decoded QOA file (raw pcm data)
pub const decode = struct {
    header: Header,
    frames: []Frame,

    pub const Header = extern struct {
        magic: [magic.len]u8,
        samples: u32,

        fn take(
            reader: *std.Io.Reader,
        ) Error!Frame.Header {
            return Header{
                .magic = try reader.takeArray(magic.len),
                .samples = try reader.takeInt(u32, endianess),
            };
        }

        /// Returns the number of frames in this QOA file
        pub fn countFrames(self: Header) usize {
            return std.math.divCeil(u32, self.samples, 256 * 20) catch unreachable;
        }
    };

    /// A decoded frame. The header contains some information on the samples.
    pub const Frame = struct {
        header: Frame.Header,
        samples: std.ArrayList(i16),

        pub const Header = packed struct(u64) {
            num_channels: u8,
            /// In hertz
            sample_rate: u24,
            /// Samples per channel in this frame
            samples_per_channel: u16,
            /// Frame size (including this header)
            size: u16,

            fn take(
                reader: *std.Io.Reader,
            ) Error!Frame.Header {
                return Frame.Header{
                    .num_channels = try reader.takeByte(),
                    .sample_rate = try reader.takeInt(u24, endianess),
                    .samples_per_channel = try reader.takeInt(u16, endianess),
                    .size = try reader.takeInt(u16, endianess),
                };
            }
        };

        pub inline fn deinit(
            self: *Frame,
            alloc: std.mem.Allocator,
        ) void {
            self.samples.deinit(alloc);
        }
    };

    pub const Error = error{
        InvalidFileFormat,
        ReadFailed,
        EndOfStream,
        OutOfMemory,
    };

    /// Parses bytes from reader into `QOA`.
    pub fn fromReader(
        alloc: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) Error!decode {
        const header = try headerFromReader(reader);
        const fbuf = try alloc.alloc(Frame, header.countFrames());
        errdefer alloc.free(fbuf);

        var frames = std.ArrayList(Frame).initBuffer(fbuf);
        errdefer for (frames.items) |*initialized_frame| initialized_frame.deinit(alloc);

        for (0..fbuf.len) |_| {
            const next_frame = frameFromReader(alloc, reader) catch break;
            frames.appendAssumeCapacity(next_frame);
        }

        std.debug.assert(frames.items.len == frames.capacity);
        std.debug.assert(frames.capacity == fbuf.len);

        return decode{ .header = header, .frames = fbuf };
    }

    /// Should be called once on a fresh reader on a *`QOA`* file (before `decodeFrameReader`!)
    pub fn headerFromReader(
        reader: *std.Io.Reader,
    ) Error!Header {
        const header = try reader.takeStruct(Header, endianess);
        if (!std.mem.eql(u8, magic, &header.magic)) return error.InvalidFileFormat;
        return header;
    }

    /// Should be called after `decodeFrameReader` to extract a frame.
    ///
    /// `alloc`: Used to reallocate the dynamic array used to store the samples for this frame.
    /// `reader`: Source for bytes to decode.
    pub fn frameFromReader(
        alloc: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) Error!Frame {
        const header = try Frame.Header.take(reader);

        // Parse all the lms states from the file
        const max_buf_size = comptime std.math.maxInt(@TypeOf(header.num_channels)) + 1;
        if (max_buf_size > 256) @compileError("stack buf too large");

        // FIX: This buffer is ~4kb
        var buf: [max_buf_size]LMSState = undefined;
        var lms_states = std.ArrayList(LMSState).initBuffer(&buf);
        for (0..header.num_channels) |_| {
            const state = try reader.takeStruct(LMSState, endianess);
            lms_states.appendAssumeCapacity(state);
        }

        // PERF: Maybe put all the samples in the same buffer?
        const sample_count = @as(u32, header.samples_per_channel) * @as(u32, header.num_channels);
        var samples = try std.ArrayList(i16).initCapacity(alloc, sample_count);
        errdefer samples.deinit(alloc);

        outer: for (0..256) |_| {
            for (0..header.num_channels) |channel| {
                // If we break here then this is the last frame.
                // Calling this function again returns end of stream so that should be fine.
                //
                // TEST: This takeStruct might not be what I want
                const slice = reader.takeStruct(Slice, endianess) catch break :outer;
                const sf: f32 = dequant(@floatFromInt(slice.scale_factor));

                inline for (@typeInfo(Slice.Residuals).@"struct".fields) |field| {
                    const qr: u3 = @field(slice.residuals, field.name);
                    const r = @as(i16, @intFromFloat(@round(sf * dequant_tab[qr])));
                    const s = r +| lms_states.items[channel].predict();

                    try samples.append(alloc, s);

                    lms_states.items[channel].updateWeights(r);
                    lms_states.items[channel].updateHistory(s);
                }
            }
        }

        return Frame{ .header = header, .samples = samples };
    }

    pub fn deinit(
        self: *decode,
        alloc: std.mem.Allocator,
    ) void {
        for (self.frames) |*frame| frame.deinit(alloc);
        alloc.free(self.frames);
    }

    const magic = "qoaf";
    const endianess = std.builtin.Endian.big;
    const dequant_tab = [_]f32{ 0.75, -0.75, 2.5, -2.5, 4.5, -4.5, 7, -7 };

    inline fn dequant(scale_factor_quant: f32) f32 {
        return @round(std.math.pow(f32, scale_factor_quant + 1, 2.75));
    }

    const Slice = packed struct(u64) {
        scale_factor: u4,
        residuals: Residuals,

        // zig fmt: off
            const Residuals = packed struct(u60) {
                qr01: u3, qr02: u3, qr03: u3, qr04: u3,
                qr05: u3, qr06: u3, qr07: u3, qr08: u3,
                qr09: u3, qr10: u3, qr11: u3, qr12: u3,
                qr13: u3, qr14: u3, qr15: u3, qr16: u3,
                qr17: u3, qr18: u3, qr19: u3, qr20: u3,
            };
            // zig fmt: on
    };

    const LMSState = extern struct {
        history: vec(i16),
        weights: vec(i16),

        fn vec(comptime T: type) type {
            return @Vector(4, T);
        }

        inline fn predict(self: LMSState) i16 {
            const prod =
                @as(vec(i32), self.history) *
                @as(vec(i32), self.weights);
            return @truncate(@reduce(.Add, prod) >> 13);
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
