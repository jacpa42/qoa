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
        decoded = try qoa.Header.decode(&reader);
        try assertEq(decoded.samples, @as(qoa.Header.Samples, @enumFromInt(samples)));

        samples = rng.int(@TypeOf(samples));
        header_buf = "qoaf" ++ std.mem.toBytes(std.mem.nativeToBig(@TypeOf(samples), samples));
        reader = .fixed(header_buf);
        decoded = try qoa.Header.decode(&reader);
        try assertEq(decoded.samples, @as(qoa.Header.Samples, @enumFromInt(samples)));

        samples = rng.int(@TypeOf(samples));
        header_buf = "qoaf" ++ std.mem.toBytes(std.mem.nativeToBig(@TypeOf(samples), samples));
        reader = .fixed(header_buf);
        decoded = try qoa.Header.decode(&reader);
        try assertEq(decoded.samples, @as(qoa.Header.Samples, @enumFromInt(samples)));
    }

    { // unhappy path

        // too small
        {
            samples = rng.int(@TypeOf(samples));
            var buf = [_]u8{0} ** 7;
            rng.bytes(&buf);
            header_buf = buf[0..];
            reader = .fixed(header_buf);
            try assertEq(qoa.Header.decode(&reader), error.InvalidFileFormat);
        }

        // too small
        {
            samples = rng.int(@TypeOf(samples));
            var buf = [_]u8{0} ** 2;
            rng.bytes(&buf);
            header_buf = buf[0..];
            reader = .fixed(header_buf);
            try assertEq(qoa.Header.decode(&reader), error.InvalidFileFormat);
        }

        // no magic
        {
            samples = rng.int(@TypeOf(samples));
            header_buf = "qafo" ++ std.mem.toBytes(std.mem.nativeToBig(@TypeOf(samples), samples));
            reader = .fixed(header_buf);
            try assertEq(qoa.Header.decode(&reader), error.InvalidFileFormat);
        }
    }
}

test "decode test files" {
    const alloc = std.testing.allocator;
    const dir = try std.fs.cwd().openDir("test_files/", .{ .iterate = true });
    var threads = std.ArrayList(std.Thread).empty;
    defer threads.deinit(alloc);

    try parseEveryQOAInDirRecursive(alloc, &threads, dir);

    for (threads.items) |thread| {
        thread.join();
    }
}

fn parseEveryQOAInDirRecursive(
    alloc: std.mem.Allocator,
    tasks: *std.ArrayList(std.Thread),
    dir: std.fs.Dir,
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| switch (entry.kind) {
        .directory => {
            std.debug.print("dir {s}\n", .{entry.name});
            const new_dir = try dir.openDir(entry.name, .{ .iterate = true });
            try parseEveryQOAInDirRecursive(alloc, tasks, new_dir);
        },
        .file => if (std.mem.eql(u8, ".qoa", std.fs.path.extension(entry.name))) {
            std.debug.print("Parsing {s}\n", .{entry.name});
            const file = try dir.openFile(entry.name, .{});
            const handle = try std.Thread.spawn(
                .{ .allocator = alloc },
                parseQOAFile,
                .{ alloc, file },
            );
            try tasks.append(alloc, handle);
        },
        else => {},
    };
}

fn parseQOAFile(alloc: std.mem.Allocator, file: std.fs.File) !void {
    defer file.close();

    var iobuf: [1024]u8 = undefined;
    var reader = file.reader(&iobuf);

    const audio = try qoa.decodeReader(alloc, &reader.interface);
    defer audio.deinit(alloc);

    std.debug.print("audio.num_channels = {}\n", .{audio.num_channels});
    std.debug.print("audio.sample_rate_hz = {}\n", .{audio.sample_rate_hz});
    std.debug.print("audio.samples.len  = {}\n", .{audio.samples.len});
}
