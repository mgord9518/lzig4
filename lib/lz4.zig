const std = @import("std");
const testing = std.testing;

pub const frame = @import("frame_header.zig");
pub const block = @import("block.zig");

pub const Decompressor = struct {
    in_stream: *std.Io.Reader,
    current_frame_header: frame.FrameHeader,
    interface: std.Io.Reader,
    allocator: std.mem.Allocator,
    buffer: []u8,

    pub const Options = struct {
        verify_checksum: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, in_stream: *std.Io.Reader) !Decompressor {
        const buffer = try allocator.alloc(u8, 1024 * 1024 * 8);
        const compress_buffer = try allocator.alloc(u8, 1024 * 1024 * 16);

        var decompressor: Decompressor = .{
            .buffer = compress_buffer,
            .allocator = allocator,
            .in_stream = in_stream,
            .current_frame_header = undefined,
            .interface = .{
                .vtable = &.{
                    .stream = Decompressor.stream,
                    .readVec = Decompressor.readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };

        decompressor.current_frame_header = try frame.FrameHeader.takeFromStream(in_stream);

        return decompressor;
    }

    pub fn deinit(decompressor: Decompressor) void {
        decompressor.allocator.free(decompressor.interface.buffer);
        decompressor.allocator.free(decompressor.buffer);
    }

    fn resetBuffer(decompressor: *Decompressor) !void {
        var block_info = try decompressor.getBlockInfo();

        sw: switch (block_info.isEndMark()) {
            // End of frame, attempt to read another one
            true => {
                if (decompressor.current_frame_header != .general) break :sw;

                // Dump checksum
                // TODO: verify it
                _ = try decompressor.in_stream.takeInt(u32, .little);
                decompressor.current_frame_header = frame.FrameHeader.takeFromStream(decompressor.in_stream) catch return error.EndOfStream;

                block_info = try decompressor.getBlockInfo();
                continue :sw block_info.isEndMark();
            },
            false => {},
        }

        if (block_info.uncompressed) {
            var buffer_writer: std.Io.Writer = .fixed(decompressor.interface.buffer);
            try decompressor.in_stream.streamExact(&buffer_writer, block_info.size);

            return;
        }

        var buffer_writer: std.Io.Writer = .fixed(decompressor.buffer);
        try decompressor.in_stream.streamExact(&buffer_writer, block_info.size);

        var read_out: usize = 0;
        var written_out: usize = 0;

        block.decodeBlock(
            decompressor.buffer[0..block_info.size],
            &read_out,
            decompressor.interface.buffer,
            &written_out,
        ) catch unreachable;

        // Attempt to read another frame header
        if (decompressor.current_frame_header == .legacy) blk: {
            decompressor.current_frame_header = frame.FrameHeader.takeFromStream(
                decompressor.in_stream
            ) catch break :blk;
        }

        decompressor.interface.seek = 0;
        decompressor.interface.end = written_out;
    }

    fn readVec(reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        _ = data;

        const decompressor: *Decompressor = @alignCast(@fieldParentPtr("interface", reader));
        decompressor.resetBuffer() catch |err| switch (err) {
            error.WriteFailed => return error.EndOfStream,
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
        
        return 0;
    }

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        _ = limit;
        _ = writer;

        const decompressor: *Decompressor = @alignCast(@fieldParentPtr("interface", reader));
        try decompressor.resetBuffer();

        return 0;
    }

    // Gets size of decompressed block based on current frame type
    fn decompressedBlockSize(decompressor: Decompressor) error{InvalidBlockSize}!usize {
        return switch (decompressor.current_frame_header) {
            // Legacy blocks are always 8 MiB
            .legacy => 1024 * 1024 * 8,

            .general => |general| @as(usize, switch (general.block_data.max_size) {
                ._64KiB => 1024 * 64,
                ._256KiB => 1024 * 256,
                ._1MiB => 1024 * 1024,
                ._4MiB => 1024 * 1024 * 4,

                else => return error.InvalidBlockSize,
            }),

            else => unreachable,
        };
    }

    const BlockInfo = struct {
        uncompressed: bool,
        size: u32,

        fn isEndMark(block_info: BlockInfo) bool {
            return @intFromBool(block_info.uncompressed) + block_info.size == 0;
        }
    };

    fn getBlockInfo(decompressor: *Decompressor) std.Io.Reader.Error!BlockInfo {
        return switch (decompressor.current_frame_header) {
            .legacy => .{
                .uncompressed = false,
                .size = decompressor.current_frame_header.legacy,
            },

            .general => blk: {
                const header: block.BlockHeader = @bitCast(try decompressor.in_stream.takeInt(u32, .little));

                break :blk .{
                    .uncompressed = header.uncompressed,
                    .size = header.size,
                };
            },

            else => unreachable,
        };
    }
};

fn testDecompressingStream(
    compressed_data: []const u8,
    expected_uncompressed_data: []const u8
) !void {
    const allocator = std.testing.allocator;

    var reader: std.Io.Reader = .fixed(compressed_data);

    var decompressor: Decompressor = try .init(allocator, &reader);
    defer decompressor.deinit();

    var allocating_writer: std.Io.Writer.Allocating = .init(allocator);
    defer allocating_writer.deinit();
    const writer = &allocating_writer.writer;

    const written = try decompressor.interface.streamRemaining(writer);

    try writer.flush();

    const result = writer.buffer[0..written];

    try testing.expect(std.mem.eql(u8, result, expected_uncompressed_data));
}

test "Decompress single frame (general format)" {
    try testDecompressingStream(
        @embedFile("lorem.txt.lz4"),
        @embedFile("lorem.txt"),
    );
}

test "Decompress single frame (legacy format)" {
    try testDecompressingStream(
        @embedFile("lorem.txt.legacy_frame.lz4"),
        @embedFile("lorem.txt"),
    );
}

test "Decompress concatenated frames (general format)" {
    try testDecompressingStream(
        @embedFile("lorem.txt.lz4") ++ @embedFile("lorem.txt.lz4"),
        @embedFile("lorem.txt") ++ @embedFile("lorem.txt"),
    );
}

test "Decompress concatenated frames (legacy format)" {
    try testDecompressingStream(
        @embedFile("lorem.txt.legacy_frame.lz4") ++ @embedFile("lorem.txt.legacy_frame.lz4"),
        @embedFile("lorem.txt") ++ @embedFile("lorem.txt"),
    );
}

test "Decompress concatenated frames (mixed formats)" {
    try testDecompressingStream(
        @embedFile("lorem.txt.legacy_frame.lz4") ++ @embedFile("lorem.txt.lz4") ++ @embedFile("lorem.txt.legacy_frame.lz4"),
        @embedFile("lorem.txt") ++ @embedFile("lorem.txt") ++ @embedFile("lorem.txt"),
    );
}
