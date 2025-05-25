const std = @import("std");
const testing = std.testing;

pub const frame = @import("frame_header.zig");
pub const block = @import("block.zig");

pub const DecompressorOptions = struct {
    verify_checksum: bool = true,
};

pub fn decompress(allocator: std.mem.Allocator, reader: anytype) !Decompressor(@TypeOf(reader)) {
    return try Decompressor(@TypeOf(reader)).init(allocator, reader);
}

pub fn Decompressor(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        off: usize,
        compressed_buf: std.ArrayList(u8),
        decompress_buf: std.ArrayList(u8),
        in_stream: ReaderType,
        current_frame_header: frame.FrameHeader,

        pub const Reader = std.io.Reader(Self, ReadError, read);
        //pub const ReadError = error{InvalidBlockSize};
        // TODO
        pub const ReadError = anyerror;

        pub fn init(allocator: std.mem.Allocator, in_stream: ReaderType) !Self {
            const compressed_buf = std.ArrayList(u8).init(allocator);
            const decompress_buf = std.ArrayList(u8).init(allocator);

            var self = Self{
                .off = 0,
                .compressed_buf = compressed_buf,
                .decompress_buf = decompress_buf,
                .in_stream = in_stream,
                .current_frame_header = undefined,
            };

            self.current_frame_header = try self.readFrameHeader();

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.compressed_buf.deinit();
            self.decompress_buf.deinit();
        }


        pub fn readFrameHeader(self: *Self) !frame.FrameHeader {
            return frame.FrameHeader.readFrameHeader(self.in_stream);
        }

        pub fn read(self: *Self, buf: []u8) ReadError!usize {
            const decompressed_block_size = try self.decompressedBlockSize();

            // Made it to the end of the buffer (or haven't populated it yet)
            if (self.off == self.decompress_buf.items.len) {
                self.loadCompressedBuffer() catch |err| {
                    switch (err) {
                        error.EndOfStream => return 0,

                        // TODO: load another frame descriptor
                        error.EndMark => return 0,
                        //                        error.BlockNotCompressed => {
                        //                            const block_size = try self.in_stream.reader().readInt(u32, .little);
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
                var read_out: usize = 0;
                var written_out: usize = 0;

                try block.decodeBlock(
                    self.compressed_buf.items,
                    &read_out,
                    buf,
                    &written_out,
                );

                return written_out;
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
                .legacy => try self.in_stream.readInt(u32, .little),

                .general => blk: {
                    const header: block.BlockHeader = @bitCast(try self.in_stream.readInt(u32, .little));

                    if (header.uncompressed) return error.BlockNotCompressed;
                    if (header.size == 0) return error.EndMark;

                    break :blk header.size;
                },
                else => unreachable,
            };

            if (compressed_block_size > self.compressed_buf.capacity) {
                try self.compressed_buf.resize(compressed_block_size);
            }

            const read_amount = try self.in_stream.readAll(self.compressed_buf.items);

            if (read_amount != compressed_block_size) return error.ShortRead;

            self.compressed_buf.shrinkRetainingCapacity(read_amount);
        }

        // Gets size of decompressed block based on current frame type
        fn decompressedBlockSize(self: *const Self) error{InvalidBlockSize}!usize {
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

test {
    std.testing.refAllDecls(@This());
}

test "Decompress lorem ipsum (modern frame format)" {
    const allocator = std.testing.allocator;

    const compressed = @embedFile("lorem.txt.lz4");
    const expected = @embedFile("lorem.txt");

    var buf: [512]u8 = undefined;

    var fbs = std.io.fixedBufferStream(compressed);

    var decompressor = try decompress(allocator, fbs.reader());
    defer decompressor.deinit();

    const read_amount = try decompressor.read(&buf);

    try testing.expectEqual(expected.len, read_amount);
    try testing.expectEqualSlices(u8, expected, buf[0..read_amount]);
}

test "Decompress lorem ipsum (legacy frame format)" {
    const allocator = std.testing.allocator;

    const compressed = @embedFile("lorem.txt.legacy_frame.lz4");
    const expected = @embedFile("lorem.txt");

    var buf: [512]u8 = undefined;

    var fbs = std.io.fixedBufferStream(compressed);

    var decompressor = try decompress(allocator, fbs.reader());
    defer decompressor.deinit();

    const read_amount = try decompressor.read(&buf);

    try testing.expectEqual(expected.len, read_amount);
    try testing.expectEqualSlices(u8, expected, buf[0..read_amount]);
}
