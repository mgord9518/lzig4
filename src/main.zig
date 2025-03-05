const std = @import("std");
const decompress = @import("lzig4").decompress;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.debug.print(
            "usage: {s} <INPUT_FILE> <OUTPUT_FILE>",
            .{args[0]},
        );

        return;
    }

    const cwd = std.fs.cwd();
    var input_file = try cwd.openFile(args[1], .{});
    var output_file = try cwd.createFile(args[2], .{});
    defer input_file.close();
    defer output_file.close();

    var decompressor = try decompress.Decompressor(@TypeOf(input_file)).init(
        allocator,
        input_file,
    );

    // Legacy LZ4 blocks are 8MiB, this allows to skip double copying data
    // through the Reader interface. If you know you will *not* be decoding
    // legacy frames, this can be lowered to 4MiB without performance impact
    // as that is the maximum size of the modern frame format
    var buf = try allocator.alloc(u8, 1024 * 1024 * 8);
    defer allocator.free(buf);

    while (true) {
        const read = try decompressor.read(buf);
        if (read == 0) break;

        _ = try output_file.write(buf[0..read]);
    }
}
