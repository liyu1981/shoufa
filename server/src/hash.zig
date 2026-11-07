//! Hash value helpers: memory accounting and the on-disk object format.
//!
//! Values are stored as a compact length-prefixed binary blob in the object
//! directory. The format is intentionally simple and checksummed:
//!
//!     "SHF1" | field_count:u32 | (key_len:u32, value_len:u32, key, value)* | crc32:u32
//!
//! All integers are little-endian. The checksum covers every byte before it.

const std = @import("std");

pub const Hash = std.StringHashMapUnmanaged([]u8);

pub const FIELD_OVERHEAD: usize = 48;
pub const VALUE_OVERHEAD: usize = 24;

const magic = "SHF1";
const header_len = magic.len + @sizeOf(u32);
const trailer_len = @sizeOf(u32);

pub const FormatError = error{InvalidObject};

pub fn deinit(gpa: std.mem.Allocator, hash_in: Hash) void {
    var hash = hash_in;
    var it = hash.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        gpa.free(entry.value_ptr.*);
    }
    hash.deinit(gpa);
}

pub fn bytes(hash: *const Hash) usize {
    var total: usize = VALUE_OVERHEAD;
    var copy = hash.*;
    var it = copy.iterator();
    while (it.next()) |entry| {
        total +|= FIELD_OVERHEAD +| entry.key_ptr.*.len +| entry.value_ptr.*.len;
    }
    return total;
}

pub fn copyTo(allocator: std.mem.Allocator, hash: *const Hash) std.mem.Allocator.Error!Hash {
    var copy: Hash = .empty;
    errdefer deinit(allocator, copy);

    var source = hash.*;
    var it = source.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, entry.value_ptr.*);
        errdefer allocator.free(value);
        try copy.put(allocator, key, value);
    }
    return copy;
}

pub fn serialize(gpa: std.mem.Allocator, hash: *const Hash) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, magic);

    var source = hash.*;
    const count = source.count();
    if (count > std.math.maxInt(u32)) return error.OutOfMemory;
    try appendInt(gpa, &out, u32, @intCast(count));

    var it = source.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (key.len > std.math.maxInt(u32) or value.len > std.math.maxInt(u32)) return error.OutOfMemory;
        try appendInt(gpa, &out, u32, @intCast(key.len));
        try appendInt(gpa, &out, u32, @intCast(value.len));
        try out.appendSlice(gpa, key);
        try out.appendSlice(gpa, value);
    }

    const checksum = std.hash.Crc32.hash(out.items);
    try appendInt(gpa, &out, u32, checksum);
    return out.toOwnedSlice(gpa);
}

pub fn deserialize(gpa: std.mem.Allocator, data: []const u8) (std.mem.Allocator.Error || FormatError)!Hash {
    if (data.len < header_len + trailer_len) return error.InvalidObject;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return error.InvalidObject;

    const body = data[0 .. data.len - trailer_len];
    const expected_crc = std.mem.readInt(u32, data[data.len - trailer_len ..][0..4], .little);
    if (std.hash.Crc32.hash(body) != expected_crc) return error.InvalidObject;

    const count = std.mem.readInt(u32, data[magic.len..][0..4], .little);
    // Each field needs at least 8 bytes of length prefixes. Reject absurd
    // counts before attempting any allocation.
    if (count > body.len / 8) return error.InvalidObject;

    var hash: Hash = .empty;
    errdefer deinit(gpa, hash);
    try hash.ensureTotalCapacity(gpa, @intCast(count));

    var pos: usize = header_len;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        if (pos + 8 > body.len) return error.InvalidObject;
        const key_len = std.mem.readInt(u32, body[pos..][0..4], .little);
        pos += 4;
        const value_len = std.mem.readInt(u32, body[pos..][0..4], .little);
        pos += 4;

        const key_end = std.math.add(usize, pos, key_len) catch return error.InvalidObject;
        const value_end = std.math.add(usize, key_end, value_len) catch return error.InvalidObject;
        if (value_end > body.len) return error.InvalidObject;

        const key = try gpa.dupe(u8, body[pos..key_end]);
        errdefer gpa.free(key);
        const value = try gpa.dupe(u8, body[key_end..value_end]);
        errdefer gpa.free(value);
        try hash.put(gpa, key, value);
        pos = value_end;
    }

    if (pos != body.len) return error.InvalidObject;
    return hash;
}

fn appendInt(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime T: type,
    value: T,
) std.mem.Allocator.Error!void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try out.appendSlice(gpa, &buffer);
}

// ============================================================
// Tests
// ============================================================

test "hash round trip through the object format" {
    const gpa = std.testing.allocator;

    var hash: Hash = .empty;
    defer deinit(gpa, hash);
    try hash.put(gpa, try gpa.dupe(u8, "id"), try gpa.dupe(u8, "abc123"));
    try hash.put(gpa, try gpa.dupe(u8, "createdAt"), try gpa.dupe(u8, "1700000000000"));
    try hash.put(gpa, try gpa.dupe(u8, "content"), try gpa.dupe(u8, "hello"));

    const data = try serialize(gpa, &hash);
    defer gpa.free(data);

    var decoded = try deserialize(gpa, data);
    defer deinit(gpa, decoded);

    try std.testing.expectEqual(@as(usize, 3), decoded.count());
    try std.testing.expectEqualStrings("abc123", decoded.get("id").?);
    try std.testing.expectEqualStrings("1700000000000", decoded.get("createdAt").?);
    try std.testing.expectEqualStrings("hello", decoded.get("content").?);
}

test "empty hash round trip" {
    const gpa = std.testing.allocator;
    const hash: Hash = .empty;

    const data = try serialize(gpa, &hash);
    defer gpa.free(data);

    var decoded = try deserialize(gpa, data);
    defer deinit(gpa, decoded);
    try std.testing.expectEqual(@as(usize, 0), decoded.count());
}

test "object format rejects corruption" {
    const gpa = std.testing.allocator;

    var hash: Hash = .empty;
    defer deinit(gpa, hash);
    try hash.put(gpa, try gpa.dupe(u8, "key"), try gpa.dupe(u8, "value"));

    var data = try serialize(gpa, &hash);
    defer gpa.free(data);

    // Corrupt a payload byte; the CRC must catch it.
    data[8] = data[8] ^ 0xFF;
    try std.testing.expectError(error.InvalidObject, deserialize(gpa, data));
    data[8] = data[8] ^ 0xFF;

    // Truncated objects are rejected too.
    try std.testing.expectError(error.InvalidObject, deserialize(gpa, data[0 .. data.len - 1]));
    try std.testing.expectError(error.InvalidObject, deserialize(gpa, "SHF1"));
}
