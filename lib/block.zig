const std = @import("std");
const testing = std.testing;
const mem = std.mem;

// For the frame format
pub const BlockHeader = packed struct(u32) {
    size: u31,
    uncompressed: bool,
};

test "BlockHeader" {
    const data = [_]u8{ 0xFE, 0xDE, 0xBC, 0x9A };
    const header: BlockHeader = @bitCast(mem.readInt(u32, &data, .little));

    try testing.expectEqual(header.size, 0x1ABCDEFE);
    try testing.expectEqual(header.uncompressed, true);
}

// General block functions

const Token = packed struct(u8) {
    match_length: u4,
    literal_length: u4,
};

test "Token" {
    const token: Token = @bitCast(@as(u8, 0x54));

    try testing.expectEqual(token.literal_length, 5);
    try testing.expectEqual(token.match_length, 4);
}

// returns the number of bytes read
pub fn determineLiteralLengh(token: Token, data: []const u8, length_out: *usize) !usize {
    return variableLengthIntegerWithHalfByteStart(token.literal_length, data, length_out);
}

test "determineLiteralLength" {
    {
        const data = [3]u8{ 0xF0, 33, 4 };
        var length: usize = undefined;
        const read = try determineLiteralLengh(@bitCast(data[0]), data[1..], &length);
        try testing.expectEqual(1, read);
        try testing.expectEqual(48, length);
    }
    {
        const data = [5]u8{ 0xF0, 255, 10, 22, 33 };
        var length: usize = undefined;
        const read = try determineLiteralLengh(@bitCast(data[0]), data[1..], &length);
        try testing.expectEqual(2, read);
        try testing.expectEqual(280, length);
    }
    {
        const data = [4]u8{ 0xF0, 0, 232, 21 };
        var length: usize = undefined;
        const read = try determineLiteralLengh(@bitCast(data[0]), data[1..], &length);
        try testing.expectEqual(1, read);
        try testing.expectEqual(15, length);
    }
    {
        const data = [4]u8{ 0xF0, 0xFF, 0xFF, 0xFF };
        var length: usize = undefined;
        try testing.expectError(error.IncompleteData, determineLiteralLengh(@bitCast(data[0]), data[1..], &length));
        try testing.expectEqual(15 + 255 + 255 + 255, length);
    }
}

const MatchOperation = struct {
    offset: u16, // 0 is invalid
    match_length: usize, // minimal value is 4
};

// Returns how many bytes have been read
pub fn readMatchOperation(token: Token, data: []const u8, operation: *MatchOperation) !usize {
    if (data.len < 2) {
        return error.NoEnoughData;
    }

    operation.offset = mem.readInt(u16, data[0..2], .little);
    const read: usize = 2;
    defer {
        operation.match_length += 4;
    }

    return (try variableLengthIntegerWithHalfByteStart(
        token.match_length,
        data[read..],
        &operation.match_length,
    )) + read;
}

fn variableLengthIntegerWithHalfByteStart(start: u4, data: []const u8, length_out: *usize) !usize {
    var length: usize = start;
    if (length < 0xF) {
        length_out.* = length;
        return 0;
    }
    for (data, 0..) |d, i| {
        length += d;
        if (d < 0xFF) {
            length_out.* = length;
            return i + 1;
        }
    }
    length_out.* = length;
    return error.IncompleteData;
}

test "readMatchOperation" {
    {
        const token = Token{ .literal_length = 0, .match_length = 10 };
        const data = .{ 0x04, 0x30, 0xFF, 32 };
        var operation: MatchOperation = undefined;
        const read = try readMatchOperation(token, &data, &operation);
        try testing.expectEqual(2, read);
        try testing.expectEqual(0x3004, operation.offset);
        try testing.expectEqual(14, operation.match_length);
    }
    {
        const token = Token{ .literal_length = 0, .match_length = 15 };
        const data = .{ 0x04, 0x30, 0xFF, 0x32 };
        var operation: MatchOperation = undefined;
        const read = try readMatchOperation(token, &data, &operation);
        try testing.expectEqual(4, read);
        try testing.expectEqual(0x3004, operation.offset);
        try testing.expectEqual(19 + 0xFF + 0x32, operation.match_length);
    }
    {
        const token = Token{ .literal_length = 0, .match_length = 15 };
        const data = [1]u8{0x04};
        var operation: MatchOperation = undefined;
        try testing.expectError(error.NoEnoughData, readMatchOperation(token, &data, &operation));
    }
    {
        const token = Token{ .literal_length = 0, .match_length = 15 };
        const data = [4]u8{ 0x04, 0x30, 0xFF, 0xFF };
        var operation: MatchOperation = undefined;
        try testing.expectError(error.IncompleteData, readMatchOperation(token, &data, &operation));
        try testing.expectEqual(0x3004, operation.offset);
        try testing.expectEqual(19 + 0xFF + 0xFF, operation.match_length);
    }
}

// Returns the end offset/last unwritten position
pub fn applyMatchOperation(operation: MatchOperation, uncompressed: []u8, start_offset: usize) usize {
    std.debug.assert(operation.offset > 0);
    std.debug.assert(start_offset >= operation.offset);

    const end_offset = start_offset + operation.match_length;
    mem.copyForwards(u8, uncompressed[start_offset..end_offset], uncompressed[start_offset - operation.offset .. end_offset - operation.offset]);
    return end_offset;
}

test "applyMatchOperation" {
    {
        var data = [_]u8{ 1, 2, 3, 4 } ++ (.{0} ** 100);
        const operation = MatchOperation{ .offset = 3, .match_length = 100 };
        const offset = applyMatchOperation(operation, data[0..], 4);
        try testing.expectEqual(data.len, offset);
        const expected_data = [_]u8{ 1, 2, 3, 4 } ++ [_]u8{ 2, 3, 4 } ** 33 ++ [_]u8{2};
        try testing.expectEqual(expected_data, data);
    }
    {
        var data = [_]u8{ 1, 2, 3, 4 } ++ (.{0} ** 100);
        const operation = MatchOperation{ .offset = 1, .match_length = 10 };
        const offset = applyMatchOperation(operation, data[0..], 4);
        try testing.expectEqual(14, offset);
        const expected_data = [_]u8{ 1, 2, 3, 4 } ++ [_]u8{4} ** 10;
        try testing.expectEqualSlices(u8, &expected_data, data[0..14]);
    }
    {
        var data = [_]u8{ 1, 2, 3, 4 } ++ (.{0} ** 100);
        const operation = MatchOperation{ .offset = 1, .match_length = 10 };
        const offset = applyMatchOperation(operation, data[0..], 4);
        try testing.expectEqual(14, offset);
        const expected_data = [_]u8{ 1, 2, 3, 4 } ++ [_]u8{4} ** 10;
        try testing.expectEqualSlices(u8, &expected_data, data[0..14]);
    }
}

pub fn decodeBlock(compressed: []const u8, read_out: *usize, uncompressed: []u8, written_out: *usize) !void {
    var read: usize = 0;
    var written: usize = 0;
    defer {
        read_out.* = read;
        written_out.* = written;
    }

    while (read < compressed.len) {
        const token: Token = @bitCast(compressed[read]);
        read += 1;
        var literal_length: usize = undefined;
        read += try determineLiteralLengh(token, compressed[read..], &literal_length);
        if (read + literal_length > compressed.len) {
            mem.copyForwards(u8, uncompressed[written..], compressed[read..]);
            written += compressed.len - read;
            read = compressed.len;
            return error.IncompleteData;
        }
        mem.copyForwards(u8, uncompressed[written..], compressed[read .. read + literal_length]);
        written += literal_length;
        read += literal_length;
        if (read < compressed.len) {
            var operation: MatchOperation = undefined;
            read += try readMatchOperation(token, compressed[read..], &operation);
            written = applyMatchOperation(operation, uncompressed, written);
        }
    }
}

test "decodeBlock" {
    {
        const compressed = .{ 0x8F, 1, 2, 3, 4, 5, 6, 7, 8, 0x02, 0x00, 0xFF, 0x04 };
        var data = [_]u8{0} ** 512;
        const expected_data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 } ++ .{ 7, 8 } ** 139;
        var read: usize = undefined;
        var written: usize = undefined;
        try decodeBlock(&compressed, &read, data[0..], &written);
        try testing.expectEqual(compressed.len, read);
        try testing.expectEqual(expected_data.len, written);
        try testing.expectEqualSlices(u8, &expected_data, data[0..expected_data.len]);
    }
    {
        const compressed = [_]u8{ 0x8F, 1, 2, 3, 4, 5, 6, 7, 8, 0x02, 0x00, 0x04 } ++ .{ 0x42, 4, 3, 2, 1, 0x04, 0x00 };
        var data = [_]u8{0} ** 512;
        const expected_data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 } ++ [_]u8{ 7, 8 } ** 11 ++ [_]u8{7} ++ [_]u8{ 4, 3, 2, 1 } ** 2 ++ [_]u8{ 4, 3 };
        var read: usize = undefined;
        var written: usize = undefined;
        try decodeBlock(&compressed, &read, data[0..], &written);
        try testing.expectEqual(compressed.len, read);
        try testing.expectEqual(expected_data.len, written);
        try testing.expectEqualSlices(u8, &expected_data, data[0..expected_data.len]);
    }
    {
        const compressed = .{ 0x8F, 1, 2, 3, 4 };
        var data = [_]u8{0} ** 512;
        const expected_data = .{ 1, 2, 3, 4 };
        var read: usize = undefined;
        var written: usize = undefined;
        try testing.expectError(error.IncompleteData, decodeBlock(&compressed, &read, data[0..], &written));
        try testing.expectEqual(compressed.len, read);
        try testing.expectEqual(4, written);
        try testing.expectEqualSlices(u8, &expected_data, data[0..expected_data.len]);
    }
    {
        const compressed = [_]u8{ 0x8F, 1, 2, 3, 4, 5, 6, 7, 8, 0x02, 0x00, 0x04 } ++ [_]u8{ 0x42, 4, 3, 2, 1, 0x04, 0x00 } ++ [_]u8{ 0x0F, 38, 0x00, 11 };
        var data = [_]u8{0} ** 512;
        const expected_data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 } ++ [_]u8{ 7, 8 } ** 11 ++ [_]u8{7} ++ [_]u8{ 4, 3, 2, 1 } ** 2 ++ [_]u8{ 4, 3 } ++
            [_]u8{ 4, 5, 6, 7, 8 } ++ [_]u8{ 7, 8 } ** 11 ++ [_]u8{7} ++ [_]u8{ 4, 3 };
        var read: usize = undefined;
        var written: usize = undefined;
        try decodeBlock(&compressed, &read, data[0..], &written);
        try testing.expectEqual(compressed.len, read);
        try testing.expectEqual(expected_data.len, written);
        try testing.expectEqualSlices(u8, &expected_data, data[0..expected_data.len]);
    }
}
