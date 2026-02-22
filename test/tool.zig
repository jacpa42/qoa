const std = @import("std");
const qoa = @import("qoa");
const zaudio = @import("zaudio");

const sample_size = @sizeOf(i16);

const log = std.log.scoped(.tool);

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    const args = try parseArgs();
    if (args.help) {
        try printHelp();
        return;
    }

    var sound: qoa = undefined;
    if (args.multithread) {
        var thread_count: ?usize = null;
        if (args.thread_count) |t| {
            if (t > 0) thread_count = t;
        }
        sound = try loadSoundMultiThreaded(alloc, args.inpath, thread_count);
    } else {
        sound = try loadSound(alloc, args.inpath);
    }
    defer sound.deinit(alloc);

    log.info(
        \\Finished parsing
        \\┌────────────────────────────────┐
        \\│ num_channels   : {:13} │
        \\│ sample_rate_hz : {:13} │
        \\│ num_samples    : {:13} │
        \\│ buffer size    : {:9} MiB │
        \\│ song_duration  : {:5} minutes │
        \\└────────────────────────────────┘
        \\
    , .{
        sound.num_channels,
        sound.sample_rate_hz,
        sound.sample_list.items.len,
        sound.sample_list.capacity * @sizeOf(i16) / (1024 * 1024),
        sound.sample_list.items.len / (sound.sample_rate_hz * std.time.s_per_min),
    });

    if (args.playback) {
        zaudio.init(alloc);
        defer zaudio.deinit();
        const as_bytes: [*]u8 = @ptrCast(sound.sample_list.items.ptr);
        var qoa_data_reader = std.Io.Reader.fixed(as_bytes[0 .. sample_size * sound.sample_list.items.len]);
        // device
        var device_config = zaudio.Device.Config.init(.playback);
        device_config.playback.format = zaudio.Format.signed16;
        device_config.playback.channels = sound.num_channels;
        device_config.sample_rate = sound.sample_rate_hz;
        device_config.data_callback = dataCallback;
        device_config.user_data = @ptrCast(&qoa_data_reader);

        const device = zaudio.Device.create(null, device_config) catch {
            @panic("Failed to open playback device");
        };
        defer device.destroy();

        zaudio.Device.start(device) catch {
            @panic("Failed to start playback device");
        };

        while (device.getState() != .stopped or device.getState() != .stopping) {
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
    }
}

fn dataCallback(
    device: *zaudio.Device,
    pOutput: ?*anyopaque,
    _: ?*const anyopaque,
    frame_count: u32,
) callconv(.c) void {
    const qoa_data_reader: *std.Io.Reader = @ptrCast(@alignCast(device.getUserData().?));
    const output_array: [*]i16 = @ptrCast(@alignCast(pOutput orelse return));
    const output_slice = output_array[0 .. frame_count * device.getPlaybackChannels()];

    qoa_data_reader.readSliceAll(@ptrCast(output_slice)) catch |err| {
        log.err("Failed to write to output array: {s}", .{@errorName(err)});
    };
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
        \\      --threads,     -t  The number of worker threads to use with the --multithread option
        \\      --playback,    -p  Play the audio file using zaudio
        \\
    );
    try writer.interface.flush();
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

const Args = struct {
    help: bool,
    playback: bool,
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
    return qoa.decodeFilePath(alloc, path);
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
    return qoa.decodeFilePathMultithread(alloc, path, threads);
}
