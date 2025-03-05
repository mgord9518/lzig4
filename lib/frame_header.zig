const std = @import("std");
const testing = std.testing;

pub const FrameType = enum {
    general,
    legacy,
    skippable,

    pub fn readFrameType(in_stream: anytype) !FrameType {
        const magic = try in_stream.reader().readInt(u32, .little);

        return switch (magic) {
            0x184d2204 => .general,
            0x184c2102 => .legacy,
            0x184d2a50...0x184d2a5f => .skippable,

            else => error.InvalidMagic,
        };
    }
};

pub const FrameFlags = packed struct(u8) {
    dictionary: packed struct(u1) {
        id_present: bool,
    },
    _1: u1,
    content: packed struct(u2) {
        checksum_present: bool,
        size_present: bool,
    },
    block: packed struct(u2) {
        checksum_present: bool,
        independent: bool,
    },
    version: u2,
};

pub const BlockData = packed struct(u8) {
    _0: u4,
    max_size: BlockMaximumSize,
    _7: u1,

    pub const BlockMaximumSize = enum(u3) {
        _64KiB = 4,
        _256KiB = 5,
        _1MiB = 6,
        _4MiB = 7,
        _,
    };
};

pub const FrameDescriptor = struct {
    flags: FrameFlags,
    block_data: BlockData,
    content_size: ?u64,
    dictionary_id: ?u32,
    header_checksum: u8,

    pub const Options = struct {
        verify_checksum: bool = true,
    };

    pub fn verifyChecksum(self: FrameDescriptor) error{BadFrameHeader}!void {
        var hash = std.hash.XxHash32.init(0);

        hash.update(&(@as([1]u8, @bitCast(self.flags))));
        hash.update(&(@as([1]u8, @bitCast(self.block_data))));

        if (self.content_size) |content_size| {
            hash.update(&(@as([8]u8, @bitCast(content_size))));
        }

        if (self.dictionary_id) |dictionary_id| {
            hash.update(&(@as([4]u8, @bitCast(dictionary_id))));
        }

        if (((hash.final() >> 8) & 0xff) != self.header_checksum) {
            return error.BadFrameHeader;
        }
    }

    pub fn readFrameDescriptor(in_stream: anytype, opts: Options) !FrameDescriptor {
        var frame_descriptor = FrameDescriptor{
            .content_size = null,
            .dictionary_id = null,

            .flags = undefined,
            .block_data = undefined,
            .header_checksum = undefined,
        };

        frame_descriptor.flags = @bitCast(try in_stream.reader().readByte());
        if (frame_descriptor.flags.version != 1) {
            return error.UnsupportedVersion;
        }

        frame_descriptor.block_data = @bitCast(try in_stream.reader().readByte());
        if (frame_descriptor.block_data._0 | frame_descriptor.block_data._7 > 0) return error.UnableToDecode;

        const block_max: u3 = @intFromEnum(frame_descriptor.block_data.max_size);
        if (block_max < 4 or block_max > 7) return error.InvalidBlockSize;

        if (frame_descriptor.flags.content.size_present) {
            frame_descriptor.content_size = try in_stream.reader().readInt(u64, .little);
        }

        if (frame_descriptor.flags.dictionary.id_present) {
            frame_descriptor.dictionary_id = try in_stream.reader().readInt(u32, .little);
        }

        frame_descriptor.header_checksum = try in_stream.reader().readByte();
        if (opts.verify_checksum) {
            try frame_descriptor.verifyChecksum();
        }

        return frame_descriptor;
    }
};

pub const FrameHeader = union(FrameType) {
    general: FrameDescriptor,
    legacy,
    skippable: u32,

    pub fn readFrameHeader(in_stream: anytype) !FrameHeader {
        var header = try FrameType.readFrameType(in_stream);

        // Discard all skippable headers we find
        // TODO: expose skippable frame headers to caller so they can
        // handle format extensions
        while (header == .skippable) : (header = try FrameType.readFrameType(in_stream)) {
            const size = try in_stream.reader().readInt(
                u32,
                .little,
            );

            try (in_stream.reader().skipBytes(size, .{}));
        }

        return switch (header) {
            .general => .{ .general = try FrameDescriptor.readFrameDescriptor(in_stream, .{}) },
            .legacy => .legacy,
            .skippable => unreachable,
        };
    }
};

pub fn readContentChecksum(data: []const u8) !u32 {
    if (data.len < 4)
        return error.NotEnoughData;
    return std.mem.readInt(u32, data[0..4], .little);
}

// TODO: rewrite tests for new functions

//test "magic" {
//    const dataInvalid = [4]u8{ 1, 2, 3, 4 };
//    try testing.expectError(error.InvalidMagic, handleMagic(&dataInvalid));
//    const dataCorrect = [4]u8{ 0x04, 0x22, 0x4D, 0x18 };
//    try testing.expectEqual(.general, try handleMagic(&dataCorrect));
//    const dataCorrectAndMore = [8]u8{ 0x04, 0x22, 0x4D, 0x18, 1, 2, 3, 4 };
//    try testing.expectEqual(.general, try handleMagic(dataCorrectAndMore[0..4]));
//    inline for ([_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }) |i| {
//        const dataSkippable = [4]u8{ 0x50 + i, 0x2A, 0x4D, 0x18 };
//        try testing.expectEqual(.skippable, try handleMagic(dataSkippable[0..4]));
//    }
//}

//test "frame descriptor errors" {
//    const dataShort: [2]u8 = undefined;
//    var frame_descriptor: FrameDescriptor = undefined;
//    try testing.expectError(error.NotEnoughData, readFrameDescriptor(&dataShort, &frame_descriptor));
//}

//test "frame version" {
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const dataInvalidVersion = .{ 0x00, 0x00, 0x00 };
//        try testing.expectError(error.UnsupportedVersion, readFrameDescriptor(&dataInvalidVersion, &frame_descriptor));
//    }
//
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const dataValidVersion = .{ 0x40, 0x40, 0x00 };
//        _ = try readFrameDescriptor(&dataValidVersion, &frame_descriptor);
//        try testing.expectEqual(frame_descriptor.flags.version, 1);
//    }
//}
//
//test "frame flags" {
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = [3]u8{ 0x40, 0x40, 0x00 };
//        _ = try readFrameDescriptor(&data, &frame_descriptor);
//        try testing.expectEqual(frame_descriptor.flags.block.independent, false);
//        try testing.expectEqual(frame_descriptor.flags.block.checksum_present, false);
//        try testing.expectEqual(frame_descriptor.flags.content.size_present, false);
//        try testing.expectEqual(frame_descriptor.flags.content.checksum_present, false);
//        try testing.expectEqual(frame_descriptor.flags.dictionary.id_present, false);
//    }
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = .{ 0x60, 0x40, 0x00 };
//        _ = try readFrameDescriptor(&data, &frame_descriptor);
//        try testing.expectEqual(frame_descriptor.flags.block.independent, true);
//        try testing.expectEqual(frame_descriptor.flags.block.checksum_present, false);
//        try testing.expectEqual(frame_descriptor.flags.content.size_present, false);
//        try testing.expectEqual(frame_descriptor.flags.content.checksum_present, false);
//        try testing.expectEqual(frame_descriptor.flags.dictionary.id_present, false);
//    }
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = .{ 0x50, 0x40, 0x00 };
//        _ = try readFrameDescriptor(&data, &frame_descriptor);
//        try testing.expectEqual(frame_descriptor.flags.block.independent, false);
//        try testing.expectEqual(frame_descriptor.flags.block.checksum_present, true);
//        try testing.expectEqual(frame_descriptor.flags.content.size_present, false);
//        try testing.expectEqual(frame_descriptor.flags.content.checksum_present, false);
//        try testing.expectEqual(frame_descriptor.flags.dictionary.id_present, false);
//    }
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = .{ 0x48, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
//        _ = try readFrameDescriptor(&data, &frame_descriptor);
//        try testing.expectEqual(frame_descriptor.flags.block.independent, false);
//        try testing.expectEqual(frame_descriptor.flags.block.checksum_present, false);
//        try testing.expectEqual(frame_descriptor.flags.content.size_present, true);
//        try testing.expectEqual(frame_descriptor.flags.content.checksum_present, false);
//        try testing.expectEqual(frame_descriptor.flags.dictionary.id_present, false);
//    }
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = .{ 0x44, 0x40, 0x00 };
//        _ = try readFrameDescriptor(&data, &frame_descriptor);
//        try testing.expectEqual(frame_descriptor.flags.block.independent, false);
//        try testing.expectEqual(frame_descriptor.flags.block.checksum_present, false);
//        try testing.expectEqual(frame_descriptor.flags.content.size_present, false);
//        try testing.expectEqual(frame_descriptor.flags.content.checksum_present, true);
//        try testing.expectEqual(frame_descriptor.flags.dictionary.id_present, false);
//    }
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = .{ 0x41, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00 };
//        _ = try readFrameDescriptor(&data, &frame_descriptor);
//        try testing.expectEqual(frame_descriptor.flags.block.independent, false);
//        try testing.expectEqual(frame_descriptor.flags.block.checksum_present, false);
//        try testing.expectEqual(frame_descriptor.flags.content.size_present, false);
//        try testing.expectEqual(frame_descriptor.flags.content.checksum_present, false);
//        try testing.expectEqual(frame_descriptor.flags.dictionary.id_present, true);
//    }
//}

//test "block data" {
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = [3]u8{ 0x40, 0x00, 0x00 };
//        try testing.expectError(error.InvalidBlockSize, readFrameDescriptor(&data, &frame_descriptor));
//    }
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = [3]u8{ 0x40, 0x80, 0x00 };
//        try testing.expectError(error.UnableToDecode, readFrameDescriptor(&data, &frame_descriptor));
//    }
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        for ([_]u2{ 0, 1, 2, 3 }) |i| {
//            const data = [3]u8{ 0x40, @as(u8, 1) << i, 0x00 };
//            try testing.expectError(error.UnableToDecode, readFrameDescriptor(&data, &frame_descriptor));
//        }
//    }
//    inline for (@typeInfo(BlockData.BlockMaximumSize).Enum.fields) |field| {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = [3]u8{ 0x40, @as(u8, field.value) << 4, 0x00 };
//        _ = try readFrameDescriptor(&data, &frame_descriptor);
//        try testing.expectEqual(@as(BlockData.BlockMaximumSize, @enumFromInt(field.value)), frame_descriptor.block_data.max_size);
//    }
//}

//test "Content Size" {
//    var frame_descriptor: FrameDescriptor = undefined;
//    const data = [11]u8{ 0x48, 0x40, 0xFE, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12, 0x00 };
//    _ = try readFrameDescriptor(&data, &frame_descriptor);
//    try testing.expectEqual(0x123456789ABCDEFE, frame_descriptor.content_size.?);
//}
//
//test "Dictionary Id" {
//    var frame_descriptor: FrameDescriptor = undefined;
//    const data = [7]u8{ 0x41, 0x40, 0xFE, 0xDE, 0xBC, 0x9A, 0x00 };
//    _ = try readFrameDescriptor(&data, &frame_descriptor);
//    try testing.expectEqual(0x9ABCDEFE, frame_descriptor.dictionary_id.?);
//}
//
//test "Header Checksum" {
//    var frame_descriptor: FrameDescriptor = undefined;
//    const data = [3]u8{ 0x40, 0x40, 0xFE };
//    _ = try readFrameDescriptor(&data, &frame_descriptor);
//    try testing.expectEqual(0xFE, frame_descriptor.header_checksum);
//}
//
//test "Content Size, Dictionary Id and Header Checksum" {
//    var frame_descriptor: FrameDescriptor = undefined;
//    const data = [15]u8{ 0x49, 0x40, 0xFE, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12, 0x21, 0x43, 0x65, 0x87, 0xF1 };
//    _ = try readFrameDescriptor(&data, &frame_descriptor);
//    try testing.expectEqual(0x123456789ABCDEFE, frame_descriptor.content_size.?);
//    try testing.expectEqual(0x87654321, frame_descriptor.dictionary_id.?);
//    try testing.expectEqual(0xF1, frame_descriptor.header_checksum);
//}
//
//test "Bytes read" {
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = [3]u8{ 0x40, 0x40, 0xFE };
//        try testing.expectEqual(3, try readFrameDescriptor(&data, &frame_descriptor));
//    }
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = [3]u8{ 0x40, 0x40, 0xFE } ++ [_]u8{0x00} ** 100;
//        try testing.expectEqual(3, try readFrameDescriptor(&data, &frame_descriptor));
//    }
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = [2]u8{ 0x48, 0x40 } ++ [_]u8{0x00} ** 100;
//        try testing.expectEqual(11, try readFrameDescriptor(&data, &frame_descriptor));
//    }
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = [2]u8{ 0x41, 0x40 } ++ [_]u8{0x00} ** 100;
//        try testing.expectEqual(7, try readFrameDescriptor(&data, &frame_descriptor));
//    }
//    {
//        var frame_descriptor: FrameDescriptor = undefined;
//        const data = [2]u8{ 0x49, 0x40 } ++ [_]u8{0x00} ** 100;
//        try testing.expectEqual(15, try readFrameDescriptor(&data, &frame_descriptor));
//    }
//}

//test "Skippable frame" {
//    const data = [4]u8{ 0x01, 0x02, 0x03, 0x04 };
//    var frame_descriptor: SkippableFrameDescriptor = undefined;
//    _ = try readSkippableFrameDescriptor(&data, &frame_descriptor);
//    try testing.expectEqual(0x04030201, frame_descriptor.size);
//    const dataShort: [3]u8 = undefined;
//    try testing.expectError(error.NotEnoughData, readSkippableFrameDescriptor(&dataShort, &frame_descriptor));
//}

//test "Read Frame Header" {
//    {
//        const skippableData = [4]u8{ 0x50, 0x2A, 0x4D, 0x18 } ++ [4]u8{ 0x01, 0x02, 0x03, 0x04 };
//        var frame_header: FrameHeader = undefined;
//        const read = try readFrameHeader(&skippableData, &frame_header);
//        try testing.expectEqual(8, read);
//        try testing.expect(frame_header == .skippable);
//        try testing.expectEqual(0x04030201, frame_header.skippable.size);
//    }
//    {
//        var frame_header: FrameHeader = undefined;
//        const data = [4]u8{ 0x04, 0x22, 0x4D, 0x18 } ++ [3]u8{ 0x40, 0x40, 0xFE };
//        const read = try readFrameHeader(&data, &frame_header);
//        try testing.expectEqual(7, read);
//        try testing.expect(frame_header == .general);
//        try testing.expectEqual(0xFE, frame_header.general.header_checksum);
//    }
//}
