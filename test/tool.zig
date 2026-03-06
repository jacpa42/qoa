const std = @import("std");
const qoa = @import("qoa");
const zaudio = @import("zaudio");

const sample_size = @sizeOf(i16);

const log = std.log.scoped(.tool);

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    const args = try parseArgs();
    if (args.help) {
        try printHelp();
        return;
    }

    var file: std.fs.File = std.fs.File.stdin();
    defer file.close();
    var iobuf: [1024]u8 = undefined;
    var file_reader: std.fs.File.Reader = undefined;

    var num_channels: u8 = undefined;
    var sample_rate_hz: u24 = undefined;

    var sample_iter = blk: {
        const parse_start = std.time.Instant.now() catch unreachable;
        defer {
            const parse_end = std.time.Instant.now() catch unreachable;
            log.info("Loaded in {:.3}ms", .{
                @as(f32, @floatFromInt(parse_end.since(parse_start))) / std.time.ns_per_ms,
            });
        }

        file = try std.fs.cwd().openFile(args.inpath, .{});
        file_reader = file.reader(&iobuf);

        const frame_header, const frame_iter = try qoa.FrameIter.init(&file_reader.interface);
        num_channels = frame_header.num_channels;
        sample_rate_hz = frame_header.sample_rate_hz;

        // NOTE: as we are *not* in streaming mode, we can use the number of samples in the first frame as the upper bound for samples in the whole file.
        const buf = try gpa.alloc(i16, frame_header.frameSampleCount());
        break :blk qoa.SampleIter.initFrameIter(frame_iter, buf);
    };
    defer sample_iter.deinit(gpa);

    var thread_count: ?u8 = args.thread_count;
    if (thread_count == 0) thread_count = null;

    log.info(
        \\
        \\┌────────────────────────────────┐
        \\│ mode           :          file │
        \\│ num_threads    : {any:13} │
        \\│ num_channels   : {:13} │
        \\│ sample_rate_hz : {:13} │
        \\│ num_samples<   : {:13} │
        \\│ playback speed : {:13.2} │
        \\│ ~song_duration : {:5} minutes │
        \\└────────────────────────────────┘
        \\
    , .{
        thread_count,
        num_channels,
        sample_rate_hz,
        sample_iter.frame_iter.overestimateSamplesRemaining(num_channels),
        args.speed,
        sample_iter.frame_iter.overestimateSamplesRemaining(num_channels) / (sample_rate_hz * std.time.s_per_min),
    });

    if (args.playback) {
        defer zaudio.deinit();
        zaudio.init(gpa);

        // device
        var device_config = zaudio.Device.Config.init(.playback);
        device_config.playback.format = zaudio.Format.signed16;
        device_config.playback.channels = num_channels;
        const t = std.math.clamp(
            args.speed * @as(f32, @floatFromInt(sample_rate_hz)),
            std.math.minInt(u32),
            std.math.maxInt(u32),
        );
        device_config.sample_rate = t;
        device_config.data_callback = dataCallback;
        device_config.user_data = @ptrCast(&sample_iter);

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
    const sound_reader: *qoa.SampleIter = @ptrCast(@alignCast(device.getUserData().?));
    var output_array: [*]i16 = @ptrCast(@alignCast(pOutput orelse return));

    sound_reader.nextSlice(output_array[0 .. frame_count * device.getPlaybackChannels()]) catch |e| {
        log.err("Failed to write samples to output: {}", .{e});
    };
}

fn trim(buf: []const u8) []const u8 {
    return std.mem.trim(u8, buf, &std.ascii.whitespace);
}

fn eql(l: []const u8, r: []const u8) bool {
    return std.mem.eql(u8, l, r);
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
        \\      --speed,       -S  Modify the speed at which playback occurs. Accepts a floating point value.
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
    speed: f32,
    thread_count: ?u8,
    inpath: [:0]const u8,
};

const Error = error{
    ExpectedThreadCountValue,
    ExpectedSpeedValue,
} || std.fmt.ParseIntError;

fn parseArgs() Error!Args {
    var args = std.process.args();
    _ = args.next();

    var no_arg_provided = true;
    var help = false;
    var thread_count: ?u8 = null;
    var playback = false;
    var speed: f32 = 1;
    var stream = false;
    var inpath: [:0]const u8 = &.{};

    while (args.next()) |arg| {
        no_arg_provided = false;
        var trimmed = trim(arg);
        if (eql(trimmed, "-h") or eql(trimmed, "--help")) {
            help = true;
        } else if (eql(trimmed, "-p") or eql(trimmed, "--playback")) {
            playback = true;
        } else if (eql(trimmed, "-s") or eql(trimmed, "--stream")) {
            stream = true;
        } else if (eql(trimmed, "-S") or eql(trimmed, "--speed")) {
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |equal_char| {
                speed = std.fmt.parseFloat(@TypeOf(speed), trimmed[equal_char + 1 ..]) catch |e| {
                    log.err("Failed to parse \"{s}\" into speed {s}", .{ trimmed[equal_char + 1 ..], @errorName(e) });
                    return e;
                };
            } else { // must be next arg
                const next = args.next() orelse {
                    const e = error.ExpectedSpeedValue;
                    log.err("Failed to parse speed {s}", .{@errorName(e)});
                    return e;
                };
                trimmed = trim(next);

                speed = std.fmt.parseFloat(@TypeOf(speed), trimmed) catch |e| {
                    log.err("Failed to parse \"{s}\" into speed {s}", .{ trimmed, @errorName(e) });
                    return e;
                };
            }
        } else if (eql(trimmed, "-t") or eql(trimmed, "--threads")) {
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |equal_char| {
                thread_count = std.fmt.parseInt(u8, trimmed[equal_char + 1 ..], 10) catch |e| {
                    log.err("Failed to parse \"{s}\" into thread count {s}", .{ trimmed[equal_char + 1 ..], @errorName(e) });
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
        .thread_count = thread_count,
        .playback = playback,
        .speed = speed,
        .stream = stream,
        .inpath = inpath,
    };
}
