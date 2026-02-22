const std = @import("std");

const qoa = @This();

const log = std.log.scoped(.qoa);

const stack_size = 64 * 1024;
const default_num_workers = 8;
const native_endian = @import("builtin").cpu.arch.endian();

const magic: [4]u8 = "qoaf".*;
const max_decode_channels = 8;
const max_slices_per_frame = 256;
const num_samples_in_slice = 20;
const max_samples_in_frame = max_slices_per_frame * num_samples_in_slice * max_decode_channels;
const dequant_tab: [16][8]i16 = blk: {
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
sample_list: std.ArrayList(i16),

pub const Header = extern struct {
    magic: [4]u8,
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

    /// Called after decoding the header and LmsStates
    pub fn decodeSlices(
        reader: *std.Io.Reader,
        lms_states: []Frame.LmsState,
        num_channels: u8,
        samples: []i16,
    ) Frame.Slice.DecodeError!void {
        var samples_computed: u32 = 0;
        const values_per_slice = num_samples_in_slice * num_channels;

        while (samples_computed < samples.len) {
            // each frame we compute num_channels * num_samples_in_slice total samples
            defer samples_computed += values_per_slice;

            for (0..num_channels) |channel_no| {
                var slice = try Slice.decode(reader);
                const sf_quant: u4 = @truncate(slice.data >> 60);
                slice.data <<= 4;

                var sample_index = samples_computed + channel_no;
                const slice_end = @min(sample_index + values_per_slice, samples.len);

                while (sample_index < slice_end) : (sample_index += num_channels) {
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

    pub const Slice = packed struct {
        data: u64,
        pub const DecodeError = error{ ReadFailed, EndOfStream };
        pub fn decode(reader: *std.Io.Reader) Slice.DecodeError!Slice {
            return @bitCast(try reader.takeInt(u64, .big));
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

        /// Gets the size of the buffer required to allocate all the samples for the frame
        fn getSampleSlice(frame_header: Frame.Header) usize {
            return @as(usize, frame_header.samples_per_channel) * @as(usize, frame_header.num_channels);
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

pub const DecodeError = error{
    EndOfStream,
    ExceededMaxDecodeChannels,
    InvalidFileFormat,
    OutOfMemory,
    ReadFailed,
};

/// Decodes directly from the file reader allocating once only for the sample data
pub fn decodeFilePath(
    alloc: std.mem.Allocator,
    sub_path: [:0]const u8,
) (DecodeError || std.fs.File.OpenError)!qoa {
    var file = try std.fs.cwd().openFile(sub_path, .{});
    var iobuf: [1024]u8 = undefined;
    var reader = file.reader(&iobuf);
    return decodeReader(alloc, &reader.interface);
}

const DecodeFilePathMultithreadError = DecodeError || std.fs.File.OpenError || std.Io.Reader.LimitedAllocError || std.Thread.SpawnError;

/// Loads the whole file into memory and then decodes it via using a couple workers
pub fn decodeFilePathMultithread(
    alloc: std.mem.Allocator,
    sub_path: [:0]const u8,
    worker_thread_count: ?usize,
) DecodeFilePathMultithreadError!qoa {
    var file = try std.fs.cwd().openFile(sub_path, .{});
    var iobuf: [1024]u8 = undefined;
    var reader = file.reader(&iobuf);

    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    try reader.interface.appendRemaining(alloc, &list, .unlimited);

    return decodeSliceMultithread(alloc, list.items, worker_thread_count);
}

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
    num_samples: Header.Samples,
) DecodeError!qoa {
    std.debug.assert(num_samples != .streaming);
    std.debug.assert(@as(usize, @intFromEnum(num_samples)) >= 1); // same as above :)

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
        @as(usize, @intFromEnum(num_samples)) - 1,
        num_samples_in_slice * max_slices_per_frame,
    );

    if (num_channels > max_decode_channels) return error.ExceededMaxDecodeChannels;
    var lms_state_buf: [max_decode_channels]Frame.LmsState = undefined;

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
        // read the frame header
        const header = try Frame.Header.decode(reader);

        // Decode the lms states
        const lms_states = lms_state_buf[0..header.num_channels];
        for (lms_states) |*lms| lms.* = try .decode(reader);

        // Get sample output slice
        const frame_sample_count = header.getSampleSlice();
        const samples = try sample_list.addManyAsSliceBounded(frame_sample_count);

        try Frame.decodeSlices(reader, lms_states, header.num_channels, samples);
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
        .sample_list = sample_list,
    };
}

/// pass `worker_thread_count` as `null` to try to use all cpu cores
pub fn decodeSliceMultithread(
    alloc: std.mem.Allocator,
    data: []const u8,
    worker_thread_count: ?usize,
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
        @sizeOf(Frame.Slice) * @as(usize, header.num_channels) * max_slices_per_frame;

    const num_workers: usize = blk: {
        const num_workers = worker_thread_count orelse std.Thread.getCpuCount() catch |e| {
            log.warn("Unable to query number of cpus: {s}", .{@errorName(e)});
            log.warn("Using default {}", .{default_num_workers});
            comptime if (default_num_workers <= 0) @compileError("default_num_workers must be > 0");
            break :blk default_num_workers;
        };
        break :blk @max(num_workers, 1);
    };

    var thread_buffer: [512]std.Thread = undefined;
    if (num_workers > thread_buffer.len) return error.OutOfMemory;
    var worker_threads = thread_buffer[0..num_workers];

    var sample_list = try std.ArrayList(i16).initCapacity(alloc, estimated_total_samples);
    errdefer sample_list.deinit(alloc);

    std.debug.assert(num_workers > 0);
    const frames_per_worker = num_frames / num_workers;
    var frames_per_worker_remainder = num_frames - num_workers * frames_per_worker;

    log.info("total frames in file {}", .{num_frames});
    log.info("total memory per thread ~{:.2}KiB", .{@as(f32, @floatFromInt((bytes_per_frame * frames_per_worker))) / 1024});

    for (0..worker_threads.len) |worker_id| {
        const add_one = @intFromBool(frames_per_worker_remainder == 0);
        frames_per_worker_remainder -= add_one;

        const samples_per_worker =
            (frames_per_worker + add_one) *
            max_slices_per_frame * num_samples_in_slice * // -> max samples per frame
            header.num_channels; // 1 i16 per channel -> total length of output slice
        const output_slice = try sample_list.addManyAsSliceBounded(samples_per_worker);

        worker_threads[worker_id] = try std.Thread.spawn(
            .{ .allocator = null, .stack_size = stack_size },
            decodeFrames,
            .{ worker_id, reader, frames_per_worker, output_slice },
        );

        reader.toss(frames_per_worker * bytes_per_frame);
    }

    for (worker_threads) |worker| worker.join();

    return .{
        .num_channels = header.num_channels,
        .sample_rate_hz = header.sample_rate_hz,
        .sample_list = sample_list,
    };
}

fn decodeFrames(
    worker_id: usize,
    initial_reader: std.Io.Reader,
    num_frames: usize,
    output_slice: []i16,
) DecodeError!void {
    var reader = initial_reader;
    var lms_state_buf: [max_decode_channels]Frame.LmsState = undefined;
    var list = std.ArrayList(i16).initBuffer(output_slice);

    for (0..num_frames) |frame_no| {
        // Read the frame header
        const header = try Frame.Header.decode(&reader);

        // Decode the lms states
        const lms_states = lms_state_buf[0..header.num_channels];
        for (lms_states) |*lms| lms.* = try .decode(&reader);

        // Get sample output slice
        const frame_sample_count = header.getSampleSlice();
        const samples = list.addManyAsSliceAssumeCapacity(frame_sample_count);

        Frame.decodeSlices(&reader, lms_states, header.num_channels, samples) catch |e| {
            std.log.scoped(.qoa_worker).err(
                "(id={}) failed to decode frame {} with {} frames left: {s}",
                .{ worker_id, frame_no, num_frames - frame_no, @errorName(e) },
            );
            return e;
        };
    }
}

pub fn deinit(
    self: *qoa,
    alloc: std.mem.Allocator,
) void {
    self.sample_list.deinit(alloc);
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
