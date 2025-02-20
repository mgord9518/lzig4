const std = @import("std");
const testing = std.testing;

const frame = @import("frame_header.zig");
const block = @import("block.zig");

pub const Decompressor = struct {
    frame_header: frame.FrameHeader,

    pub fn init() Decompressor {
        return .{
            // Gets populated on the first run of `decompress`
            .frame_header = undefined,
        };
    }

    pub fn decompress(
        self: *Decompressor,
        compressed: []const u8,
        read_out: *usize,
        decompressed: []u8,
        written_out: *usize,
    ) !void {
        var read: usize = 0;
        var written: usize = 0;
        while (read < compressed.len and written < decompressed.len) {
            read = try frame.readFrameHeader(compressed, &self.frame_header);
            defer {
                read_out.* = read;
                written_out.* = written;
            }
            switch (self.frame_header) {
                .general => {
                    var frame_read: usize = 0;
                    var frame_written: usize = 0;
                    defer {
                        read += frame_read;
                        written += frame_written;
                    }

                    try self.decompressGeneralFrame(
                        compressed[read..],
                        &frame_read,
                        decompressed[written..],
                        &frame_written,
                    );
                },
                .skippable => |value| {
                    read += value.size;
                },
                .legacy => {},
            }
        }
    }

    /// Decompresses raw LZ4 data, like LZ4_decompress_default from liblz4
    pub fn decompressRaw(
        self: *const Decompressor,
        compressed: []const u8,
        read_out: *usize,
        decompressed: []u8,
        written_out: *usize,
    ) !void {
        _ = self;

        return block.decodeBlock(compressed, read_out, decompressed, written_out);
    }

    fn decompressGeneralFrame(
        self: *const Decompressor,
        compressed: []const u8,
        read_out: *usize,
        decompressed: []u8,
        written_out: *usize,
    ) !void {
        const frame_descriptor = &self.frame_header.general;
        var read: usize = 0;
        var written: usize = 0;

        defer {
            read_out.* = read;
            written_out.* = written;
        }

        var header = block.BlockHeader{
            .size = 0x7fffffff,
            .uncompressed = false,
        };

        while (header.size != 0) {
            if (compressed[read..].len < 4) {
                return error.NotEnoughData;
            }

            header = @bitCast(std.mem.readInt(u32, compressed[read..][0..4], .little));
            read += @sizeOf(block.BlockHeader);

            if (header.uncompressed) {
                @memcpy(
                    decompressed[written..][0..header.size],
                    compressed[read..][0..header.size],
                );

                read += header.size;
                written += header.size;
            } else {
                var decode_read: usize = undefined;
                var decode_written: usize = undefined;
                defer {
                    read += decode_read;
                    written += decode_written;
                }

                try self.decompressRaw(
                    compressed[read .. read + header.size],
                    &decode_read,
                    decompressed[written..],
                    &decode_written,
                );
            }
        }

        if (frame_descriptor.flags.content.checksum_present) {
            _ = try frame.readContentChecksum(compressed[read..]);
            read += 4;
        }
    }
};

test "decompress simple" {
    const block1 = .{ 0x8F, 1, 2, 3, 4, 5, 6, 7, 8, 0x02, 0x00, 0xFF, 0x04 };
    const compressed = [4]u8{ 0x04, 0x22, 0x4D, 0x18 } ++
        .{ 0x40, 0x40, 0xFE } ++
        .{ @as(u8, block1.len), 0x00, 0x00, 0x00 } ++
        block1 ++ .{ 0x00, 0x00, 0x00, 0x00 };

    var data = [_]u8{0} ** 512;
    const expected_data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 } ++ .{ 7, 8 } ** 139;
    var decompressor = Decompressor.init();
    var read: usize = undefined;
    var written: usize = undefined;
    try decompressor.decompress(&compressed, &read, data[0..], &written);
    try testing.expectEqual(compressed.len, read);
    try testing.expectEqual(expected_data.len, written);
    try testing.expectEqualSlices(u8, &expected_data, data[0..expected_data.len]);
}

test "decompress small lorem ipsum" {
    const compressed = @embedFile("lorem.txt.lz4");
    const expected = @embedFile("lorem.txt");
    var data = [_]u8{0} ** 1024;
    var decompressor: Decompressor = undefined;
    var read: usize = undefined;
    var written: usize = undefined;
    try decompressor.decompress(compressed, &read, data[0..], &written);
    try testing.expectEqual(compressed.len, read);
    try testing.expectEqual(expected.len, written);
    try testing.expectEqualSlices(u8, expected, data[0..expected.len]);
}
