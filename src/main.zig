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

    const compressed = try input_file.reader().readAllAlloc(allocator, 1024 * 1024 * 8);
    defer allocator.free(compressed);

    const data: []u8 = try allocator.alloc(u8, 1024 * 1024 * 16);
    defer allocator.free(data);
    var decompressor: decompress.Decompressor = undefined;
    var read: usize = undefined;
    var written: usize = undefined;
    try decompressor.decompress(compressed, &read, data[0..], &written);

    try output_file.writer().writeAll(data[0..written]);

    std.debug.print("Input: {?s}\nOutput: {?s}\n", .{ input, output });
}
