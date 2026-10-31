//! Thread-safe in-memory key/value store with Redis-compatible semantics.
//!
//! Supports the subset of commands used by the Shoufa web app:
//!   strings, hashes, key expiry and deletion.
//!
//! Memory is accounted conservatively and capped by `max_bytes` (default 5 GiB).
//! Expired keys are removed lazily on access and proactively by a background
//! sweeper, which returns their allocations to the allocator.

const std = @import("std");

pub const KEY_OVERHEAD: usize = 96;
pub const FIELD_OVERHEAD: usize = 48;
pub const VALUE_OVERHEAD: usize = 24;

pub const Value = union(enum) {
    string: []u8,
    hash: std.StringHashMapUnmanaged([]u8),
};

pub const Entry = struct {
    value: Value,
    expires_at_ms: ?i64 = null,
    bytes: usize,
};

pub const Field = struct {
    field: []const u8,
    value: []const u8,
};

pub const HashCopy = struct {
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn deinit(self: *HashCopy, gpa: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        self.map.deinit(gpa);
        self.* = .{};
    }
};

pub const SetOptions = struct {
    expires_at_ms: ?i64 = null,
    keep_ttl: bool = false,
    nx: bool = false,
    xx: bool = false,
};

pub const SetOutcome = enum { ok, not_set };

pub const HSetOutcome = struct {
    added: usize,
};

pub const Stats = struct {
    used_bytes: usize,
    max_bytes: usize,
    keys: usize,
    hits: u64,
    misses: u64,
    expired: u64,
};

pub const Error = error{
    WrongType,
    MaxMemory,
} || std.mem.Allocator.Error;

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    used_bytes: usize = 0,
    max_bytes: usize,
    sweep_interval_ms: u64,
    hits: u64 = 0,
    misses: u64 = 0,
    expired_count: u64 = 0,
    started_at_ms: i64,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        max_bytes: usize,
        sweep_interval_ms: u64,
    ) Store {
        return .{
            .gpa = gpa,
            .io = io,
            .max_bytes = max_bytes,
            .sweep_interval_ms = sweep_interval_ms,
            .started_at_ms = nowMs(io),
        };
    }

    pub fn deinit(self: *Store) void {
        self.lock();
        self.flushLocked();
        self.map.deinit(self.gpa);
        self.unlock();
    }

    // ============================================================
    // Locking helpers
    // ============================================================

    pub fn lock(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
    }

    pub fn unlock(self: *Store) void {
        self.mutex.unlock(self.io);
    }

    fn nowMs(io: std.Io) i64 {
        return std.Io.Timestamp.now(io, .real).toMilliseconds();
    }

    fn now(self: *Store) i64 {
        return nowMs(self.io);
    }

    // ============================================================
    // Expiry / memory
    // ============================================================

    fn isExpired(entry: *const Entry, now_ms: i64) bool {
        const exp = entry.expires_at_ms orelse return false;
        return exp <= now_ms;
    }

    fn removeKeyLocked(self: *Store, key: []const u8) bool {
        const kv = self.map.fetchRemove(key) orelse return false;
        self.used_bytes -|= kv.value.bytes;
        self.freeValue(kv.value.value);
        self.gpa.free(kv.key);
        return true;
    }

    fn expireKeyLocked(self: *Store, key: []const u8) bool {
        const entry = self.map.getPtr(key) orelse return false;
        if (!isExpired(entry, self.now())) return false;
        if (self.removeKeyLocked(key)) self.expired_count += 1;
        return true;
    }

    fn freeValue(self: *Store, value: Value) void {
        switch (value) {
            .string => |s| self.gpa.free(s),
            .hash => |h_in| {
                var h = h_in;
                var it = h.iterator();
                while (it.next()) |e| {
                    self.gpa.free(e.key_ptr.*);
                    self.gpa.free(e.value_ptr.*);
                }
                h.deinit(self.gpa);
            },
        }
    }

    fn hashBytes(hash: *const std.StringHashMapUnmanaged([]u8)) usize {
        var total: usize = VALUE_OVERHEAD;
        var h = hash.*;
        var it = h.iterator();
        while (it.next()) |e| {
            total +|= FIELD_OVERHEAD +| e.key_ptr.*.len +| e.value_ptr.*.len;
        }
        return total;
    }

    fn hashBytesAfterUpdates(old: ?*Entry, fields: []const Field) usize {
        var total: usize = VALUE_OVERHEAD;
        if (old) |e| total = hashBytes(&e.value.hash);

        var i: usize = 0;
        while (i < fields.len) : (i += 1) {
            if (hasLaterField(fields, i)) continue;
            const f = fields[i];
            if (old) |e| {
                if (e.value.hash.get(f.field)) |old_value| {
                    total -|= FIELD_OVERHEAD +| f.field.len +| old_value.len;
                }
            }
            total +|= FIELD_OVERHEAD +| f.field.len +| f.value.len;
        }
        return total;
    }

    fn entryBytes(key_len: usize, value_bytes: usize) usize {
        return key_len +| KEY_OVERHEAD +| value_bytes;
    }

    fn projectedReplacement(self: *Store, key_len: usize, new_value_bytes: usize, old: ?*Entry) usize {
        const new_entry_bytes = entryBytes(key_len, new_value_bytes);
        if (old) |e| return self.used_bytes -| e.bytes +| new_entry_bytes;
        return self.used_bytes +| new_entry_bytes;
    }

    pub fn sweepExpired(self: *Store) void {
        self.lock();
        defer self.unlock();
        self.sweepExpiredLocked();
    }

    fn sweepExpiredLocked(self: *Store) void {
        const now_ms = self.now();
        var expired: std.ArrayList([]const u8) = .empty;
        defer expired.deinit(self.gpa);

        var it = self.map.iterator();
        while (it.next()) |e| {
            if (isExpired(e.value_ptr, now_ms)) {
                expired.append(self.gpa, e.key_ptr.*) catch break;
            }
        }
        for (expired.items) |key| {
            if (self.removeKeyLocked(key)) self.expired_count += 1;
        }
    }

    fn flushLocked(self: *Store) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.freeValue(e.value_ptr.value);
            self.gpa.free(e.key_ptr.*);
        }
        self.map.clearRetainingCapacity();
        self.used_bytes = 0;
    }

    // ============================================================
    // Generic key commands
    // ============================================================

    pub fn exists(self: *Store, keys: []const []const u8) u64 {
        self.lock();
        defer self.unlock();
        var count: u64 = 0;
        for (keys) |key| {
            _ = self.expireKeyLocked(key);
            if (self.map.contains(key)) count += 1;
        }
        return count;
    }

    pub fn del(self: *Store, keys: []const []const u8) u64 {
        self.lock();
        defer self.unlock();
        var count: u64 = 0;
        for (keys) |key| {
            _ = self.expireKeyLocked(key);
            if (self.map.contains(key)) {
                if (self.removeKeyLocked(key)) count += 1;
            }
        }
        return count;
    }

    pub fn expire(self: *Store, key: []const u8, seconds: i64) i64 {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse return 0;
        if (seconds <= 0) {
            _ = self.removeKeyLocked(key);
            return 1;
        }
        const delta_ms = std.math.mul(i64, seconds, 1000) catch std.math.maxInt(i64);
        entry.expires_at_ms = self.now() +| delta_ms;
        return 1;
    }

    pub fn expireAt(self: *Store, key: []const u8, at_ms: i64) i64 {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse return 0;
        entry.expires_at_ms = at_ms;
        if (at_ms <= self.now()) {
            _ = self.removeKeyLocked(key);
        }
        return 1;
    }

    pub fn ttl(self: *Store, key: []const u8) i64 {
        self.lock();
        defer self.unlock();
        return self.ttlLocked(key, true);
    }

    pub fn pttl(self: *Store, key: []const u8) i64 {
        self.lock();
        defer self.unlock();
        return self.ttlLocked(key, false);
    }

    fn ttlLocked(self: *Store, key: []const u8, seconds: bool) i64 {
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse return -2;
        const exp = entry.expires_at_ms orelse return -1;
        const remaining_ms = exp - self.now();
        if (remaining_ms <= 0) {
            _ = self.removeKeyLocked(key);
            return -2;
        }
        if (seconds) {
            return @divTrunc(remaining_ms + 999, 1000);
        }
        return remaining_ms;
    }

    pub fn persist(self: *Store, key: []const u8) i64 {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse return 0;
        if (entry.expires_at_ms == null) return 0;
        entry.expires_at_ms = null;
        return 1;
    }

    pub fn typeOf(self: *Store, key: []const u8) []const u8 {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse return "none";
        return switch (entry.value) {
            .string => "string",
            .hash => "hash",
        };
    }

    pub fn dbsize(self: *Store) u64 {
        self.lock();
        defer self.unlock();
        self.sweepExpiredLocked();
        return self.map.count();
    }

    pub fn flush(self: *Store) void {
        self.lock();
        defer self.unlock();
        self.flushLocked();
    }

    pub fn stats(self: *Store) Stats {
        self.lock();
        defer self.unlock();
        return .{
            .used_bytes = self.used_bytes,
            .max_bytes = self.max_bytes,
            .keys = self.map.count(),
            .hits = self.hits,
            .misses = self.misses,
            .expired = self.expired_count,
        };
    }

    pub fn uptimeSeconds(self: *Store) i64 {
        return @divTrunc(self.now() - self.started_at_ms, 1000);
    }

    // ============================================================
    // String commands
    // ============================================================

    pub fn set(self: *Store, key: []const u8, value: []const u8, options: SetOptions) Error!SetOutcome {
        self.lock();
        defer self.unlock();

        _ = self.expireKeyLocked(key);
        const old = self.map.getPtr(key);

        if (options.nx and old != null) return .not_set;
        if (options.xx and old == null) return .not_set;

        const new_value_bytes = VALUE_OVERHEAD +| value.len;
        var projected = self.projectedReplacement(key.len, new_value_bytes, old);
        if (projected > self.max_bytes) {
            self.sweepExpiredLocked();
            const old_after = self.map.getPtr(key);
            projected = self.projectedReplacement(key.len, new_value_bytes, old_after);
        }
        if (projected > self.max_bytes) return error.MaxMemory;

        const new_value = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(new_value);

        const old_after = self.map.getPtr(key);
        if (old_after) |entry| {
            const expires = if (options.keep_ttl) entry.expires_at_ms else options.expires_at_ms;
            self.freeValue(entry.value);
            entry.value = .{ .string = new_value };
            entry.expires_at_ms = expires;
            entry.bytes = entryBytes(key.len, new_value_bytes);
            self.used_bytes = projected;
        } else {
            const owned_key = try self.gpa.dupe(u8, key);
            errdefer self.gpa.free(owned_key);
            try self.map.put(self.gpa, owned_key, .{
                .value = .{ .string = new_value },
                .expires_at_ms = options.expires_at_ms,
                .bytes = entryBytes(key.len, new_value_bytes),
            });
            self.used_bytes = projected;
        }
        return .ok;
    }

    pub fn get(self: *Store, allocator: std.mem.Allocator, key: []const u8) Error!?[]u8 {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse {
            self.misses += 1;
            return null;
        };
        switch (entry.value) {
            .string => |s| {
                self.hits += 1;
                return try allocator.dupe(u8, s);
            },
            .hash => return error.WrongType,
        }
    }

    pub fn incrBy(self: *Store, key: []const u8, delta: i64) Error!i64 {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key);
        if (entry) |e| switch (e.value) {
            .string => {
                const current = std.fmt.parseInt(i64, e.value.string, 10) catch return error.WrongType;
                const updated = std.math.add(i64, current, delta) catch return error.WrongType;
                const text = try std.fmt.allocPrint(self.gpa, "{d}", .{updated});
                errdefer self.gpa.free(text);
                const new_bytes = entryBytes(key.len, VALUE_OVERHEAD +| text.len);
                const projected = self.used_bytes -| e.bytes +| new_bytes;
                if (projected > self.max_bytes) return error.MaxMemory;
                self.gpa.free(e.value.string);
                e.value = .{ .string = text };
                e.bytes = new_bytes;
                self.used_bytes = projected;
                return updated;
            },
            .hash => return error.WrongType,
        };

        const text = try std.fmt.allocPrint(self.gpa, "{d}", .{delta});
        errdefer self.gpa.free(text);
        const owned_key = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned_key);
        const bytes = entryBytes(key.len, VALUE_OVERHEAD +| text.len);
        if (bytes > self.max_bytes -| self.used_bytes) return error.MaxMemory;
        try self.map.put(self.gpa, owned_key, .{
            .value = .{ .string = text },
            .bytes = bytes,
        });
        self.used_bytes += bytes;
        return delta;
    }

    // ============================================================
    // Hash commands
    // ============================================================

    pub fn hset(self: *Store, key: []const u8, fields: []const Field) Error!HSetOutcome {
        if (fields.len == 0) return .{ .added = 0 };

        self.lock();
        defer self.unlock();

        _ = self.expireKeyLocked(key);
        const old = self.map.getPtr(key);
        if (old) |e| switch (e.value) {
            .string => return error.WrongType,
            .hash => {},
        };

        // Compute the projected hash size. Duplicate fields are handled with
        // last-write-wins; only the final value for each field is counted.
        var new_hash_bytes = hashBytesAfterUpdates(old, fields);
        var projected = self.projectedReplacement(key.len, new_hash_bytes, old);
        if (projected > self.max_bytes) {
            self.sweepExpiredLocked();
            const old_after = self.map.getPtr(key);
            new_hash_bytes = hashBytesAfterUpdates(old_after, fields);
            projected = self.projectedReplacement(key.len, new_hash_bytes, old_after);
        }
        if (projected > self.max_bytes) return error.MaxMemory;

        // Allocate all field/value pairs before mutating the hash. This keeps
        // a failed OOM from leaving a partially updated hash behind.
        var pending: std.ArrayList(OwnedField) = .empty;
        defer {
            for (pending.items) |pf| {
                if (pf.field) |f| self.gpa.free(f);
                if (pf.value) |v| self.gpa.free(v);
            }
            pending.deinit(self.gpa);
        }

        var i: usize = 0;
        while (i < fields.len) : (i += 1) {
            if (hasLaterField(fields, i)) continue;
            const f = fields[i];
            const owned_field = try self.gpa.dupe(u8, f.field);
            errdefer self.gpa.free(owned_field);
            const owned_value = try self.gpa.dupe(u8, f.value);
            errdefer self.gpa.free(owned_value);
            try pending.append(self.gpa, .{ .field = owned_field, .value = owned_value });
        }

        const old_after = self.map.getPtr(key);
        if (old_after) |entry| {
            var hash = &entry.value.hash;
            try hash.ensureUnusedCapacity(self.gpa, @intCast(pending.items.len));

            var added: usize = 0;
            for (pending.items) |*pf| {
                const gop = hash.getOrPutAssumeCapacity(pf.field.?);
                if (gop.found_existing) {
                    self.gpa.free(pf.field.?);
                    pf.field = null;
                    self.gpa.free(gop.value_ptr.*);
                    gop.value_ptr.* = pf.value.?;
                    pf.value = null;
                } else {
                    gop.key_ptr.* = pf.field.?;
                    gop.value_ptr.* = pf.value.?;
                    pf.field = null;
                    pf.value = null;
                    added += 1;
                }
            }

            entry.bytes = entryBytes(key.len, new_hash_bytes);
            self.used_bytes = projected;
            return .{ .added = added };
        }

        // New key.
        var hash: std.StringHashMapUnmanaged([]u8) = .empty;
        errdefer {
            var it = hash.iterator();
            while (it.next()) |e| {
                self.gpa.free(e.key_ptr.*);
                self.gpa.free(e.value_ptr.*);
            }
            hash.deinit(self.gpa);
        }
        try hash.ensureTotalCapacity(self.gpa, @intCast(pending.items.len));

        var added: usize = 0;
        for (pending.items) |*pf| {
            hash.putAssumeCapacity(pf.field.?, pf.value.?);
            pf.field = null;
            pf.value = null;
            added += 1;
        }

        const owned_key = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned_key);
        try self.map.put(self.gpa, owned_key, .{
            .value = .{ .hash = hash },
            .bytes = entryBytes(key.len, new_hash_bytes),
        });
        self.used_bytes = projected;
        return .{ .added = added };
    }

    pub fn hget(self: *Store, allocator: std.mem.Allocator, key: []const u8, field: []const u8) Error!?[]u8 {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse {
            self.misses += 1;
            return null;
        };
        switch (entry.value) {
            .string => return error.WrongType,
            .hash => |*hash| {
                const value = hash.get(field) orelse {
                    self.misses += 1;
                    return null;
                };
                self.hits += 1;
                return try allocator.dupe(u8, value);
            },
        }
    }

    pub fn hgetall(self: *Store, allocator: std.mem.Allocator, key: []const u8) Error!?HashCopy {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse {
            self.misses += 1;
            return null;
        };
        switch (entry.value) {
            .string => return error.WrongType,
            .hash => |*hash| {
                self.hits += 1;
                var copy: HashCopy = .{};
                errdefer copy.deinit(allocator);

                var it = hash.iterator();
                while (it.next()) |e| {
                    const field = try allocator.dupe(u8, e.key_ptr.*);
                    errdefer allocator.free(field);
                    const value = try allocator.dupe(u8, e.value_ptr.*);
                    errdefer allocator.free(value);
                    try copy.map.put(allocator, field, value);
                }
                return copy;
            },
        }
    }

    pub fn hdel(self: *Store, key: []const u8, fields: []const []const u8) Error!u64 {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse return 0;
        switch (entry.value) {
            .string => return error.WrongType,
            .hash => |*hash| {
                var removed: u64 = 0;
                var removed_bytes: usize = 0;
                for (fields) |field| {
                    if (hash.fetchRemove(field)) |kv| {
                        removed += 1;
                        removed_bytes +|= FIELD_OVERHEAD +| kv.key.len +| kv.value.len;
                        self.gpa.free(kv.key);
                        self.gpa.free(kv.value);
                    }
                }

                if (hash.count() == 0) {
                    const kv = self.map.fetchRemove(key).?;
                    self.used_bytes -|= kv.value.bytes;
                    self.gpa.free(kv.key);
                    var empty_hash = kv.value.value.hash;
                    empty_hash.deinit(self.gpa);
                } else {
                    entry.bytes -|= removed_bytes;
                    self.used_bytes -|= removed_bytes;
                }
                return removed;
            },
        }
    }

    pub fn hexists(self: *Store, key: []const u8, field: []const u8) Error!bool {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse return false;
        return switch (entry.value) {
            .string => error.WrongType,
            .hash => |*hash| hash.contains(field),
        };
    }

    pub fn hlen(self: *Store, key: []const u8) Error!u64 {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse return 0;
        return switch (entry.value) {
            .string => error.WrongType,
            .hash => |*hash| hash.count(),
        };
    }

    pub fn hkeys(self: *Store, allocator: std.mem.Allocator, key: []const u8) Error![]const []const u8 {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse return &.{};

        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |item| allocator.free(item);
            result.deinit(allocator);
        }
        switch (entry.value) {
            .string => return error.WrongType,
            .hash => |*hash| {
                var it = hash.iterator();
                while (it.next()) |e| {
                    try result.append(allocator, try allocator.dupe(u8, e.key_ptr.*));
                }
            },
        }
        return try result.toOwnedSlice(allocator);
    }

    pub fn hvals(self: *Store, allocator: std.mem.Allocator, key: []const u8) Error![]const []const u8 {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse return &.{};

        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |item| allocator.free(item);
            result.deinit(allocator);
        }
        switch (entry.value) {
            .string => return error.WrongType,
            .hash => |*hash| {
                var it = hash.iterator();
                while (it.next()) |e| {
                    try result.append(allocator, try allocator.dupe(u8, e.value_ptr.*));
                }
            },
        }
        return try result.toOwnedSlice(allocator);
    }
};

const OwnedField = struct {
    field: ?[]u8,
    value: ?[]u8,
};

fn hasLaterField(fields: []const Field, index: usize) bool {
    var i = index + 1;
    while (i < fields.len) : (i += 1) {
        if (std.mem.eql(u8, fields[index].field, fields[i].field)) return true;
    }
    return false;
}
