const std = @import("std");
const qoa = @import("qoa");
const zaudio = @import("zaudio");

const sample_size = @sizeOf(i16);

const log = std.log.scoped(.tool);

const Sound = union(enum) {
    file: qoa,
    fixed_stream: qoa.streaming.Fixed,
};

const SoundReader = union(enum) {
    file: struct {
        samples: []i16,
        position: usize,
    },
    fixed_stream: struct {
        stream: *qoa.streaming.Fixed,
        frame: []i16,
        frame_pos: usize,
    },
};

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    const args = try parseArgs();
    if (args.help) {
        try printHelp();
        return;
    }

    var sound: Sound = blk: {
        if (args.stream and !args.multithread) {
            const fixed_stream = try loadAudioStream(gpa, args.inpath);
            // NOTE: I don't deinit any memory because it doesn't really matter here

            log.info(
                \\
                \\┌────────────────────────────────┐
                \\│ mode           :     streaming │
                \\│ num_threads    :          null │
                \\│ num_channels   : {:13} │
                \\│ sample_rate_hz : {:13} │
                \\│ num_samples    :          n.a. │
                \\│ buffer size    : {:9} MiB │
                \\│ song_duration  :          n.a. │
                \\└────────────────────────────────┘
                \\
            , .{
                fixed_stream.num_channels,
                fixed_stream.sample_rate_hz,
                fixed_stream.frame_samples.len * sample_size / (1024 * 1024),
            });

            break :blk .{ .fixed_stream = fixed_stream };
        } else {
            var sound_file: qoa = undefined;
            var thread_count: ?usize = std.Thread.getCpuCount() catch null;
            if (args.multithread or args.thread_count != null) {
                if (args.thread_count) |t| {
                    if (t > 0) thread_count = t;
                }
                sound_file = try loadSoundMultiThreaded(gpa, args.inpath, thread_count);
            } else {
                sound_file = try loadSound(gpa, args.inpath);
            }

            log.info(
                \\
                \\┌────────────────────────────────┐
                \\│ mode           :          file │
                \\│ num_threads    : {any:13} │
                \\│ num_channels   : {:13} │
                \\│ sample_rate_hz : {:13} │
                \\│ num_samples    : {:13} │
                \\│ buffer size    : {:9} MiB │
                \\│ song_duration  : {:5} minutes │
                \\└────────────────────────────────┘
                \\
            , .{
                thread_count,
                sound_file.num_channels,
                sound_file.sample_rate_hz,
                sound_file.sample_list.items.len,
                sound_file.sample_list.capacity * sample_size / (1024 * 1024),
                sound_file.sample_list.items.len / (sound_file.sample_rate_hz * std.time.s_per_min),
            });
            break :blk .{ .file = sound_file };
        }
    };

    if (args.playback) {
        var channels: u8 = undefined;
        var sample_rate: u24 = undefined;
        var sound_reader: SoundReader = switch (sound) {
            .file => |file| blk: {
                channels = file.num_channels;
                sample_rate = file.sample_rate_hz;
                break :blk SoundReader{
                    .file = .{
                        .samples = file.sample_list.items,
                        .position = 0,
                    },
                };
            },
            .fixed_stream => |*fixed_stream| blk: {
                channels = fixed_stream.num_channels;
                sample_rate = fixed_stream.sample_rate_hz;
                const current_frame = try fixed_stream.next();
                break :blk SoundReader{
                    .fixed_stream = .{
                        .stream = fixed_stream,
                        .frame = current_frame.?,
                        .frame_pos = 0,
                    },
                };
            },
        };

        defer zaudio.deinit();
        zaudio.init(gpa);

        // device
        var device_config = zaudio.Device.Config.init(.playback);
        device_config.playback.format = zaudio.Format.signed16;
        device_config.playback.channels = channels;
        device_config.sample_rate = sample_rate;
        device_config.data_callback = dataCallback;
        device_config.user_data = @ptrCast(&sound_reader);

        const device = zaudio.Device.create(null, device_config) catch {
            @panic("Failed to open playback device");
        };
        defer device.destroy();

        zaudio.Device.start(device) catch {
            @panic("Failed to start playback device");
        };

        while (device.getState() != .stopped or device.getState() != .stopping) {
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
    }
}

fn dataCallback(
    device: *zaudio.Device,
    pOutput: ?*anyopaque,
    _: ?*const anyopaque,
    frame_count: u32,
) callconv(.c) void {
    const sound_reader: *SoundReader = @ptrCast(@alignCast(device.getUserData().?));
    var output_array: [*]i16 = @ptrCast(@alignCast(pOutput orelse return));

    switch (sound_reader.*) {
        .file => |*sample_reader| {
            const start = sample_reader.position;
            sample_reader.position += frame_count * device.getPlaybackChannels();
            const end = sample_reader.position;

            @memcpy(output_array, sample_reader.samples[start..end]);
        },
        .fixed_stream => |*stream| {
            var samples_remaining = frame_count * device.getPlaybackChannels();

            while (samples_remaining > 0) {
                var samples_left = stream.frame.len -| stream.frame_pos;

                if (samples_left == 0) {
                    log.debug("Reading next frame", .{});
                    const next = stream.stream.next() catch |err| {
                        log.err("Failed to decode next stream: {s}", .{@errorName(err)});
                        return;
                    } orelse {
                        log.info("End of stream reached", .{});
                        return;
                    };

                    stream.frame = next;
                    stream.frame_pos = 0;
                    samples_left = next.len;
                }

                std.debug.assert(samples_left > 0);

                const samples_we_consume = @min(samples_left, samples_remaining);
                samples_remaining -= samples_we_consume;
                @memcpy(output_array, stream.frame[stream.frame_pos .. stream.frame_pos + samples_we_consume]);

                stream.frame_pos += samples_we_consume;
                output_array = output_array + samples_we_consume;
            }
        },
    }
}
pub fn onMalloc(len: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const allocator: *std.mem.Allocator = @ptrCast(user_data.?);
    const slice = allocator.alloc(u8, len) catch return null;
    return @ptrCast(slice.ptr);
}

pub fn onRealloc(
    ptr: ?*anyopaque,
    len: usize,
    user_data: ?*anyopaque,
) callconv(.c) ?*anyopaque {
    const allocator: *std.mem.Allocator = @ptrCast(user_data.?);
    const old_slice: []u8 = @as([*]u8, @ptrCast(ptr.?))[0..len];
    const new_slice: []u8 = allocator.realloc(old_slice, len) catch return null;
    return @ptrCast(new_slice.ptr);
}

pub fn onFree(ptr: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    if (ptr) |nonnull| {
        const allocator: *std.mem.Allocator = @ptrCast(user_data.?);
        allocator.free(nonnull);
    }
}

fn trim(buf: []const u8) []const u8 {
    return std.mem.trim(u8, buf, &std.ascii.whitespace);
}

fn printHelp() !void {
    const stdout = std.fs.File.stderr();
    var writer = stdout.writer(&.{});
    try writer.interface.writeAll(
        \\Epic qoa tool. Takes in an input file and plays it back
        \\
        \\SYNOPSIS
        \\      tool [options] input-file
        \\OPTIONS
        \\      --help,        -h  Print this menu and exit
        \\      --multithread, -m  Use the multithreaded decoder
        \\      --stream,      -s  Decode a single frame at a time instead of the whole file at once.
        \\      --threads,     -t  The number of worker threads to use with the --multithread option
        \\      --playback,    -p  Play the audio file using zaudio
        \\
    );
    try writer.interface.flush();
}

const Args = struct {
    help: bool,
    playback: bool,
    stream: bool,
    thread_count: ?u8,
    multithread: bool,
    inpath: [:0]const u8,
};

const Error = error{
    ExpectedThreadCountValue,
} || std.fmt.ParseIntError;

fn parseArgs() Error!Args {
    var args = std.process.args();
    _ = args.next();

    var no_arg_provided = true;
    var help = false;
    var thread_count: ?u8 = null;
    var multithread = false;
    var playback = false;
    var stream = false;
    var inpath: [:0]const u8 = &.{};

    while (args.next()) |arg| {
        no_arg_provided = false;
        var trimmed = trim(arg);
        if (std.mem.startsWith(u8, trimmed, "-h") or
            std.mem.startsWith(u8, trimmed, "--h"))
        {
            help = true;
        } else if (std.mem.startsWith(u8, trimmed, "-p") or
            std.mem.startsWith(u8, trimmed, "--p"))
        {
            playback = true;
        } else if (std.mem.startsWith(u8, trimmed, "-s") or
            std.mem.startsWith(u8, trimmed, "--s"))
        {
            stream = true;
        } else if (std.mem.startsWith(u8, trimmed, "-m") or
            std.mem.startsWith(u8, trimmed, "--m"))
        {
            multithread = true;
        } else if (std.mem.startsWith(u8, trimmed, "-t") or
            std.mem.startsWith(u8, trimmed, "--t"))
        {
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eql| {
                thread_count = std.fmt.parseInt(u8, trimmed[eql + 1 ..], 10) catch |e| {
                    log.err("Failed to parse \"{s}\" into thread count {s}", .{ trimmed[eql + 1 ..], @errorName(e) });
                    return e;
                };
            } else { // must be next arg
                const next = args.next() orelse {
                    const e = error.ExpectedThreadCountValue;
                    log.err("Failed to parse thread count {s}", .{@errorName(e)});
                    return e;
                };
                trimmed = trim(next);

                thread_count = std.fmt.parseInt(u8, trimmed, 10) catch |e| {
                    log.err("Failed to parse \"{s}\" into thread count {s}", .{ trimmed, @errorName(e) });
                    return e;
                };
            }
        } else {
            inpath = arg;
        }
    }

    return Args{
        .help = help or no_arg_provided or inpath.len == 0,
        .multithread = multithread,
        .thread_count = thread_count,
        .playback = playback,
        .stream = stream,
        .inpath = inpath,
    };
}

fn loadSound(
    alloc: std.mem.Allocator,
    path: [:0]const u8,
) !qoa {
    const parse_start = std.time.Instant.now() catch unreachable;
    defer {
        const parse_end = std.time.Instant.now() catch unreachable;
        log.info("Parsed in {:.2}ms", .{
            @as(f32, @floatFromInt(parse_end.since(parse_start))) / std.time.ns_per_ms,
        });
    }

    log.info("parsing file {s}", .{path});
    return qoa.decode.fromPath(alloc, path);
}

fn loadSoundMultiThreaded(
    alloc: std.mem.Allocator,
    path: [:0]const u8,
    threads: ?usize,
) !qoa {
    const parse_start = std.time.Instant.now() catch unreachable;
    defer {
        const parse_end = std.time.Instant.now() catch unreachable;
        log.info("Parsed in {:.2}ms", .{
            @as(f32, @floatFromInt(parse_end.since(parse_start))) / std.time.ns_per_ms,
        });
    }

    log.info("parsing file {s}", .{path});
    return qoa.decode.multithread.fromPath(alloc, path, threads);
}

fn loadAudioStream(
    gpa: std.mem.Allocator,
    path: [:0]const u8,
) !qoa.streaming.Fixed {
    const parse_start = std.time.Instant.now() catch unreachable;
    defer {
        const parse_end = std.time.Instant.now() catch unreachable;
        log.info("Parsed in {:.2}ms", .{
            @as(f32, @floatFromInt(parse_end.since(parse_start))) / std.time.ns_per_ms,
        });
    }

    log.info("parsing file {s}", .{path});

    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    var iobuf: [1024]u8 = undefined;
    var reader = f.reader(&iobuf);

    var list = std.ArrayList(u8).empty;
    // defer list.deinit(gpa); // NOTE: Don't deinit!
    try reader.interface.appendRemaining(gpa, &list, .unlimited);

    return try qoa.streaming.Fixed.init(gpa, list.items);
}
