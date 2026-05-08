const std = @import("std");
const qoa = @import("qoa");

test "decode qoa header" {
    const assertEq = std.testing.expectEqualDeep;
    var prng = std.Random.DefaultPrng.init(0);
    const rng = prng.random();

    var samples: u32 = undefined;
    var header_buf: []const u8 = undefined;
    var reader: std.Io.Reader = undefined;
    var decoded: qoa.Header = undefined;

    { // happy path
        samples = rng.int(@TypeOf(samples));
        header_buf = "qoaf" ++ std.mem.toBytes(std.mem.nativeToBig(@TypeOf(samples), samples));
        reader = .fixed(header_buf);
        decoded = try qoa.Header.take(&reader);

        samples = rng.int(@TypeOf(samples));
        header_buf = "qoaf" ++ std.mem.toBytes(std.mem.nativeToBig(@TypeOf(samples), samples));
        reader = .fixed(header_buf);
        decoded = try qoa.Header.take(&reader);

        samples = rng.int(@TypeOf(samples));
        header_buf = "qoaf" ++ std.mem.toBytes(std.mem.nativeToBig(@TypeOf(samples), samples));
        reader = .fixed(header_buf);
        decoded = try qoa.Header.take(&reader);
    }

    { // unhappy path

        // too small
        {
            samples = rng.int(@TypeOf(samples));
            var buf = [_]u8{0} ** 7;
            rng.bytes(&buf);
            header_buf = buf[0..];
            reader = .fixed(header_buf);
            try assertEq(qoa.Header.take(&reader), error.InvalidFileFormat);
        }

        // too small
        {
            samples = rng.int(@TypeOf(samples));
            var buf = [_]u8{0} ** 2;
            rng.bytes(&buf);
            header_buf = buf[0..];
            reader = .fixed(header_buf);
            try assertEq(qoa.Header.take(&reader), error.EndOfStream);
        }

        // no magic
        {
            samples = rng.int(@TypeOf(samples));
            header_buf = "qafo" ++ std.mem.toBytes(std.mem.nativeToBig(@TypeOf(samples), samples));
            reader = .fixed(header_buf);
            try assertEq(qoa.Header.take(&reader), error.InvalidFileFormat);
        }
    }
}

test "decode test files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const dir = try std.Io.Dir.cwd().openDir(io, "test/test_files/songs", .{ .iterate = true });

    var threads = std.ArrayList(std.Thread).empty;
    defer threads.deinit(alloc);

    try parseQOARecursive(alloc, &threads, io, dir);

    for (threads.items) |thread| {
        thread.join();
    }
}

fn parseQOARecursive(
    alloc: std.mem.Allocator,
    tasks: *std.ArrayList(std.Thread),
    io: std.Io,
    dir: std.Io.Dir,
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| switch (entry.kind) {
        .directory => {
            const new_dir = try dir.openDir(io, entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            });
            try parseQOARecursive(alloc, tasks, io, new_dir);
        },
        .file => if (std.mem.eql(u8, ".qoa", std.fs.path.extension(entry.name))) {
            // FIX: put limit here for oom killer :)
            if (tasks.items.len > 6) {
                for (tasks.items) |task| task.join();
                tasks.clearRetainingCapacity();
            }
            const file = try dir.openFile(io, entry.name, .{});
            const handle = try std.Thread.spawn(
                .{ .allocator = alloc },
                parseQOAFile,
                .{ alloc, io, file },
            );
            try tasks.append(alloc, handle);
        },
        else => {},
    };
}

fn parseQOAFile(gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) !void {
    defer file.close(io);

    var iobuf: [1024]u8 = undefined;
    var reader = file.reader(io, &iobuf);

    var frame_iterator = try qoa.FrameIter.init(&reader.interface);
    var sample_list = try std.ArrayList(i16).initCapacity(gpa, frame_iterator.overestimateSamplesRemaining());
    defer sample_list.deinit(gpa);
    _ = try frame_iterator.decodeRemaining(gpa, &sample_list);

    std.log.debug(
        \\Parsed {any}
        \\audio.header = {any}
        \\audio.samples.len = {}
        \\-------------------------------------------------------------------------------------
    , .{
        file,
        frame_iterator.frame_header,
        sample_list.items.len,
    });
}
