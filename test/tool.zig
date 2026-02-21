const std = @import("std");
const qoa = @import("qoa");
const zaudio = @import("zaudio");

const sample_size = @sizeOf(i16);

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    const args = parseArgs();
    if (args.help) {
        try printHelp();
        return;
    }

    const sound = try loadSoundIntoMemory(alloc, args.inpath);
    defer sound.deinit(alloc);

    std.log.info(
        \\Finished parsing
        \\
        \\ num_channels   : {}
        \\ sample_rate_hz : {}
        \\ num_samples    : {}
        \\ song_duration  : {} minutes
    , .{
        sound.num_channels,
        sound.sample_rate_hz,
        sound.samples.len,
        sound.samples.len / (sound.sample_rate_hz * std.time.s_per_min),
    });

    if (args.playback) {
        zaudio.init(alloc);
        defer zaudio.deinit();
        const as_bytes: [*]u8 = @ptrCast(sound.samples.ptr);
        var qoa_data_reader = std.Io.Reader.fixed(as_bytes[0 .. sample_size * sound.samples.len]);
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
        std.log.err("Failed to write to output array: {s}", .{@errorName(err)});
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
        \\      --help,     -h  Print this menu and exit
        \\      --playback, -p  Play the audio file using zaudio
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
    inpath: [:0]const u8,
};

fn parseArgs() Args {
    var args = std.process.args();
    _ = args.next();

    var no_arg_provided = true;
    var help = false;
    var playback = false;
    var inpath: [:0]const u8 = &.{};

    while (args.next()) |arg| {
        const trimmed = trim(arg);
        if (std.mem.startsWith(u8, trimmed, "-h") or
            std.mem.startsWith(u8, trimmed, "--h"))
        {
            no_arg_provided = false;
            help = true;
        } else if (std.mem.startsWith(u8, trimmed, "-p") or
            std.mem.startsWith(u8, trimmed, "--p"))
        {
            no_arg_provided = false;
            playback = true;
        } else {
            no_arg_provided = false;
            inpath = arg;
        }
    }

    return Args{
        .help = help or no_arg_provided or inpath.len == 0,
        .playback = playback,
        .inpath = inpath,
    };
}

fn loadSoundIntoMemory(
    alloc: std.mem.Allocator,
    path: [:0]const u8,
) !qoa {
    const parse_start = std.time.Instant.now() catch unreachable;
    defer {
        const parse_end = std.time.Instant.now() catch unreachable;
        std.log.info("Parsed in {:.2}ms", .{
            @as(f32, @floatFromInt(parse_end.since(parse_start))) / std.time.ns_per_ms,
        });
    }
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var reader_buf: [1024]u8 = undefined;
    var file_reader = file.reader(&reader_buf);
    var list = std.ArrayList(u8).empty;
    try file_reader.interface.appendRemaining(alloc, &list, .unlimited);
    defer list.deinit(alloc);

    std.log.info("parsing file {s}", .{path});
    return qoa.decodeSlice(alloc, list.items);
}
