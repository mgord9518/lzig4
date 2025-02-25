const std = @import("std");
const clap = @import("clap");
const debug = std.debug;
const io = std.io;
const decompress = @import("lzig4").decompress;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // First we specify what parameters our program can take.
    const params = comptime clap.parseParamsComptime(
        \\-h, --help         display this help and exit
        \\-i, --input  <str> input file path
        \\-o, --output <str> output file path
        \\
        \\<str>...
    );

    //
    var res = try clap.parse(clap.Help, &params, clap.parsers.default, .{
        .allocator = allocator,
    });
    defer res.deinit();

    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;

    if (res.args.help > 0) {
        std.debug.print("Help!\n", .{});
    }

    if (res.args.input) |in| input = in;
    if (res.args.output) |out| output = out;

    const cwd = std.fs.cwd();
    var input_file = try cwd.openFile(input.?, .{});
    var output_file = try cwd.createFile(output.?, .{});
    defer input_file.close();
    defer output_file.close();

    var decompressor = try decompress.Decompressor(@TypeOf(input_file)).init(allocator, input_file);

    // LZ4 blocks can be no larger than 8MiB, this allows to skip double copying
    // through the reader interface
    // If you know the LZ4 data does not use legacy frames, this value can be
    // lowered to 4MiB without performance impact
    var buf = try allocator.alloc(u8, 1024 * 1024 * 8);
    defer allocator.free(buf);

    while (true) {
        const read = try decompressor.read(buf);
        if (read == 0) break;

        std.debug.print("loaded {s}\n", .{buf[0..read]});
        _ = try output_file.write(buf[0..read]);
    }
}
