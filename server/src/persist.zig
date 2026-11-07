//! Durable storage layer.
//!
//! Metadata (key, expiry, field count, object size, object path) lives in a
//! SQLite database. The values themselves are written to a git-style sharded
//! object directory:
//!
//!     <data_dir>/meta.sqlite3
//!     <data_dir>/objects/ab/cd/<sha256(key)>
//!
//! Sharding keeps individual directories small even when a deployment holds
//! millions of rooms.

const std = @import("std");
const sqlite = @import("sqlite.zig");

pub const max_object_bytes: usize = 2 * 1024 * 1024 * 1024;

pub const Meta = struct {
    expires_at_ms: ?i64,
    field_count: u32,
    bytes: u64,
    object_path: []u8,

    pub fn deinit(self: *Meta, gpa: std.mem.Allocator) void {
        gpa.free(self.object_path);
        self.* = undefined;
    }
};

pub const Expired = struct {
    key: []u8,
    object_path: []u8,
};

pub const Persist = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    db: sqlite.Db,
    data_dir: []u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8) !Persist {
        const owned_dir = try gpa.dupe(u8, data_dir);
        errdefer gpa.free(owned_dir);

        try std.Io.Dir.cwd().createDirPath(io, data_dir);
        var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{});
        errdefer dir.close(io);

        const db_path = try std.fmt.allocPrint(gpa, "{s}/meta.sqlite3", .{data_dir});
        defer gpa.free(db_path);

        var db = try sqlite.Db.open(gpa, db_path);
        errdefer db.close();

        db.exec("PRAGMA journal_mode=WAL;") catch |err| {
            std.log.err("sqlite journal_mode failed: {s}", .{db.errmsg()});
            return err;
        };
        db.exec("PRAGMA synchronous=NORMAL;") catch |err| {
            std.log.err("sqlite synchronous failed: {s}", .{db.errmsg()});
            return err;
        };
        db.exec("PRAGMA busy_timeout=5000;") catch |err| {
            std.log.err("sqlite busy_timeout failed: {s}", .{db.errmsg()});
            return err;
        };
        db.exec(
            \\CREATE TABLE IF NOT EXISTS objects (
            \\  key TEXT PRIMARY KEY NOT NULL,
            \\  expires_at INTEGER,
            \\  fields INTEGER NOT NULL,
            \\  bytes INTEGER NOT NULL,
            \\  object TEXT NOT NULL,
            \\  updated_at INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS objects_expires_at ON objects(expires_at);
        ) catch |err| {
            std.log.err("sqlite schema failed: {s}", .{db.errmsg()});
            return err;
        };

        return .{
            .gpa = gpa,
            .io = io,
            .dir = dir,
            .db = db,
            .data_dir = owned_dir,
        };
    }

    pub fn deinit(self: *Persist) void {
        self.db.close();
        self.dir.close(self.io);
        self.gpa.free(self.data_dir);
        self.* = undefined;
    }

    /// Copies the sharded object path for `key` into `out` and returns it.
    pub fn objectPath(key: []const u8, out: *[128]u8) []const u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        return std.fmt.bufPrint(out, "objects/{s}/{s}/{s}", .{
            hex[0..2],
            hex[2..4],
            hex,
        }) catch unreachable;
    }

    pub fn writeObject(self: *Persist, rel_path: []const u8, data: []const u8) !void {
        var atomic = try self.dir.createFileAtomic(self.io, rel_path, .{
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(self.io);

        try atomic.file.writeStreamingAll(self.io, data);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }

    pub fn readObject(self: *Persist, rel_path: []const u8) ![]u8 {
        return self.dir.readFileAlloc(self.io, rel_path, self.gpa, .limited(max_object_bytes));
    }

    pub fn deleteObject(self: *Persist, rel_path: []const u8) !void {
        self.dir.deleteFile(self.io, rel_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    pub fn getMeta(self: *Persist, gpa: std.mem.Allocator, key: []const u8) !?Meta {
        var stmt = try self.db.prepare(
            \\SELECT expires_at, fields, bytes, object FROM objects WHERE key = ?1
        );
        defer stmt.finalize();
        try stmt.bindText(1, key);

        if (!try stmt.step()) return null;

        const expires_at_ms: ?i64 = if (stmt.columnNull(0)) null else stmt.columnInt(0);
        const field_count: u32 = @intCast(@max(0, stmt.columnInt(1)));
        const bytes: u64 = @intCast(@max(0, stmt.columnInt(2)));
        const object_path = try gpa.dupe(u8, stmt.columnText(3) orelse "");
        errdefer gpa.free(object_path);

        return .{
            .expires_at_ms = expires_at_ms,
            .field_count = field_count,
            .bytes = bytes,
            .object_path = object_path,
        };
    }

    pub fn putMeta(
        self: *Persist,
        key: []const u8,
        expires_at_ms: ?i64,
        field_count: u32,
        bytes: u64,
        object_path: []const u8,
        now_ms: i64,
    ) !void {
        var stmt = try self.db.prepare(
            \\INSERT INTO objects(key, expires_at, fields, bytes, object, updated_at)
            \\VALUES(?1, ?2, ?3, ?4, ?5, ?6)
            \\ON CONFLICT(key) DO UPDATE SET
            \\  expires_at = excluded.expires_at,
            \\  fields = excluded.fields,
            \\  bytes = excluded.bytes,
            \\  object = excluded.object,
            \\  updated_at = excluded.updated_at
        );
        defer stmt.finalize();

        try stmt.bindText(1, key);
        if (expires_at_ms) |value| {
            try stmt.bindInt(2, value);
        } else {
            try stmt.bindNull(2);
        }
        try stmt.bindInt(3, field_count);
        try stmt.bindInt(4, @intCast(@min(bytes, @as(u64, std.math.maxInt(i64)))));
        try stmt.bindText(5, object_path);
        try stmt.bindInt(6, now_ms);
        if (try stmt.step()) return error.UnexpectedRow;
    }

    pub fn deleteMeta(self: *Persist, key: []const u8) !bool {
        var stmt = try self.db.prepare("DELETE FROM objects WHERE key = ?1");
        defer stmt.finalize();
        try stmt.bindText(1, key);
        if (try stmt.step()) return error.UnexpectedRow;
        return self.db.changes() > 0;
    }

    pub fn updateExpiry(self: *Persist, key: []const u8, expires_at_ms: ?i64, now_ms: i64) !bool {
        var stmt = try self.db.prepare(
            \\UPDATE objects SET expires_at = ?2, updated_at = ?3 WHERE key = ?1
        );
        defer stmt.finalize();
        try stmt.bindText(1, key);
        if (expires_at_ms) |value| {
            try stmt.bindInt(2, value);
        } else {
            try stmt.bindNull(2);
        }
        try stmt.bindInt(3, now_ms);
        if (try stmt.step()) return error.UnexpectedRow;
        return self.db.changes() > 0;
    }

    pub fn listExpired(self: *Persist, gpa: std.mem.Allocator, now_ms: i64) ![]Expired {
        var stmt = try self.db.prepare(
            \\SELECT key, object FROM objects
            \\WHERE expires_at IS NOT NULL AND expires_at <= ?1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, now_ms);

        var expired: std.ArrayList(Expired) = .empty;
        errdefer {
            for (expired.items) |item| {
                gpa.free(item.key);
                gpa.free(item.object_path);
            }
            expired.deinit(gpa);
        }

        while (try stmt.step()) {
            const key = try gpa.dupe(u8, stmt.columnText(0) orelse "");
            errdefer gpa.free(key);
            const object_path = try gpa.dupe(u8, stmt.columnText(1) orelse "");
            errdefer gpa.free(object_path);
            try expired.append(gpa, .{ .key = key, .object_path = object_path });
        }

        return expired.toOwnedSlice(gpa);
    }

    pub fn freeExpired(gpa: std.mem.Allocator, items: []Expired) void {
        for (items) |item| {
            gpa.free(item.key);
            gpa.free(item.object_path);
        }
        gpa.free(items);
    }
};

// ============================================================
// Tests
// ============================================================

pub const TmpDir = struct {
    path: []u8,

    pub fn remove(self: *TmpDir, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
    }
};

/// Creates a scratch directory under `.zig-cache/tmp` for tests.
pub fn makeTmpDir(gpa: std.mem.Allocator, io: std.Io) !TmpDir {
    var random: [12]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/shoufa-{s}", .{hex});
    errdefer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    return .{ .path = path };
}

test "metadata and objects round trip on disk" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = try makeTmpDir(gpa, io);
    defer {
        tmp.remove(io);
        gpa.free(tmp.path);
    }

    var persist = try Persist.init(gpa, io, tmp.path);
    defer persist.deinit();

    const now: i64 = 1_700_000_000_000;
    const expires: i64 = now + 60_000;

    try persist.putMeta("slug:demo", expires, 2, 128, "objects/aa/bb/aabb", now);
    try persist.putMeta("slug:demo:assets", null, 1, 64, "objects/cc/dd/ccdd", now);

    var meta = (try persist.getMeta(gpa, "slug:demo")).?;
    defer meta.deinit(gpa);
    try std.testing.expectEqual(expires, meta.expires_at_ms.?);
    try std.testing.expectEqual(@as(u32, 2), meta.field_count);
    try std.testing.expectEqual(@as(u64, 128), meta.bytes);
    try std.testing.expectEqualStrings("objects/aa/bb/aabb", meta.object_path);

    // Missing rows report null rather than an error.
    try std.testing.expect((try persist.getMeta(gpa, "slug:missing")) == null);

    // Objects are written atomically and read back byte for byte.
    const payload = "SHF1 payload bytes";
    try persist.writeObject("objects/aa/bb/aabb", payload);
    const read_back = try persist.readObject("objects/aa/bb/aabb");
    defer gpa.free(read_back);
    try std.testing.expectEqualStrings(payload, read_back);

    // Expiry scans see only keys whose deadline has passed.
    const expired = try persist.listExpired(gpa, expires + 1);
    defer Persist.freeExpired(gpa, expired);
    try std.testing.expectEqual(@as(usize, 1), expired.len);
    try std.testing.expectEqualStrings("slug:demo", expired[0].key);
    try std.testing.expectEqualStrings("objects/aa/bb/aabb", expired[0].object_path);

    try std.testing.expect(try persist.deleteMeta("slug:demo"));
    try std.testing.expect(!try persist.deleteMeta("slug:demo"));
    try std.testing.expect((try persist.getMeta(gpa, "slug:demo")) == null);

    // Deletes ignore already-removed object files.
    try persist.deleteObject("objects/aa/bb/aabb");
    try persist.deleteObject("objects/aa/bb/aabb");
}

test "object paths are sharded like git" {
    var buffer: [128]u8 = undefined;
    const path = Persist.objectPath("slug:demo", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, path, "objects/"));
    try std.testing.expectEqual(@as(usize, "objects/ab/cd/".len + 64), path.len);

    var other_buffer: [128]u8 = undefined;
    const other = Persist.objectPath("slug:other", &other_buffer);
    try std.testing.expect(!std.mem.eql(u8, path, other));
}
