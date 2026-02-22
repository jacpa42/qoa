const std = @import("std");

const qoa = @This();

const log = std.log.scoped(.qoa);

const magic: [4]u8 = "qoaf".*;
const default_num_background = 7;
const max_decode_channels = 8;
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

pub const Header = extern struct {
    magic: [4]u8 = undefined,
    samples: Samples,

    pub const Samples = enum(u32) {
        streaming = 0,
        _,
    };

    pub const DecodeError = error{
        InvalidFileFormat,
        ReadFailed,
        EndOfStream,
    };

    pub fn decode(
        reader: *std.Io.Reader,
    ) Header.DecodeError!Header {
        var header: Header = @bitCast((try reader.takeArray(@sizeOf(Header))).*);

        if (@as(u32, @bitCast(header.magic)) !=
            @as(u32, @bitCast(magic)))
        {
            return error.InvalidFileFormat;
        }

        if (native_endian != .big) {
            header.samples = @enumFromInt(@byteSwap(@intFromEnum(header.samples)));
        }

        return header;
    }
};

pub const Frame = struct {
    pub const DecodeError = error{
        OutOfMemory,
        ReadFailed,
        EndOfStream,
        ExceededMaxDecodeChannels,
    };

    fn decode(
        reader: *std.Io.Reader,
        lms_state_buf: *[max_decode_channels]Frame.LmsState,
        sample_list: *std.ArrayList(i16),
    ) Frame.DecodeError!void {
        // read the frame header
        const header = try Frame.Header.decode(reader);

        // Decode the lms states
        const lms_states = lms_state_buf[0..header.num_channels];
        for (lms_states) |*lms| lms.* = try .decode(reader);

        var samples_computed: u32 = 0;
        const total_samples_in_frame =
            @as(u32, header.samples_per_channel) *
            @as(u32, header.num_channels);

        if ((sample_list.capacity - sample_list.items.len) < total_samples_in_frame) {
            log.err("I need {} bytes, I have {} bytes\n", .{
                total_samples_in_frame * 2,
                (sample_list.capacity - sample_list.items.len) * 2,
            });
            return error.OutOfMemory;
        }

        const samples = sample_list.addManyAsSliceAssumeCapacity(total_samples_in_frame);

        while (samples_computed < total_samples_in_frame) {
            // each frame we compute num_channels * num_samples_in_slice total samples
            defer samples_computed +=
                num_samples_in_slice *
                header.num_channels;

            for (0..header.num_channels) |channel_no| {
                var slice = try Slice.decode(reader);
                const sf_quant: u4 = @truncate(slice.data >> 60);
                slice.data <<= 4;

                var sample_index = samples_computed + channel_no;
                const slice_end = @min(
                    sample_index + num_samples_in_slice * header.num_channels,
                    total_samples_in_frame,
                );

                while (sample_index < slice_end) : (sample_index += header.num_channels) {
                    const predicted = lms_states[channel_no].predict();
                    const quantized: u3 = @truncate(slice.data >> 61);
                    const dequantized = @as(i32, dequant_tab[sf_quant][quantized]);
                    const reconstructed = clamp(predicted + dequantized);

                    samples[sample_index] = reconstructed;

                    slice.data <<= 3;
                    lms_states[channel_no].update(reconstructed, dequantized);
                }
            }
        }
    }

    pub const Header = packed struct(u64) {
        num_channels: u8,
        sample_rate_hz: u24,
        samples_per_channel: u16,
        frame_size: u16,

        pub const DecodeError = error{
            ReadFailed,
            EndOfStream,
            ExceededMaxDecodeChannels,
        };

        pub fn decode(
            reader: *std.Io.Reader,
        ) Frame.Header.DecodeError!Frame.Header {
            var header: Frame.Header =
                @bitCast((try reader.takeArray(@sizeOf(Frame.Header))).*);

            if (native_endian != .big) {
                std.mem.byteSwapAllFields(Frame.Header, &header);
            }

            if (header.num_channels > max_decode_channels) {
                @branchHint(.cold);
                return error.ExceededMaxDecodeChannels;
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

            if (header.num_channels > max_decode_channels) {
                @branchHint(.cold);
                return error.ExceededMaxDecodeChannels;
            }

            return header;
        }
    };

    const lms_len = 4;

    /// This is how lms is stored in the file
    pub const LmsState16 = extern struct {
        history: [lms_len]i16,
        weights: [lms_len]i16,

        comptime {
            if (@sizeOf(LmsState16) != lms_len * 2 * @sizeOf(i16)) {
                @compileError("There can't be padding in this struct!");
            }
        }
    };

    pub const LmsState = struct {
        history: @Vector(lms_len, i32),
        weights: @Vector(lms_len, i32),

        pub const DecodeError = error{ ReadFailed, EndOfStream };

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

        pub fn decode(
            reader: *std.Io.Reader,
        ) LmsState.DecodeError!LmsState {
            const t = try reader.takeStruct(LmsState16, .big);
            return .{ .history = t.history, .weights = t.weights };
        }
    };
};

pub const Slice = packed struct {
    data: u64,
    pub const DecodeError = error{ ReadFailed, EndOfStream };
    pub fn decode(reader: *std.Io.Reader) Slice.DecodeError!Slice {
        return @bitCast(try reader.takeInt(u64, .big));
    }
};

pub const DecodeError = error{
    EndOfStream,
    ExceededMaxDecodeChannels,
    InvalidFileFormat,
    OutOfMemory,
    ReadFailed,
};

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
        const F = packed struct(u32) { num_channels: u8, sample_rate_hz: u24 };
        var header_data: F = @bitCast((try reader.peekArray(@sizeOf(F))).*);
        if (native_endian != .big) {
            std.mem.byteSwapAllFields(F, &header_data);
        }
        break :blk .{ header_data.num_channels, header_data.sample_rate_hz };
    };

    const num_frames: usize = 1 + @divFloor(
        @as(usize, @intFromEnum(samples)) - 1,
        num_samples_in_slice * max_slices_per_frame,
    );

    if (num_channels > max_decode_channels) return error.ExceededMaxDecodeChannels;
    var lms_states: [max_decode_channels]Frame.LmsState = undefined;

    // This overshoots by a small amount depending on how many are in the final frame.
    // Means we never grow capacity and do at most 1 realloc.
    const estimated_total_samples =
        num_frames *
        max_slices_per_frame * // -> max slices
        num_samples_in_slice * // -> max samples per frame
        num_channels; // -> max total samples

    log.info(
        "Estimated memory: {:.4}MiB",
        .{@as(f32, @floatFromInt(estimated_total_samples * @sizeOf(i16))) / (1024 * 1024)},
    );

    var sample_list = try std.ArrayList(i16).initCapacity(alloc, estimated_total_samples);
    errdefer sample_list.deinit(alloc);

    for (0..num_frames) |_| {
        try Frame.decode(reader, &lms_states, &sample_list);
    }

    log.info(
        "Filled {:.3}% of arraylist ({:.4}MiB left)",
        .{
            @as(f32, @floatFromInt(100 * sample_list.items.len)) / @as(f32, @floatFromInt(sample_list.capacity)),
            @as(f32, @floatFromInt(
                (sample_list.capacity - sample_list.items.len) * @sizeOf(i16),
            )) / (1024 * 1024),
        },
    );

    return .{
        .num_channels = num_channels,
        .sample_rate_hz = sample_rate_hz,
        .samples = try sample_list.toOwnedSlice(alloc),
    };
}

// TODO: Multithreading should be possible. I can break up the work into `n` chunks as each frame is a fixed size once I know the number of channels (except the final one).
//
// Break the workload of n-1 of the chunks into some threads. Decode the final chunk on the main thread. Join. la di da.
// TODO: Figure out how many workers to create (might default to 4 or something idk need to test)
pub fn decodeSliceMultithread(
    alloc: std.mem.Allocator,
    data: []const u8,
) (DecodeError || std.Thread.SpawnError)!qoa {
    var reader = std.Io.Reader.fixed(data);
    const file_header = try Header.decode(&reader);
    const samples: u32 = switch (file_header.samples) {
        .streaming => @panic("TODO: Implement streaming decoder"),
        else => |samples| @intFromEnum(samples),
    };

    // Peek to get the next frame
    const header = try Frame.Header.peek(&reader);

    const num_frames: usize = 1 + @divFloor(
        samples - 1,
        num_samples_in_slice * max_slices_per_frame,
    );
    log.info("total frames in file {}\n", .{num_frames});

    // This overshoots by a small amount depending on how many are in the final frame.
    // Means we never grow capacity and do at most 1 realloc.
    const estimated_total_samples =
        num_frames *
        max_slices_per_frame * // -> max slices
        num_samples_in_slice * // -> max samples per frame
        header.num_channels; // -> max total samples

    const bytes_per_frame: usize =
        @sizeOf(Frame.Header) +
        @sizeOf(Frame.LmsState16) * @as(usize, header.num_channels) +
        @sizeOf(Slice) * @as(usize, header.num_channels) * max_slices_per_frame;

    const num_background = std.Thread.getCpuCount() catch |e| blk: {
        log.warn("Unable to query number of cpus: {s}", .{@errorName(e)});
        log.warn("Using default {}", .{default_num_background + 1});
        break :blk default_num_background;
    };
    const num_workers = 1 + num_background;
    var worker_threads = try alloc.alloc(std.Thread, num_background);
    defer alloc.free(worker_threads);
    var num_complete = std.atomic.Value(u8).init(0);

    var sample_list = try std.ArrayList(i16).initCapacity(alloc, estimated_total_samples);
    errdefer sample_list.deinit(alloc);

    std.debug.assert(num_workers > 0);
    const frames_per_worker = num_frames / num_workers;
    if (frames_per_worker > 0) for (0..worker_threads.len) |worker_id| {
        const samples_per_worker =
            frames_per_worker *
            max_slices_per_frame * num_samples_in_slice * // -> max samples per frame
            header.num_channels; // 1 i16 per channel -> total length of output slice
        const output_slice = try sample_list.addManyAsSliceBounded(samples_per_worker);

        worker_threads[worker_id] = try std.Thread.spawn(
            .{ .allocator = alloc, .stack_size = 512 * 1024 },
            decodeFrames,
            .{ worker_id, reader, frames_per_worker, &num_complete, output_slice },
        );

        reader.toss(frames_per_worker * bytes_per_frame);
    };

    // We still have a few frames left to decode which we do on the main thread
    {
        const num_frames_remaining = num_frames - (frames_per_worker * num_background);
        var lms_state_buf: [max_decode_channels]Frame.LmsState = undefined;
        for (0..num_frames_remaining) |frame_no| {
            Frame.decode(&reader, &lms_state_buf, &sample_list) catch |e| {
                std.log.scoped(.qoa_worker).info(
                    "(id=main) failed to decode frame {}: {s}",
                    .{ frame_no, @errorName(e) },
                );
                return e;
            };
        }
    }

    while (num_complete.load(.acquire) < num_background) {
        std.Thread.sleep(std.time.ns_per_ms / 2);
    }
    for (worker_threads) |worker| worker.join();

    return .{
        .num_channels = header.num_channels,
        .sample_rate_hz = header.sample_rate_hz,
        .samples = try sample_list.toOwnedSlice(alloc),
    };
}

fn decodeFrames(
    worker_id: usize,
    initial_reader: std.Io.Reader,
    num_frames: usize,
    incr_on_completion: *std.atomic.Value(u8),
    output_slice: []i16,
) DecodeError!void {
    defer _ = incr_on_completion.fetchAdd(1, .acq_rel);
    var reader = initial_reader;
    var lms_state_buf: [max_decode_channels]Frame.LmsState = undefined;
    var list = std.ArrayList(i16).initBuffer(output_slice);

    for (0..num_frames) |frame_no| {
        Frame.decode(&reader, &lms_state_buf, &list) catch |e| {
            std.log.scoped(.qoa_worker).err(
                "(id={}) failed to decode frame {} with {} frames left: {s}",
                .{ worker_id, frame_no, num_frames - frame_no, @errorName(e) },
            );
            return e;
        };
    }
}

pub fn deinit(
    self: qoa,
    alloc: std.mem.Allocator,
) void {
    alloc.free(self.samples);
}

const max = std.math.maxInt(i16);
const min = std.math.minInt(i16);
// Special clamp
pub fn clamp(v: i32) i16 {
    if (@as(u32, @bitCast(v + max + 1)) > 2 * max + 1) {
        @branchHint(.unlikely);
        return @intCast(std.math.clamp(v, min, max));
    }
    return @intCast(v);
}

test {
    std.testing.refAllDecls(@This());
}
