const std = @import("std");
const rl = @import("raylib");
const qoa = @import("qoa.zig");

pub fn main() !void {
    var debug_alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_alloc.deinit();
    const alloc = debug_alloc.allocator();

    var path_opt: ?[:0]const u8 = null;

    {
        var args = std.process.args();
        _ = args.next();
        while (args.next()) |arg| {
            path_opt = arg;
        }
    }

    const path = path_opt orelse return error.ExpectedQoaFilePath;

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf: [1024]u8 = undefined;
    var file_reader = file.reader(&buf);

    var decoded_qoa_file = try qoa.fromReader(alloc, &file_reader.interface);
    defer decoded_qoa_file.deinit(alloc);

    if (decoded_qoa_file.samples.len == 0) return;

    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    const stream = try rl.loadAudioStream(
        decoded_qoa_file.sample_rate,
        16,
        decoded_qoa_file.channels,
    );
    defer rl.unloadAudioStream(stream);

    rl.playAudioStream(stream);
    rl.setAudioStreamPan(stream, 0.5);
    rl.setAudioStreamPitch(stream, 1);
    rl.setAudioStreamVolume(stream, 1);

    var samples_read: usize = 0;
    const buf_size = 256;
    rl.setAudioStreamBufferSizeDefault(buf_size);

    while (true) {
        if (rl.isAudioStreamProcessed(stream)) {
            if (samples_read + buf_size > decoded_qoa_file.samples.len) {
                rl.updateAudioStream(
                    stream,
                    @ptrCast(&decoded_qoa_file.samples.ptr[samples_read]),
                    @intCast(decoded_qoa_file.samples.len - samples_read),
                );
                rl.updateAudioStream(
                    stream,
                    @ptrCast(decoded_qoa_file.samples.ptr),
                    @intCast(buf_size - (decoded_qoa_file.samples.len - samples_read)),
                );
            } else {
                rl.updateAudioStream(
                    stream,
                    @ptrCast(&decoded_qoa_file.samples[samples_read]),
                    buf_size,
                );
            }
            samples_read = (samples_read + buf_size) % decoded_qoa_file.samples.len;
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}
