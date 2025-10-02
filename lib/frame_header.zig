const std = @import("std");
const testing = std.testing;

pub const FrameType = enum {
    general,
    legacy,
    skippable,

    pub fn fromData(data: *const [4]u8) !FrameType {
        const magic = std.mem.readInt(u32, data, .little);

        return switch (magic) {
            0x184d2204 => .general,
            0x184c2102 => .legacy,
            0x184d2a50...0x184d2a5f => .skippable,

            else => error.InvalidMagic,
        };
    }
};

test "FrameType.fromData" {
    try testing.expect(try FrameType.fromData("\x04\x22\x4d\x18") == .general);
    try testing.expect(try FrameType.fromData("\x02\x21\x4c\x18") == .legacy);

    inline for (0x50 .. 0x5f) |byte| {
        try testing.expect(try FrameType.fromData(
            &[1]u8{byte} ++ "\x2a\x4d\x18") == .skippable,
        );
    }
}

pub const FrameDescriptor = struct {
    flags: FrameFlags,
    block_data: BlockData,
    content_size: ?u64,
    dictionary_id: ?u32,
    header_checksum: u8,

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

    pub const Options = struct {
        verify_checksum: bool = true,
    };

    pub fn isChecksumGood(self: FrameDescriptor) bool {
        var hash = std.hash.XxHash32.init(0);

        hash.update(&(@as([1]u8, @bitCast(self.flags))));
        hash.update(&(@as([1]u8, @bitCast(self.block_data))));

        if (self.content_size) |content_size| {
            hash.update(&(@as([8]u8, @bitCast(content_size))));
        }

        if (self.dictionary_id) |dictionary_id| {
            hash.update(&(@as([4]u8, @bitCast(dictionary_id))));
        }

        return ((hash.final() >> 8) & 0xff) == self.header_checksum;
    }

    pub fn takeFromStream(in_stream: *std.Io.Reader, options: Options) !FrameDescriptor {
        var frame_descriptor = FrameDescriptor{
            .content_size = null,
            .dictionary_id = null,

            .flags = undefined,
            .block_data = undefined,
            .header_checksum = undefined,
        };

        frame_descriptor.flags = @bitCast(try in_stream.takeByte());
        if (frame_descriptor.flags.version != 1) return error.UnsupportedVersion;
        

        frame_descriptor.block_data = @bitCast(try in_stream.takeByte());
        if (frame_descriptor.block_data._0 | frame_descriptor.block_data._7 > 0) {
            return error.ReservedBitsNotZero;
        }

        const block_max: u3 = @intFromEnum(frame_descriptor.block_data.max_size);
        if (block_max < 4 or block_max > 7) return error.InvalidBlockSize;

        if (frame_descriptor.flags.content.size_present) {
            frame_descriptor.content_size = try in_stream.takeInt(u64, .little);
        }

        if (frame_descriptor.flags.dictionary.id_present) {
            frame_descriptor.dictionary_id = try in_stream.takeInt(u32, .little);
        }

        frame_descriptor.header_checksum = try in_stream.takeByte();
        if (options.verify_checksum and !frame_descriptor.isChecksumGood()) {
            return error.BadFrameHeader;
        }

        return frame_descriptor;
    }
};

test "FrameDescriptor.takeFromStream" {
    {
        var reader: std.Io.Reader = .fixed("\x40\x40\xc0");
        const frame_descriptor = try FrameDescriptor.takeFromStream(&reader, .{});

        try testing.expect(frame_descriptor.flags.block.independent == false);
        try testing.expect(frame_descriptor.flags.block.checksum_present == false);
        try testing.expect(frame_descriptor.flags.content.size_present == false);
        try testing.expect(frame_descriptor.flags.content.checksum_present == false);
        try testing.expect(frame_descriptor.flags.dictionary.id_present == false);
    }
    {
        var reader: std.Io.Reader = .fixed("\x60\x40\x82");
        const frame_descriptor = try FrameDescriptor.takeFromStream(&reader, .{});

        try testing.expect(frame_descriptor.flags.block.independent == true);
        try testing.expect(frame_descriptor.flags.block.checksum_present == false);
        try testing.expect(frame_descriptor.flags.content.size_present == false);
        try testing.expect(frame_descriptor.flags.content.checksum_present == false);
        try testing.expect(frame_descriptor.flags.dictionary.id_present == false);
    }
}

pub const FrameHeader = union(FrameType) {
    general: FrameDescriptor,
    legacy: u32,
    skippable: u32,

    pub fn takeFromStream(in_stream: *std.Io.Reader) !FrameHeader {
        const header_bytes = try in_stream.takeArray(4);
        const header = try FrameType.fromData(header_bytes);

        return switch (header) {
            .general => .{
                .general = try FrameDescriptor.takeFromStream(in_stream, .{})
            },
            .legacy => .{
                .legacy = try in_stream.takeInt(u32, .little)
            },
            .skippable => .{
                .skippable = try in_stream.takeInt(u32, .little)
            },
        };
    }
};

test "Skippable FrameHeader" {
    {
        var reader: std.Io.Reader = .fixed("\x50\x2a\x4d\x18" ++ "\x01\x02\x03\x04");
        const frame_header = try FrameHeader.takeFromStream(&reader);
        try testing.expect(frame_header == .skippable);
    }
    {
        var reader: std.Io.Reader = .fixed("\x50\x2a\x4d\x18" ++ "\x01\x02\x03\x04");
        const frame_header = try FrameHeader.takeFromStream(&reader);
        try testing.expect(frame_header.skippable == 0x04030201);
    }
    {
        var reader: std.Io.Reader = .fixed("\x5f\x2a\x4d\x18" ++ "\x69\x00\x00\x00");
        const frame_header = try FrameHeader.takeFromStream(&reader);
        try testing.expect(frame_header.skippable == 0x69);
    }
}

test "Legacy FrameHeader" {
    {
        var reader: std.Io.Reader = .fixed("\x02\x21\x4c\x18" ++ "\x01\x02\x03\x04");
        const frame_header = try FrameHeader.takeFromStream(&reader);
        try testing.expect(frame_header == .legacy);
    }
    {
        var reader: std.Io.Reader = .fixed("\x02\x21\x4c\x18" ++ "\x01\x02\x03\x04");
        const frame_header = try FrameHeader.takeFromStream(&reader);
        try testing.expect(frame_header.legacy == 0x04030201);
    }
    {
        var reader: std.Io.Reader = .fixed("\x02\x21\x4c\x18" ++ "\xff\xff\xff\xff");
        const frame_header = try FrameHeader.takeFromStream(&reader);
        try testing.expect(frame_header.legacy == 0xffffffff);
    }
}

pub fn readContentChecksum(data: []const u8) !u32 {
    if (data.len < 4)
        return error.NotEnoughData;
    return std.mem.readInt(u32, data[0..4], .little);
}
