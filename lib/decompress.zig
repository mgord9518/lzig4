const std = @import("std");
const testing = std.testing;

const frame = @import("frame_header.zig");
const block = @import("block.zig");

pub const DecompressorOptions = struct {
    verify_checksum: bool = true,
};

pub fn Decompressor(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        off: usize,
        compressed_buf: std.ArrayList(u8),
        decompress_buf: std.ArrayList(u8),
        reader: ReaderType,
        current_frame_header: frame.FrameHeader,

        pub fn init(allocator: std.mem.Allocator, reader: ReaderType) !Self {
            const compressed_buf = std.ArrayList(u8).init(allocator);
            const decompress_buf = std.ArrayList(u8).init(allocator);

            var self = Self{
                .off = 0,
                .compressed_buf = compressed_buf,
                .decompress_buf = decompress_buf,
                .reader = reader,
                .current_frame_header = undefined,
            };

            var header = try frame.handleMagicInt(try reader.reader().readInt(
                u32,
                .little,
            ));

            while (header == .skippable) {
                const size = try reader.reader().readInt(
                    u32,
                    .little,
                );

                try (reader.reader().skipBytes(size, .{}));

                header = try frame.handleMagicInt(try reader.reader().readInt(
                    u32,
                    .little,
                ));
            }

            self.current_frame_header = switch (header) {
                .general => .{ .general = try self.readFrameDescriptor() },
                .legacy => .legacy,
                .skippable => unreachable,
                else => unreachable,
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.compressed_buf.deinit();
            self.decompress_buf.deinit();
        }

        fn readFrameDescriptor(self: *Self) !frame.FrameDescriptor {
            var frame_descriptor = frame.FrameDescriptor{
                .flags = undefined,
                .block_data = undefined,
                .content_size = null,
                .dictionary_id = null,
                .header_checksum = undefined,
            };

            frame_descriptor.flags = @bitCast(try self.reader.reader().readByte());
            if (frame_descriptor.flags.version != 1) {
                return error.UnsupportedVersion;
            }

            frame_descriptor.block_data = @bitCast(try self.reader.reader().readByte());
            if (frame_descriptor.block_data._0 | frame_descriptor.block_data._7 > 0) return error.UnableToDecode;

            const block_max: u3 = @intFromEnum(frame_descriptor.block_data.max_size);
            if (block_max < 4 or block_max > 7) return error.InvalidBlockSize;

            if (frame_descriptor.flags.content.size_present) {
                frame_descriptor.content_size = try self.reader.reader().readInt(u64, .little);
            }

            if (frame_descriptor.flags.dictionary.id_present) {
                frame_descriptor.dictionary_id = try self.reader.reader().readInt(u32, .little);
            }

            frame_descriptor.header_checksum = try self.reader.reader().readByte();

            return frame_descriptor;
        }

        fn decompressBlockInPlace(self: *Self, buf: []u8) !usize {
            var read_out: usize = 0;
            var written_out: usize = 0;

            try block.decodeBlock(
                self.compressed_buf.items,
                &read_out,
                buf,
                &written_out,
            );

            return written_out;
        }

        pub fn read(self: *Self, buf: []u8) !usize {
            const decompressed_block_size = try self.decompressedBlockSize();

            // Made it to the end of the buffer (or haven't populated it yet)
            if (self.off == self.decompress_buf.items.len) {
                self.loadCompressedBuffer() catch |err| {
                    switch (err) {
                        error.EndOfStream => return 0,

                        // TODO: load another frame descriptor
                        error.EndMark => return 0,
                        //                        error.BlockNotCompressed => {
                        //                            const block_size = try self.reader.reader().readInt(u32, .little);
                        //
                        //                            return try self.reader.reader().readAll(buf[0..block_size]);
                        //                        },

                        else => return err,
                    }
                };
            }

            // The entire block must be decoded at once. Try to use the
            // caller's buffer, falling back on an internal one if it's too small
            if (self.off == 0 and decompressed_block_size <= buf.len) {
                return self.decompressBlockInPlace(buf);
            } else if (self.off == self.decompress_buf.items.len) {
                try self.growDecompressBufferIfNeeded();
                self.off = 0;
            }

            const take = @min(
                buf.len,
                self.decompress_buf.items[self.off..].len,
            );

            @memcpy(
                buf[0..take],
                self.decompress_buf.items[self.off..][0..take],
            );

            self.off += take;

            return take;
        }

        // Reads an entire compressed block into the buffer
        fn loadCompressedBuffer(self: *Self) !void {
            const compressed_block_size = switch (self.current_frame_header) {
                // TODO: check if another frame header
                .legacy => try self.reader.reader().readInt(u32, .little),

                .general => blk: {
                    const header: block.BlockHeader = @bitCast(try self.reader.reader().readInt(u32, .little));

                    if (header.uncompressed) return error.BlockNotCompressed;
                    if (header.size == 0) return error.EndMark;

                    break :blk header.size;
                },
                else => unreachable,
            };

            if (compressed_block_size > self.compressed_buf.capacity) {
                try self.compressed_buf.resize(compressed_block_size);
            }

            const read_amount = try self.reader.reader().readAll(self.compressed_buf.items);

            if (read_amount != compressed_block_size) return error.ShortRead;

            self.compressed_buf.shrinkRetainingCapacity(read_amount);
        }

        // Gets size of decompressed block based on current frame type
        fn decompressedBlockSize(self: *const Self) !usize {
            return switch (self.current_frame_header) {
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

        // Blocks must be fully decompressed before use, so we stuff a buffer
        // for easier reading
        pub fn growDecompressBufferIfNeeded(self: *Self) !void {
            const decompressed_block_size = try self.decompressedBlockSize();

            // Block is bigger than current buffer, grow it
            if (decompressed_block_size > self.decompress_buf.capacity) {
                try self.decompress_buf.resize(decompressed_block_size);
            }

            var read_out: usize = undefined;
            var written_out: usize = undefined;

            try block.decodeBlock(
                self.compressed_buf.items,
                &read_out,
                self.decompress_buf.items[0..decompressed_block_size],
                &written_out,
            );

            self.decompress_buf.shrinkRetainingCapacity(written_out);
        }
    };
}

pub const OldDecompressor = struct {
    off: usize,
    buf: std.ArrayList(u8),
    frame_header: frame.FrameHeader,

    pub fn init(allocator: std.mem.Allocator) OldDecompressor {
        const buf = std.ArrayList(u8).init(allocator);

        return .{
            .off = 0,
            .buf = buf,

            // Gets populated on the first run of `decompress`
            .frame_header = undefined,
        };
    }

    pub fn deinit(self: *OldDecompressor) void {
        self.buf.deinit();
    }

    pub fn decompress(
        self: *OldDecompressor,
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
                .legacy => {
                    var frame_read: usize = 0;
                    var frame_written: usize = 0;
                    defer {
                        read += frame_read;
                        written += frame_written;
                    }

                    try self.decompressLegacyFrame(
                        compressed[read..],
                        &frame_read,
                        decompressed[written..],
                        &frame_written,
                    );
                },
            }
        }
    }

    /// Decompresses raw LZ4 data, like LZ4_decompress_default from liblz4
    pub fn decompressRaw(
        self: *const OldDecompressor,
        compressed: []const u8,
        read_out: *usize,
        decompressed: []u8,
        written_out: *usize,
    ) !void {
        _ = self;

        return block.decodeBlock(compressed, read_out, decompressed, written_out);
    }

    fn decompressLegacyFrame(
        self: *const OldDecompressor,
        compressed: []const u8,
        read_out: *usize,
        decompressed: []u8,
        written_out: *usize,
    ) !void {
        var read: usize = 0;
        var written: usize = 0;

        defer {
            read_out.* = read;
            written_out.* = written;
        }

        var block_size = std.mem.readInt(
            u32,
            compressed[read..][0..4],
            .little,
        );
        read += 4;

        while (block_size > 0 and block_size != @intFromEnum(frame.FrameHeader.legacy)) {
            var decode_read: usize = undefined;
            var decode_written: usize = undefined;

            try self.decompressRaw(
                compressed[read..][0..block_size],
                &decode_read,
                decompressed[written..],
                &decode_written,
            );

            if (compressed[read..].len < 4) {
                return error.NotEnoughData;
            }

            read += decode_read;
            written += decode_written;

            if (read >= block_size) break;

            block_size = std.mem.readInt(
                u32,
                compressed[read..][0..4],
                .little,
            );
        }
    }

    fn decompressGeneralFrame(
        self: *const OldDecompressor,
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
