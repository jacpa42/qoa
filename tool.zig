const std = @import("std");
const qoa = @import("qoa.zig");

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const path = args.next() orelse @panic("Expected input qoa file.");

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var reader_buf: [1024]u8 = undefined;
    var file_reader = file.reader(&reader_buf);
    var iter = try qoa.Iter.init(&file_reader.interface);

    var write_buf: [128]u8 = undefined;
    const stdout = std.fs.File.stdout();

    var writer = stdout.writer(&write_buf);

    try writeWav(&writer.interface, &iter);
}

// Lifted from https://www.jonolick.com/code.html - public domain
// Made endian agnostic using qoaconv_fwrite()
fn writeWav(
    writer: *std.Io.Writer,
    iter: *qoa.Iter,
) !void {
    const data_size: u32 = iter.sample_count * iter.channel_count * @sizeOf(i16);

    try writer.writeAll("RIFF");
    try writer.writeInt(u32, data_size + 44 - 8, .little);
    try writer.writeAll("WAVEfmt \x10\x00\x00\x00\x01\x00");
    try writer.writeInt(i16, iter.channel_count, .little);
    try writer.writeInt(u32, iter.sample_rate, .little);
    try writer.writeInt(u32, iter.channel_count * iter.sample_rate * @bitSizeOf(i16) / 8, .little);
    try writer.writeInt(i16, iter.channel_count * @bitSizeOf(i16) / 8, .little);
    try writer.writeInt(i16, @bitSizeOf(i16), .little);
    try writer.writeAll("data");
    try writer.writeInt(u32, data_size, .little);

    while (try iter.next()) |sample_buf| {
        const raw_samples: []const u8 = std.mem.sliceAsBytes(sample_buf);
        try writer.writeAll(raw_samples);
    }

    try writer.flush();
}
