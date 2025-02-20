const std = @import("std");
const testing = std.testing;
const mem = std.mem;

pub const FrameType = enum(u32) {
    general = 0x184d2204,
    skippable = 0x184d2a50, // All values up to 0x184d2a5f are skippable
    legacy = 0x184c2102,

    fn isSkippable(frame_type: FrameType) bool {
        const magic_int = @intFromEnum(frame_type);

        return magic_int & 0xfffffff0 == @intFromEnum(FrameType.skippable);
    }
};

// returns the frame type, will always read 4 bytes if available
fn handleMagic(data: *const [4]u8) !FrameType {
    if (data.len < 4) {
        return error.NotEnoughData;
    }

    const magic_int = mem.readInt(u32, data[0..4], .little);
    if (magic_int & 0xfffffff0 == @intFromEnum(FrameType.skippable)) {
        return .skippable;
    }

    return std.meta.intToEnum(
        FrameType,
        magic_int,
    ) catch return error.InvalidMagic;
}

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
};

pub const SkippableFrameDescriptor = struct {
    size: u32,
};

pub const FrameHeader = union(FrameType) {
    general: FrameDescriptor,
    skippable: SkippableFrameDescriptor,

    // TODO
    legacy,
};

fn readBlockData(data: u8) !BlockData {
    const block: BlockData = @bitCast(data);

    if (block._0 | block._7 > 0) return error.UnableToDecode;

    const block_max: u3 = @intFromEnum(block.max_size);
    if (block_max < 4 or block_max > 7) return error.InvalidBlockSize;

    return block;
}

// returns how much data is has read from the input
fn readFrameDescriptor(data: []const u8, frame_descriptor: *FrameDescriptor) !usize {
    if (data.len < 3) {
        return error.NotEnoughData;
    }

    frame_descriptor.flags = @bitCast(data[0]);
    if (frame_descriptor.flags.version != 1) {
        return error.UnsupportedVersion;
    }

    frame_descriptor.block_data = try readBlockData(data[1]);

    var read: usize = 2;
    if (frame_descriptor.flags.content.size_present) {
        if (data.len < read + 9)
            return error.NotEnoughData;
        frame_descriptor.content_size = mem.readInt(u64, data[read..][0..8], .little);
        read += 8;
    }
    if (frame_descriptor.flags.dictionary.id_present) {
        if (data.len < read + 5)
            return error.NotEnoughData;
        frame_descriptor.dictionary_id = mem.readInt(u32, data[read..][0..4], .little);
        read += 4;
    }
    frame_descriptor.header_checksum = data[read];
    read += 1;
    return read;
}

// Returns the number of bytes read from `data`
fn readSkippableFrameDescriptor(data: []const u8, frame_descriptor: *SkippableFrameDescriptor) !usize {
    if (data.len < 4)
        return error.NotEnoughData;
    frame_descriptor.size = mem.readInt(u32, data[0..4], .little);
    return 4;
}

// Returns the number of bytes read from `data`
pub fn readFrameHeader(data: []const u8, frame_header: *FrameHeader) !usize {
    if (data.len < 4) {
        return error.NotEnoughData;
    }

    const read = switch (try handleMagic(data[0..4])) {
        .general => blk: {
            frame_header.* = FrameHeader{ .general = undefined };
            break :blk try readFrameDescriptor(data[4..], &frame_header.general);
        },
        .skippable => blk: {
            frame_header.* = FrameHeader{ .skippable = undefined };
            break :blk try readSkippableFrameDescriptor(data[4..], &frame_header.skippable);
        },
        .legacy => 0,
    };

    return read + 4;
}

pub fn readContentChecksum(data: []const u8) !u32 {
    if (data.len < 4)
        return error.NotEnoughData;
    return mem.readInt(u32, data[0..4], .little);
}

test "magic" {
    const dataInvalid = [4]u8{ 1, 2, 3, 4 };
    try testing.expectError(error.InvalidMagic, handleMagic(&dataInvalid));
    const dataCorrect = [4]u8{ 0x04, 0x22, 0x4D, 0x18 };
    try testing.expectEqual(.general, try handleMagic(&dataCorrect));
    const dataCorrectAndMore = [8]u8{ 0x04, 0x22, 0x4D, 0x18, 1, 2, 3, 4 };
    try testing.expectEqual(.general, try handleMagic(dataCorrectAndMore[0..4]));
    inline for ([_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }) |i| {
        const dataSkippable = [4]u8{ 0x50 + i, 0x2A, 0x4D, 0x18 };
        try testing.expectEqual(.skippable, try handleMagic(dataSkippable[0..4]));
    }
}

test "frame descriptor errors" {
    const dataShort: [2]u8 = undefined;
    var frame_descriptor: FrameDescriptor = undefined;
    try testing.expectError(error.NotEnoughData, readFrameDescriptor(&dataShort, &frame_descriptor));
}

test "frame version" {
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const dataInvalidVersion = .{ 0x00, 0x00, 0x00 };
        try testing.expectError(error.UnsupportedVersion, readFrameDescriptor(&dataInvalidVersion, &frame_descriptor));
    }

    {
        var frame_descriptor: FrameDescriptor = undefined;
        const dataValidVersion = .{ 0x40, 0x40, 0x00 };
        _ = try readFrameDescriptor(&dataValidVersion, &frame_descriptor);
        try testing.expectEqual(frame_descriptor.flags.version, 1);
    }
}

test "frame flags" {
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{ 0x40, 0x40, 0x00 };
        _ = try readFrameDescriptor(&data, &frame_descriptor);
        try testing.expectEqual(frame_descriptor.flags.block.independent, false);
        try testing.expectEqual(frame_descriptor.flags.block.checksum_present, false);
        try testing.expectEqual(frame_descriptor.flags.content.size_present, false);
        try testing.expectEqual(frame_descriptor.flags.content.checksum_present, false);
        try testing.expectEqual(frame_descriptor.flags.dictionary.id_present, false);
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = .{ 0x60, 0x40, 0x00 };
        _ = try readFrameDescriptor(&data, &frame_descriptor);
        try testing.expectEqual(frame_descriptor.flags.block.independent, true);
        try testing.expectEqual(frame_descriptor.flags.block.checksum_present, false);
        try testing.expectEqual(frame_descriptor.flags.content.size_present, false);
        try testing.expectEqual(frame_descriptor.flags.content.checksum_present, false);
        try testing.expectEqual(frame_descriptor.flags.dictionary.id_present, false);
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = .{ 0x50, 0x40, 0x00 };
        _ = try readFrameDescriptor(&data, &frame_descriptor);
        try testing.expectEqual(frame_descriptor.flags.block.independent, false);
        try testing.expectEqual(frame_descriptor.flags.block.checksum_present, true);
        try testing.expectEqual(frame_descriptor.flags.content.size_present, false);
        try testing.expectEqual(frame_descriptor.flags.content.checksum_present, false);
        try testing.expectEqual(frame_descriptor.flags.dictionary.id_present, false);
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = .{ 0x48, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
        _ = try readFrameDescriptor(&data, &frame_descriptor);
        try testing.expectEqual(frame_descriptor.flags.block.independent, false);
        try testing.expectEqual(frame_descriptor.flags.block.checksum_present, false);
        try testing.expectEqual(frame_descriptor.flags.content.size_present, true);
        try testing.expectEqual(frame_descriptor.flags.content.checksum_present, false);
        try testing.expectEqual(frame_descriptor.flags.dictionary.id_present, false);
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = .{ 0x44, 0x40, 0x00 };
        _ = try readFrameDescriptor(&data, &frame_descriptor);
        try testing.expectEqual(frame_descriptor.flags.block.independent, false);
        try testing.expectEqual(frame_descriptor.flags.block.checksum_present, false);
        try testing.expectEqual(frame_descriptor.flags.content.size_present, false);
        try testing.expectEqual(frame_descriptor.flags.content.checksum_present, true);
        try testing.expectEqual(frame_descriptor.flags.dictionary.id_present, false);
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = .{ 0x41, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00 };
        _ = try readFrameDescriptor(&data, &frame_descriptor);
        try testing.expectEqual(frame_descriptor.flags.block.independent, false);
        try testing.expectEqual(frame_descriptor.flags.block.checksum_present, false);
        try testing.expectEqual(frame_descriptor.flags.content.size_present, false);
        try testing.expectEqual(frame_descriptor.flags.content.checksum_present, false);
        try testing.expectEqual(frame_descriptor.flags.dictionary.id_present, true);
    }
}

test "block data" {
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{ 0x40, 0x00, 0x00 };
        try testing.expectError(error.InvalidBlockSize, readFrameDescriptor(&data, &frame_descriptor));
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{ 0x40, 0x80, 0x00 };
        try testing.expectError(error.UnableToDecode, readFrameDescriptor(&data, &frame_descriptor));
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        for ([_]u2{ 0, 1, 2, 3 }) |i| {
            const data = [3]u8{ 0x40, @as(u8, 1) << i, 0x00 };
            try testing.expectError(error.UnableToDecode, readFrameDescriptor(&data, &frame_descriptor));
        }
    }
    inline for (@typeInfo(BlockData.BlockMaximumSize).Enum.fields) |field| {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{ 0x40, @as(u8, field.value) << 4, 0x00 };
        _ = try readFrameDescriptor(&data, &frame_descriptor);
        try testing.expectEqual(@as(BlockData.BlockMaximumSize, @enumFromInt(field.value)), frame_descriptor.block_data.max_size);
    }
}

test "Content Size" {
    var frame_descriptor: FrameDescriptor = undefined;
    const data = [11]u8{ 0x48, 0x40, 0xFE, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12, 0x00 };
    _ = try readFrameDescriptor(&data, &frame_descriptor);
    try testing.expectEqual(0x123456789ABCDEFE, frame_descriptor.content_size.?);
}

test "Dictionary Id" {
    var frame_descriptor: FrameDescriptor = undefined;
    const data = [7]u8{ 0x41, 0x40, 0xFE, 0xDE, 0xBC, 0x9A, 0x00 };
    _ = try readFrameDescriptor(&data, &frame_descriptor);
    try testing.expectEqual(0x9ABCDEFE, frame_descriptor.dictionary_id.?);
}

test "Header Checksum" {
    var frame_descriptor: FrameDescriptor = undefined;
    const data = [3]u8{ 0x40, 0x40, 0xFE };
    _ = try readFrameDescriptor(&data, &frame_descriptor);
    try testing.expectEqual(0xFE, frame_descriptor.header_checksum);
}

test "Content Size, Dictionary Id and Header Checksum" {
    var frame_descriptor: FrameDescriptor = undefined;
    const data = [15]u8{ 0x49, 0x40, 0xFE, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12, 0x21, 0x43, 0x65, 0x87, 0xF1 };
    _ = try readFrameDescriptor(&data, &frame_descriptor);
    try testing.expectEqual(0x123456789ABCDEFE, frame_descriptor.content_size.?);
    try testing.expectEqual(0x87654321, frame_descriptor.dictionary_id.?);
    try testing.expectEqual(0xF1, frame_descriptor.header_checksum);
}

test "Bytes read" {
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{ 0x40, 0x40, 0xFE };
        try testing.expectEqual(3, try readFrameDescriptor(&data, &frame_descriptor));
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{ 0x40, 0x40, 0xFE } ++ [_]u8{0x00} ** 100;
        try testing.expectEqual(3, try readFrameDescriptor(&data, &frame_descriptor));
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [2]u8{ 0x48, 0x40 } ++ [_]u8{0x00} ** 100;
        try testing.expectEqual(11, try readFrameDescriptor(&data, &frame_descriptor));
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [2]u8{ 0x41, 0x40 } ++ [_]u8{0x00} ** 100;
        try testing.expectEqual(7, try readFrameDescriptor(&data, &frame_descriptor));
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [2]u8{ 0x49, 0x40 } ++ [_]u8{0x00} ** 100;
        try testing.expectEqual(15, try readFrameDescriptor(&data, &frame_descriptor));
    }
}

test "Skippable frame" {
    const data = [4]u8{ 0x01, 0x02, 0x03, 0x04 };
    var frame_descriptor: SkippableFrameDescriptor = undefined;
    _ = try readSkippableFrameDescriptor(&data, &frame_descriptor);
    try testing.expectEqual(0x04030201, frame_descriptor.size);
    const dataShort: [3]u8 = undefined;
    try testing.expectError(error.NotEnoughData, readSkippableFrameDescriptor(&dataShort, &frame_descriptor));
}

test "Read Frame Header" {
    {
        const skippableData = [4]u8{ 0x50, 0x2A, 0x4D, 0x18 } ++ [4]u8{ 0x01, 0x02, 0x03, 0x04 };
        var frame_header: FrameHeader = undefined;
        const read = try readFrameHeader(&skippableData, &frame_header);
        try testing.expectEqual(8, read);
        try testing.expect(frame_header == .skippable);
        try testing.expectEqual(0x04030201, frame_header.skippable.size);
    }
    {
        var frame_header: FrameHeader = undefined;
        const data = [4]u8{ 0x04, 0x22, 0x4D, 0x18 } ++ [3]u8{ 0x40, 0x40, 0xFE };
        const read = try readFrameHeader(&data, &frame_header);
        try testing.expectEqual(7, read);
        try testing.expect(frame_header == .general);
        try testing.expectEqual(0xFE, frame_header.general.header_checksum);
    }
}
