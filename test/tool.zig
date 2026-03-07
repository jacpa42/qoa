const std = @import("std");
const qoa = @import("qoa");
const zaudio = @import("zaudio");

const log = std.log.scoped(.tool);
const iobuf_size = 1024;

var volume: f32 = 1;

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    var args = try parseArgs(gpa);
    defer args.deinit(gpa);
    defer for (args.sound_files.items) |f| f.close();

    volume = @abs(args.vol);

    if (args.help) {
        try printHelp();
        return;
    }

    if (args.sound_files.items.len == 0) return error.NoSoundFiles;
    std.log.info("----------Mixing {} sounds----------", .{args.sound_files.items.len});

    var sample_buffers = std.ArrayList(i16).initBuffer(try gpa.alloc(i16, qoa.consts.max_samples_per_frame * args.sound_files.items.len));
    defer sample_buffers.deinit(gpa);
    var io_buffers = try gpa.alloc(u8, args.sound_files.items.len * iobuf_size);
    defer gpa.free(io_buffers);
    var file_readers = try gpa.alloc(std.fs.File.Reader, args.sound_files.items.len);
    defer gpa.free(file_readers);

    // TODO: Implement mixing for different number of channels
    var num_channels_opt: ?u8 = null;
    var sample_rate_hz_opt: ?u24 = null;

    var sample_iters = blk: {
        const parse_start = std.time.Instant.now() catch unreachable;
        defer {
            const parse_end = std.time.Instant.now() catch unreachable;
            log.info("Loaded in {:.3}ms", .{
                @as(f32, @floatFromInt(parse_end.since(parse_start))) / std.time.ns_per_ms,
            });
        }

        const sample_iters = try gpa.alloc(qoa.SampleIter, args.sound_files.items.len);
        for (0.., args.sound_files.items, sample_iters) |i, file, *sample_iter| {
            const iobuf = io_buffers[i * iobuf_size .. (i + 1) * iobuf_size];
            file_readers[i] = file.reader(iobuf);

            const frame_header, const frame_iter = try qoa.FrameIter.init(&file_readers[i].interface);

            if (num_channels_opt) |c| {
                if (frame_header.num_channels != c) return error.NotAllFilesHaveSameNumberOfChannels;
            } else num_channels_opt = frame_header.num_channels;

            if (sample_rate_hz_opt) |s| {
                if (frame_header.sample_rate_hz != s) return error.NotAllFilesHaveSameSampleRate;
            } else sample_rate_hz_opt = frame_header.sample_rate_hz;

            // NOTE: as we are *not* in streaming mode, we can use the number of samples in the first frame as the upper bound for samples in the whole file.
            const buf = try sample_buffers.addManyAsSliceBounded(frame_header.frameSampleCount());
            sample_iter.* = qoa.SampleIter.initFrameIter(frame_iter, buf);
        }
        break :blk sample_iters;
    };
    defer gpa.free(sample_iters);

    const num_channels = num_channels_opt.?;
    const sample_rate_hz = sample_rate_hz_opt.?;

    if (args.show_file_info) for (sample_iters) |sample_iter| {
        log.info(
            \\
            \\┌────────────────────────────────┐
            \\│ mode           :          file │
            \\│ num_channels   : {:13} │
            \\│ sample_rate_hz : {:13} │
            \\│ num_samples<   : {:13} │
            \\│ playback speed : {:13.2} │
            \\│ ~song_duration : {:5} minutes │
            \\└────────────────────────────────┘
            \\
        , .{
            num_channels,
            sample_rate_hz,
            sample_iter.frame_iter.overestimateSamplesRemaining(num_channels),
            args.speed,
            sample_iter.frame_iter.overestimateSamplesRemaining(num_channels) / (sample_rate_hz * std.time.s_per_min),
        });
    };

    {
        defer zaudio.deinit();
        zaudio.init(gpa);

        // device
        var device_config = zaudio.Device.Config.init(.playback);
        device_config.playback.format = zaudio.Format.signed16;
        device_config.playback.channels = num_channels;
        const val = args.speed * @as(f32, @floatFromInt(sample_rate_hz));
        device_config.sample_rate = if (val > std.math.maxInt(u24)) std.math.maxInt(u24) else @intFromFloat(val);
        device_config.data_callback = dataCallback;
        device_config.user_data = @ptrCast(&sample_iters);

        const device = zaudio.Device.create(null, device_config) catch {
            @panic("Failed to open playback device");
        };
        defer device.destroy();

        zaudio.Device.start(device) catch {
            @panic("Failed to start playback device");
        };

        while (true) switch (device.getState()) {
            .uninitialized => {},
            .starting, .started => {
                std.Thread.sleep(1 * std.time.ns_per_s);
                continue;
            },
            .stopped, .stopping => return,
        };
    }
}

fn dataCallback(
    device: *zaudio.Device,
    pOutput: ?*anyopaque,
    _: ?*const anyopaque,
    frame_count: u32,
) callconv(.c) void {
    const datacb_start = std.time.Instant.now() catch unreachable;
    defer {
        const datacb_end = std.time.Instant.now() catch unreachable;
        log.info("dataCallback took {:.3}ms", .{
            @as(f32, @floatFromInt(datacb_end.since(datacb_start))) / std.time.ns_per_ms,
        });
    }

    const sounds_array_ptr: *[]qoa.SampleIter = @ptrCast(@alignCast(device.getUserData().?));
    const sounds = sounds_array_ptr.*;
    const output_array = @as([*]i16, @ptrCast(@alignCast(pOutput orelse return)))[0 .. frame_count * device.getPlaybackChannels()];

    // TODO: Epic idea, create a buffer to mix to with float samples, write to it, then write to the output with casting. Should be cache friendly :) But ja need an extra buffer

    sounds[0].nextSlice(output_array) catch unreachable;
    for (sounds[1..]) |*sound| {
        var output_idx: usize = 0;
        while (output_idx < output_array.len) {
            const samples = sound.takeSlice(output_array.len - output_idx) catch unreachable;
            for (samples) |sample| {
                output_array[output_idx] +|= sample;
                output_idx += 1;
            }
        }
    }
}

fn trim(buf: []const u8) []const u8 {
    return std.mem.trim(u8, buf, &std.ascii.whitespace);
}

fn startsWith(l: []const u8, r: []const u8) bool {
    return std.mem.startsWith(u8, l, r);
}

fn printHelp() !void {
    var writer = std.fs.File.stderr().writer(&.{});
    try writer.interface.writeAll(
        \\Epic qoa tool. Takes in an input file and plays it back
        \\
        \\SYNOPSIS
        \\      tool [options] input-file
        \\OPTIONS
        \\      --help,           -h  Print this menu and exit.
        \\      --show-file-info, -S  Show file info.
        \\      --volume,         -v  Set the volume. Accepts a floating point value [0 - 1].
        \\      --speed,          -s  Modify the speed at which playback occurs. Accepts a floating point value.
        \\      --path,           -p  Specify a qoa file to play. Multiple files can be specified to play multiple files at once.
        \\
    );
    try writer.interface.flush();
}

const Args = struct {
    help: bool,
    vol: f32,
    show_file_info: bool,
    speed: f32,
    sound_files: std.ArrayList(std.fs.File),

    pub fn deinit(self: *Args, gpa: std.mem.Allocator) void {
        for (self.sound_files.items) |f| f.close();
        self.sound_files.deinit(gpa);
    }
};

fn parseArgs(gpa: std.mem.Allocator) !Args {
    var args = std.process.args();
    _ = args.next();

    var no_arg_provided = true;
    var show_file_info = false;
    var vol: f32 = 1.0;
    var help = false;
    var speed: f32 = 1;
    var inpaths: std.ArrayList(std.fs.File) = .empty;
    errdefer for (inpaths.items) |f| f.close();

    while (args.next()) |arg| {
        no_arg_provided = false;
        var trimmed = trim(arg);
        if (startsWith(trimmed, "-h") or startsWith(trimmed, "--help")) {
            help = true;
        } else if (startsWith(trimmed, "-S") or startsWith(trimmed, "--show-file-info")) {
            show_file_info = true;
        } else if (startsWith(trimmed, "-v") or startsWith(trimmed, "--volume")) {
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |equal_char| {
                vol = std.fmt.parseFloat(@TypeOf(vol), trimmed[equal_char + 1 ..]) catch |e| {
                    log.err("Failed to parse \"{s}\" into volume {s}", .{ trimmed[equal_char + 1 ..], @errorName(e) });
                    return e;
                };
            } else { // must be next arg
                const next = args.next() orelse {
                    const e = error.ExpectedSpeedValue;
                    log.err("Failed to parse volume {s}", .{@errorName(e)});
                    return e;
                };
                trimmed = trim(next);

                vol = std.fmt.parseFloat(@TypeOf(vol), trimmed) catch |e| {
                    log.err("Failed to parse \"{s}\" into speed {s}", .{ trimmed, @errorName(e) });
                    return e;
                };
            }
        } else if (startsWith(trimmed, "-s") or startsWith(trimmed, "--speed")) {
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
        } else if (startsWith(trimmed, "-p") or startsWith(trimmed, "--path")) {
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |equal_char| {
                try inpaths.append(gpa, try std.fs.cwd().openFile(trimmed[equal_char + 1 ..], .{}));
            } else { // must be next arg
                const next = args.next() orelse {
                    const e = error.ExpectedQoaFilePath;
                    log.err("Failed to parse speed {s}", .{@errorName(e)});
                    return e;
                };
                trimmed = trim(next);

                try inpaths.append(gpa, try std.fs.cwd().openFile(trimmed, .{}));
            }
        } else {
            log.warn("Unknown argument: \"{s}\"", .{trimmed});
            help = true;
            break;
        }
    }

    return Args{
        .help = help or no_arg_provided,
        .vol = vol,
        .show_file_info = show_file_info,
        .speed = speed,
        .sound_files = inpaths,
    };
}
