const std = @import("std");
const consts = @import("constants.zig");
const qoa = @import("../qoa.zig");
const decode = @import("decode.zig");

const log = std.log.scoped(.qoa);

pub const FilePathError =
    decode.Error ||
    std.fs.File.OpenError ||
    std.Io.Reader.LimitedAllocError ||
    std.Thread.SpawnError;

/// Loads the whole file into memory and then decodes it via using a couple workers
pub fn fromPath(
    alloc: std.mem.Allocator,
    sub_path: [:0]const u8,
    worker_thread_count: ?usize,
) FilePathError!qoa {
    var file = try std.fs.cwd().openFile(sub_path, .{});
    var iobuf: [1024]u8 = undefined;
    var reader = file.reader(&iobuf);

    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    try reader.interface.appendRemaining(alloc, &list, .unlimited);

    return fromSlice(alloc, list.items, worker_thread_count);
}

/// Pass `worker_thread_count` as `null` to try to use all cpu cores
pub fn fromSlice(
    alloc: std.mem.Allocator,
    data: []const u8,
    worker_thread_count: ?usize,
) (decode.Error || std.Thread.SpawnError)!qoa {
    var reader = std.Io.Reader.fixed(data);

    const samples_per_channel = try qoa.Header.decode(&reader);

    // Calculate some info about the file
    const num_frames_per_channel = samples_per_channel.numFramesPerChannel() orelse @panic("Cannot decode via multithread if the total number of frames cannot be estimated");
    const num_channels, const sample_rate_hz = try consts.peekMeta(&reader);
    const estimated_total_samples = consts.overEstimateTotalSamples(
        num_channels,
        num_frames_per_channel,
    );

    const bytes_per_frame: usize =
        @sizeOf(qoa.Frame.Header) +
        @sizeOf(qoa.Frame.LmsState16) * @as(usize, num_channels) +
        @sizeOf(qoa.Frame.Slice) * @as(usize, num_channels) * consts.max_slices_per_frame;

    const num_workers: usize = blk: {
        const num_workers = worker_thread_count orelse std.Thread.getCpuCount() catch |e| {
            log.warn("Unable to query number of cpus: {s}", .{@errorName(e)});
            log.warn("Using default {}", .{consts.default_num_workers});
            break :blk consts.default_num_workers;
        };
        break :blk @max(num_workers, 1);
    };

    var thread_buffer: [consts.max_workers]std.Thread = undefined;
    if (num_workers > thread_buffer.len) return error.OutOfMemory;
    var workers = thread_buffer[0..num_workers];

    var sample_list = try std.ArrayList(i16).initCapacity(alloc, estimated_total_samples);
    errdefer sample_list.deinit(alloc);

    std.debug.assert(num_workers > 0);
    const frames_per_worker_per_channel = num_frames_per_channel / num_workers;
    var frames_per_worker_per_channel_remainder = num_frames_per_channel - num_workers * frames_per_worker_per_channel;

    log.debug("total frames in file {}", .{num_frames_per_channel * num_channels});
    log.debug("total memory per thread ~{:.2}KiB", .{@as(f32, @floatFromInt((bytes_per_frame * frames_per_worker_per_channel))) / 1024});

    for (0..workers.len) |worker_id| {
        const add_one = @intFromBool(frames_per_worker_per_channel_remainder > 0);
        frames_per_worker_per_channel_remainder -= add_one;

        const samples_per_worker =
            (frames_per_worker_per_channel + add_one) *
            consts.max_slices_per_frame * consts.num_samples_in_slice * // -> max samples per frame
            num_channels; // 1 i16 per channel -> total length of output slice
        const output_slice = try sample_list.addManyAsSliceBounded(samples_per_worker);

        workers[worker_id] = try std.Thread.spawn(
            .{ .allocator = null, .stack_size = consts.stack_size },
            decodeFrames,
            .{ worker_id, reader, frames_per_worker_per_channel, output_slice },
        );

        // I don't need to call toss on the final frame
        if (worker_id < workers.len - 1) {
            reader.toss(frames_per_worker_per_channel * bytes_per_frame);
        }
    }

    for (workers) |worker| worker.join();

    return .{
        .num_channels = num_channels,
        .sample_rate_hz = sample_rate_hz,
        .sample_list = sample_list,
    };
}

fn decodeFrames(
    worker_id: usize,
    initial_reader: std.Io.Reader,
    num_frames: usize,
    output_slice: []i16,
) decode.Error!void {
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
        const frame_sample_count = header.getSampleSlice();
        const samples = list.addManyAsSliceAssumeCapacity(frame_sample_count);

        qoa.Frame.decodeSlices(&reader, lms_states, header.num_channels, samples) catch |e| {
            std.log.scoped(.qoa_worker).err(
                "(id={}) failed to decode frame {} with {} frames left: {s}",
                .{ worker_id, frame_no, num_frames - frame_no, @errorName(e) },
            );
            return e;
        };
    }
}
