//! Thread-safe in-memory hash store with Redis-like TTL semantics.
//!
//! The app only needs hashes plus key expiry. Keeping the store hash-only
//! avoids dead string-command paths while retaining memory accounting, lazy
//! expiry, background sweeping, and room revisions for long-poll clients.

const std = @import("std");

pub const KEY_OVERHEAD: usize = 96;
pub const FIELD_OVERHEAD: usize = 48;
pub const VALUE_OVERHEAD: usize = 24;

const Hash = std.StringHashMapUnmanaged([]u8);

pub const Field = struct {
    field: []const u8,
    value: []const u8,
};

pub const HSetOutcome = struct {
    added: usize,
};

pub const HashCopy = struct {
    map: Hash = .empty,

    pub fn deinit(self: *HashCopy, gpa: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.map.deinit(gpa);
        self.* = .{};
    }
};

pub const Error = std.mem.Allocator.Error || error{MaxMemory};

const Entry = struct {
    value: Hash,
    expires_at_ms: ?i64 = null,
    bytes: usize,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Per-room revision counters used by the long-poll notification endpoint.
    revisions: std.StringHashMapUnmanaged(u64) = .empty,
    used_bytes: usize = 0,
    max_bytes: usize,
    sweep_interval_ms: u64,

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
        };
    }

    pub fn deinit(self: *Store) void {
        self.lock();
        self.flushLocked();
        self.map.deinit(self.gpa);
        var revisions = self.revisions.iterator();
        while (revisions.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.revisions.deinit(self.gpa);
        self.unlock();
    }

    // ============================================================
    // Locking / time
    // ============================================================

    fn lock(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Store) void {
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

    fn revisionKey(key: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, key, "slug:")) return null;
        if (std.mem.endsWith(u8, key, ":assets")) {
            return key[0 .. key.len - ":assets".len];
        }
        return key;
    }

    fn bumpKeyLocked(self: *Store, key: []const u8) void {
        const base = revisionKey(key) orelse return;

        if (self.revisions.getPtr(base)) |current_revision| {
            current_revision.* +%= 1;
            return;
        }

        const owned = self.gpa.dupe(u8, base) catch return;
        self.revisions.put(self.gpa, owned, 1) catch {
            self.gpa.free(owned);
        };
    }

    fn revisionLocked(self: *Store, slug: []const u8) u64 {
        var buffer: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&buffer, "slug:{s}", .{slug}) catch return 0;
        return self.revisions.get(key) orelse 0;
    }

    pub fn revision(self: *Store, slug: []const u8) u64 {
        self.lock();
        defer self.unlock();
        return self.revisionLocked(slug);
    }

    /// Blocks until the room revision differs from `since` or the timeout
    /// expires. Used by the browser-facing long-poll endpoint.
    pub fn waitForRevision(self: *Store, slug: []const u8, since: u64, timeout_ms: u64) u64 {
        const deadline = nowMs(self.io) + @as(i64, @intCast(timeout_ms));

        while (true) {
            self.lock();
            const current = self.revisionLocked(slug);
            self.unlock();

            if (current != since) return current;

            const now_ms = nowMs(self.io);
            if (now_ms >= deadline) return current;

            const remaining = deadline - now_ms;
            const sleep_ms: u64 = @intCast(@min(@as(i64, 250), remaining));
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(sleep_ms)), .awake) catch {};
        }
    }

    fn removeKeyLocked(self: *Store, key: []const u8) bool {
        const kv = self.map.fetchRemove(key) orelse return false;
        self.bumpKeyLocked(kv.key);
        self.used_bytes -|= kv.value.bytes;
        self.freeHash(kv.value.value);
        self.gpa.free(kv.key);
        return true;
    }

    fn expireKeyLocked(self: *Store, key: []const u8) bool {
        const entry = self.map.getPtr(key) orelse return false;
        if (!isExpired(entry, self.now())) return false;
        _ = self.removeKeyLocked(key);
        return true;
    }

    fn freeHash(self: *Store, hash_in: Hash) void {
        var hash = hash_in;
        var it = hash.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        hash.deinit(self.gpa);
    }

    fn hashBytes(hash: *const Hash) usize {
        var total: usize = VALUE_OVERHEAD;
        var copy = hash.*;
        var it = copy.iterator();
        while (it.next()) |entry| {
            total +|= FIELD_OVERHEAD +| entry.key_ptr.*.len +| entry.value_ptr.*.len;
        }
        return total;
    }

    fn entryBytes(key_len: usize, value_bytes: usize) usize {
        return key_len +| KEY_OVERHEAD +| value_bytes;
    }

    fn projectedReplacement(self: *Store, key_len: usize, new_value_bytes: usize, old: ?*Entry) usize {
        const new_entry_bytes = entryBytes(key_len, new_value_bytes);
        if (old) |entry| return self.used_bytes -| entry.bytes +| new_entry_bytes;
        return self.used_bytes +| new_entry_bytes;
    }

    fn hashBytesAfterUpdates(old: ?*Entry, fields: []const Field) usize {
        var total: usize = VALUE_OVERHEAD;
        if (old) |entry| total = hashBytes(&entry.value);

        var i: usize = 0;
        while (i < fields.len) : (i += 1) {
            if (hasLaterField(fields, i)) continue;
            const field = fields[i];
            if (old) |entry| {
                if (entry.value.get(field.field)) |old_value| {
                    total -|= FIELD_OVERHEAD +| field.field.len +| old_value.len;
                }
            }
            total +|= FIELD_OVERHEAD +| field.field.len +| field.value.len;
        }
        return total;
    }

    fn sweepExpiredLocked(self: *Store) void {
        const now_ms = self.now();
        var expired: std.ArrayList([]const u8) = .empty;
        defer expired.deinit(self.gpa);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (isExpired(entry.value_ptr, now_ms)) {
                expired.append(self.gpa, entry.key_ptr.*) catch break;
            }
        }
        for (expired.items) |key| {
            _ = self.removeKeyLocked(key);
        }
    }

    pub fn sweepExpired(self: *Store) void {
        self.lock();
        defer self.unlock();
        self.sweepExpiredLocked();
    }

    fn flushLocked(self: *Store) void {
        var revisions = self.revisions.iterator();
        while (revisions.next()) |entry| entry.value_ptr.* +%= 1;

        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.freeHash(entry.value_ptr.value);
            self.gpa.free(entry.key_ptr.*);
        }
        self.map.clearRetainingCapacity();
        self.used_bytes = 0;
    }

    // ============================================================
    // Key commands
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
            if (self.removeKeyLocked(key)) count += 1;
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
        self.bumpKeyLocked(key);
        return 1;
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

        var new_hash_bytes = hashBytesAfterUpdates(old, fields);
        var projected = self.projectedReplacement(key.len, new_hash_bytes, old);
        if (projected > self.max_bytes) {
            self.sweepExpiredLocked();
            const old_after = self.map.getPtr(key);
            new_hash_bytes = hashBytesAfterUpdates(old_after, fields);
            projected = self.projectedReplacement(key.len, new_hash_bytes, old_after);
        }
        if (projected > self.max_bytes) return error.MaxMemory;

        var pending: std.ArrayList(OwnedField) = .empty;
        defer {
            for (pending.items) |field| {
                if (field.field) |owned| self.gpa.free(owned);
                if (field.value) |owned| self.gpa.free(owned);
            }
            pending.deinit(self.gpa);
        }

        var i: usize = 0;
        while (i < fields.len) : (i += 1) {
            if (hasLaterField(fields, i)) continue;
            const field = fields[i];
            const owned_field = try self.gpa.dupe(u8, field.field);
            errdefer self.gpa.free(owned_field);
            const owned_value = try self.gpa.dupe(u8, field.value);
            errdefer self.gpa.free(owned_value);
            try pending.append(self.gpa, .{ .field = owned_field, .value = owned_value });
        }

        const old_after = self.map.getPtr(key);
        if (old_after) |entry| {
            var hash = &entry.value;
            try hash.ensureUnusedCapacity(self.gpa, @intCast(pending.items.len));

            var added: usize = 0;
            for (pending.items) |*field| {
                const result = hash.getOrPutAssumeCapacity(field.field.?);
                if (result.found_existing) {
                    self.gpa.free(field.field.?);
                    field.field = null;
                    self.gpa.free(result.value_ptr.*);
                    result.value_ptr.* = field.value.?;
                    field.value = null;
                } else {
                    result.key_ptr.* = field.field.?;
                    result.value_ptr.* = field.value.?;
                    field.field = null;
                    field.value = null;
                    added += 1;
                }
            }

            entry.bytes = entryBytes(key.len, new_hash_bytes);
            self.used_bytes = projected;
            self.bumpKeyLocked(key);
            return .{ .added = added };
        }

        var hash: Hash = .empty;
        errdefer {
            var it = hash.iterator();
            while (it.next()) |entry| {
                self.gpa.free(entry.key_ptr.*);
                self.gpa.free(entry.value_ptr.*);
            }
            hash.deinit(self.gpa);
        }
        try hash.ensureTotalCapacity(self.gpa, @intCast(pending.items.len));

        var added: usize = 0;
        for (pending.items) |*field| {
            hash.putAssumeCapacity(field.field.?, field.value.?);
            field.field = null;
            field.value = null;
            added += 1;
        }

        const owned_key = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned_key);
        try self.map.put(self.gpa, owned_key, .{
            .value = hash,
            .bytes = entryBytes(key.len, new_hash_bytes),
        });
        self.used_bytes = projected;
        self.bumpKeyLocked(key);
        return .{ .added = added };
    }

    pub fn hgetall(self: *Store, allocator: std.mem.Allocator, key: []const u8) Error!?HashCopy {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse return null;

        var copy: HashCopy = .{};
        errdefer copy.deinit(allocator);

        var it = entry.value.iterator();
        while (it.next()) |field| {
            const owned_field = try allocator.dupe(u8, field.key_ptr.*);
            errdefer allocator.free(owned_field);
            const owned_value = try allocator.dupe(u8, field.value_ptr.*);
            errdefer allocator.free(owned_value);
            try copy.map.put(allocator, owned_field, owned_value);
        }
        return copy;
    }

    pub fn hdel(self: *Store, key: []const u8, fields: []const []const u8) Error!u64 {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse return 0;

        var hash = &entry.value;
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
            self.bumpKeyLocked(kv.key);
            self.used_bytes -|= kv.value.bytes;
            self.gpa.free(kv.key);
            var empty_hash = kv.value.value;
            empty_hash.deinit(self.gpa);
        } else if (removed > 0) {
            entry.bytes -|= removed_bytes;
            self.used_bytes -|= removed_bytes;
            self.bumpKeyLocked(key);
        }

        return removed;
    }

    pub fn hlen(self: *Store, key: []const u8) Error!u64 {
        self.lock();
        defer self.unlock();
        _ = self.expireKeyLocked(key);
        const entry = self.map.getPtr(key) orelse return 0;
        return entry.value.count();
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
