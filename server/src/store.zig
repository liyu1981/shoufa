//! Thread-safe hash store with Redis-like TTL semantics.
//!
//! Values are always persisted: metadata lives in SQLite and the serialized
//! hash is written to a git-style sharded object directory. A bounded LRU cache
//! keeps the hottest keys in memory. Reads check the cache first and fall back
//! to disk, loading the value back into the cache when there is room.

const std = @import("std");
const hash_mod = @import("hash.zig");
const persist_mod = @import("persist.zig");

pub const KEY_OVERHEAD: usize = 96;
pub const FIELD_OVERHEAD: usize = hash_mod.FIELD_OVERHEAD;
pub const VALUE_OVERHEAD: usize = hash_mod.VALUE_OVERHEAD;

const Hash = hash_mod.Hash;

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
        hash_mod.deinit(gpa, self.map);
        self.* = .{};
    }
};

pub const Error = std.mem.Allocator.Error || error{ PersistFailed, CorruptObject };

const Entry = struct {
    key: []u8,
    value: Hash,
    expires_at_ms: ?i64 = null,
    /// Bytes charged against the in-memory cache budget.
    bytes: usize,
    field_count: u32,
    prev: ?*Entry = null,
    next: ?*Entry = null,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    /// LRU cache. Values are heap-allocated so pointers remain stable across
    /// hash-map rehashes; `head` is most-recently-used and `tail` is evicted
    /// first.
    map: std.StringHashMapUnmanaged(*Entry) = .empty,
    head: ?*Entry = null,
    tail: ?*Entry = null,
    used_bytes: usize = 0,
    max_bytes: usize,

    sweep_interval_ms: u64,
    persist: persist_mod.Persist,

    /// Per-room revision counters used by the long-poll notification endpoint.
    revisions: std.StringHashMapUnmanaged(u64) = .empty,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        max_bytes: usize,
        sweep_interval_ms: u64,
        data_dir: []const u8,
    ) !Store {
        var persist = try persist_mod.Persist.init(gpa, io, data_dir);
        errdefer persist.deinit();

        var store: Store = .{
            .gpa = gpa,
            .io = io,
            .max_bytes = max_bytes,
            .sweep_interval_ms = sweep_interval_ms,
            .persist = persist,
        };
        store.sweepExpired();
        return store;
    }

    pub fn deinit(self: *Store) void {
        self.lock();
        self.freeAllLocked();
        self.map.deinit(self.gpa);

        var revisions = self.revisions.iterator();
        while (revisions.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.revisions.deinit(self.gpa);

        self.persist.deinit();
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
    // LRU cache
    // ============================================================

    fn linkFrontLocked(self: *Store, entry: *Entry) void {
        entry.prev = null;
        entry.next = self.head;
        if (self.head) |head| head.prev = entry else self.tail = entry;
        self.head = entry;
    }

    fn unlinkLocked(self: *Store, entry: *Entry) void {
        if (entry.prev) |prev| prev.next = entry.next else self.head = entry.next;
        if (entry.next) |next| next.prev = entry.prev else self.tail = entry.prev;
        entry.prev = null;
        entry.next = null;
    }

    fn touchLocked(self: *Store, entry: *Entry) void {
        if (self.head == entry) return;
        self.unlinkLocked(entry);
        self.linkFrontLocked(entry);
    }

    fn freeEntry(self: *Store, entry: *Entry) void {
        hash_mod.deinit(self.gpa, entry.value);
        self.gpa.free(entry.key);
        self.gpa.destroy(entry);
    }

    fn removeEntryLocked(self: *Store, entry: *Entry) void {
        _ = self.map.remove(entry.key);
        self.unlinkLocked(entry);
        self.used_bytes -|= entry.bytes;
        self.freeEntry(entry);
    }

    fn evictToBudgetLocked(self: *Store, protect: ?*Entry) void {
        while (self.used_bytes > self.max_bytes) {
            const victim = self.tail orelse break;
            if (victim == protect) {
                // Keep the entry alive for the current operation. If it is the
                // only entry it may temporarily exceed the budget.
                if (self.head == victim) break;
                self.touchLocked(victim);
                continue;
            }
            self.removeEntryLocked(victim);
        }
    }

    fn freeAllLocked(self: *Store) void {
        var current = self.head;
        while (current) |entry| {
            const next = entry.next;
            self.freeEntry(entry);
            current = next;
        }
        self.map.clearRetainingCapacity();
        self.head = null;
        self.tail = null;
        self.used_bytes = 0;
    }

    // ============================================================
    // Expiry / revisions
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

    // ============================================================
    // Persistence helpers
    // ============================================================

    fn entryBytes(key_len: usize, value_bytes: usize) usize {
        return key_len +| KEY_OVERHEAD +| value_bytes;
    }

    fn serializeEntryLocked(self: *Store, key: []const u8, entry: *Entry, now_ms: i64) !void {
        const data = try hash_mod.serialize(self.gpa, &entry.value);
        defer self.gpa.free(data);

        var path_buffer: [128]u8 = undefined;
        const rel_path = persist_mod.Persist.objectPath(key, &path_buffer);

        try self.persist.writeObject(rel_path, data);
        try self.persist.putMeta(
            key,
            entry.expires_at_ms,
            entry.field_count,
            data.len,
            rel_path,
            now_ms,
        );
    }

    const RemovedPersist = struct {
        existed: bool = false,
        unexpired: bool = false,
    };

    /// Removes the SQLite row and its object file. Returns whether a row
    /// existed and whether it was still live (unexpired) at `now_ms`.
    fn removePersistedLocked(self: *Store, key: []const u8, now_ms: i64) RemovedPersist {
        var meta_opt = self.persist.getMeta(self.gpa, key) catch |err| {
            std.log.err("metadata read failed for {s}: {t}", .{ key, err });
            return .{};
        };

        if (meta_opt) |*meta| {
            defer meta.deinit(self.gpa);

            const expired = if (meta.expires_at_ms) |expires| expires <= now_ms else false;

            _ = self.persist.deleteMeta(key) catch |err| {
                std.log.err("metadata delete failed for {s}: {t}", .{ key, err });
            };
            self.persist.deleteObject(meta.object_path) catch |err| {
                std.log.err("object delete failed for {s}: {t}", .{ meta.object_path, err });
            };
            return .{ .existed = true, .unexpired = !expired };
        }
        return .{};
    }

    /// Removes a key from both layers. Returns true only when the key was live
    /// (unexpired) and therefore counts as a successful delete.
    fn deleteKeyLocked(self: *Store, key: []const u8, entry_opt: ?*Entry) bool {
        const now_ms = self.now();
        const entry = entry_opt orelse self.map.get(key);

        const removed_persist = self.removePersistedLocked(key, now_ms);

        var live = removed_persist.unexpired;
        if (entry) |e| {
            if (!isExpired(e, now_ms)) live = true;
            // Bump before `removeEntryLocked` frees the key.
            self.bumpKeyLocked(key);
            self.removeEntryLocked(e);
        } else if (removed_persist.existed) {
            self.bumpKeyLocked(key);
        }

        return live;
    }

    fn expireKeyLocked(self: *Store, key: []const u8, now_ms: i64) bool {
        if (self.map.get(key)) |entry| {
            if (!isExpired(entry, now_ms)) return false;
            _ = self.deleteKeyLocked(key, entry);
            return true;
        }

        var meta_opt = self.persist.getMeta(self.gpa, key) catch |err| {
            std.log.err("metadata read failed for {s}: {t}", .{ key, err });
            return false;
        };
        if (meta_opt) |*meta| {
            defer meta.deinit(self.gpa);
            const expired = if (meta.expires_at_ms) |expires| expires <= now_ms else false;
            if (!expired) return false;

            _ = self.persist.deleteMeta(key) catch |err| {
                std.log.err("metadata delete failed for {s}: {t}", .{ key, err });
            };
            self.persist.deleteObject(meta.object_path) catch |err| {
                std.log.err("object delete failed for {s}: {t}", .{ meta.object_path, err });
            };
            self.bumpKeyLocked(key);
            return true;
        }
        return false;
    }

    /// Looks up `key` in the LRU cache, lazily loading it from disk on a miss.
    /// Expired keys are removed from both layers.
    fn loadEntryLocked(self: *Store, key: []const u8, now_ms: i64) Error!?*Entry {
        if (self.map.get(key)) |entry| {
            if (isExpired(entry, now_ms)) {
                _ = self.deleteKeyLocked(key, entry);
                return null;
            }
            self.touchLocked(entry);
            return entry;
        }

        var meta_opt = self.persist.getMeta(self.gpa, key) catch |err| {
            std.log.err("metadata read failed for {s}: {t}", .{ key, err });
            return error.PersistFailed;
        };
        if (meta_opt == null) return null;

        var meta = &meta_opt.?;
        defer meta.deinit(self.gpa);

        if (meta.expires_at_ms) |expires| {
            if (expires <= now_ms) {
                _ = self.persist.deleteMeta(key) catch |err| {
                    std.log.err("metadata delete failed for {s}: {t}", .{ key, err });
                };
                self.persist.deleteObject(meta.object_path) catch |err| {
                    std.log.err("object delete failed for {s}: {t}", .{ meta.object_path, err });
                };
                self.bumpKeyLocked(key);
                return null;
            }
        }

        const data = self.persist.readObject(meta.object_path) catch |err| {
            std.log.err("object read failed for {s}: {t}", .{ meta.object_path, err });
            return error.PersistFailed;
        };
        defer self.gpa.free(data);

        const value = hash_mod.deserialize(self.gpa, data) catch |err| {
            std.log.err("object decode failed for {s}: {t}", .{ meta.object_path, err });
            return error.CorruptObject;
        };

        const owned_key = try self.gpa.dupe(u8, key);
        const entry = self.gpa.create(Entry) catch |err| {
            self.gpa.free(owned_key);
            hash_mod.deinit(self.gpa, value);
            return err;
        };
        entry.* = .{
            .key = owned_key,
            .value = value,
            .expires_at_ms = meta.expires_at_ms,
            .bytes = entryBytes(key.len, hash_mod.bytes(&value)),
            .field_count = @intCast(value.count()),
        };

        self.map.put(self.gpa, entry.key, entry) catch |err| {
            self.gpa.destroy(entry);
            self.gpa.free(owned_key);
            hash_mod.deinit(self.gpa, value);
            return err;
        };

        self.linkFrontLocked(entry);
        self.used_bytes +|= entry.bytes;
        self.evictToBudgetLocked(entry);
        return entry;
    }

    // ============================================================
    // Key commands
    // ============================================================

    fn containsLocked(self: *Store, key: []const u8, now_ms: i64) bool {
        if (self.map.get(key)) |entry| {
            if (isExpired(entry, now_ms)) {
                _ = self.deleteKeyLocked(key, entry);
                return false;
            }
            self.touchLocked(entry);
            return true;
        }

        var meta_opt = self.persist.getMeta(self.gpa, key) catch |err| {
            std.log.err("metadata read failed for {s}: {t}", .{ key, err });
            return false;
        };
        if (meta_opt) |*meta| {
            defer meta.deinit(self.gpa);
            if (meta.expires_at_ms) |expires| {
                if (expires <= now_ms) {
                    _ = self.persist.deleteMeta(key) catch |err| {
                        std.log.err("metadata delete failed for {s}: {t}", .{ key, err });
                    };
                    self.persist.deleteObject(meta.object_path) catch |err| {
                        std.log.err("object delete failed for {s}: {t}", .{ meta.object_path, err });
                    };
                    self.bumpKeyLocked(key);
                    return false;
                }
            }
            return true;
        }
        return false;
    }

    pub fn exists(self: *Store, keys: []const []const u8) u64 {
        self.lock();
        defer self.unlock();
        const now_ms = self.now();
        var count: u64 = 0;
        for (keys) |key| {
            if (self.containsLocked(key, now_ms)) count += 1;
        }
        return count;
    }

    pub fn del(self: *Store, keys: []const []const u8) u64 {
        self.lock();
        defer self.unlock();
        var count: u64 = 0;
        for (keys) |key| {
            if (self.deleteKeyLocked(key, null)) count += 1;
        }
        return count;
    }

    pub fn expire(self: *Store, key: []const u8, seconds: i64) i64 {
        self.lock();
        defer self.unlock();
        const now_ms = self.now();

        // Expired values are treated as absent.
        if (self.map.get(key)) |entry| {
            if (isExpired(entry, now_ms)) {
                _ = self.deleteKeyLocked(key, entry);
                return 0;
            }
        } else if (self.expireKeyLocked(key, now_ms)) {
            return 0;
        }

        if (seconds <= 0) {
            return if (self.deleteKeyLocked(key, null)) 1 else 0;
        }

        const delta_ms = std.math.mul(i64, seconds, 1000) catch std.math.maxInt(i64);
        const expires_at = now_ms +| delta_ms;

        if (self.map.get(key)) |entry| {
            entry.expires_at_ms = expires_at;
            self.touchLocked(entry);

            const updated = self.persist.updateExpiry(key, expires_at, now_ms) catch false;
            if (!updated) {
                // Self-heal a missing metadata row/object from the cached entry.
                self.serializeEntryLocked(key, entry, now_ms) catch |err| {
                    std.log.err("metadata upsert failed for {s}: {t}", .{ key, err });
                };
            }
            self.bumpKeyLocked(key);
            return 1;
        }

        const updated = self.persist.updateExpiry(key, expires_at, now_ms) catch |err| blk: {
            std.log.err("expiry update failed for {s}: {t}", .{ key, err });
            break :blk false;
        };
        if (updated) {
            self.bumpKeyLocked(key);
            return 1;
        }
        return 0;
    }

    // ============================================================
    // Hash commands
    // ============================================================

    fn applyPending(self: *Store, hash: *Hash, pending: []OwnedField) !usize {
        try hash.ensureUnusedCapacity(self.gpa, @intCast(pending.len));

        var added: usize = 0;
        for (pending) |*field| {
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
        return added;
    }

    pub fn hset(self: *Store, key: []const u8, fields: []const Field) Error!HSetOutcome {
        if (fields.len == 0) return .{ .added = 0 };

        self.lock();
        defer self.unlock();

        const now_ms = self.now();
        const existing = self.loadEntryLocked(key, now_ms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.PersistFailed,
        };

        var pending: std.ArrayList(OwnedField) = .empty;
        defer {
            freePending(self.gpa, pending.items);
            pending.deinit(self.gpa);
        }
        try duplicateFields(self.gpa, fields, &pending);

        const old_bytes = if (existing) |entry| entry.bytes else 0;
        const new_hash_bytes = hashBytesAfterUpdates(
            if (existing) |entry| &entry.value else null,
            fields,
        );

        var entry: *Entry = undefined;
        var added: usize = 0;

        if (existing) |old_entry| {
            entry = old_entry;
            added = try self.applyPending(&entry.value, pending.items);
            entry.field_count = @intCast(entry.value.count());
            entry.bytes = entryBytes(key.len, new_hash_bytes);
            self.used_bytes -|= old_bytes;
            self.used_bytes +|= entry.bytes;
            self.touchLocked(entry);
        } else {
            var value: Hash = .empty;
            added = self.applyPending(&value, pending.items) catch |err| {
                hash_mod.deinit(self.gpa, value);
                return err;
            };

            const owned_key = try self.gpa.dupe(u8, key);
            const new_entry = self.gpa.create(Entry) catch |err| {
                self.gpa.free(owned_key);
                hash_mod.deinit(self.gpa, value);
                return err;
            };
            new_entry.* = .{
                .key = owned_key,
                .value = value,
                .bytes = entryBytes(key.len, new_hash_bytes),
                .field_count = @intCast(value.count()),
            };

            self.map.put(self.gpa, new_entry.key, new_entry) catch |err| {
                self.gpa.destroy(new_entry);
                self.gpa.free(owned_key);
                hash_mod.deinit(self.gpa, value);
                return err;
            };

            entry = new_entry;
            self.linkFrontLocked(entry);
            self.used_bytes +|= entry.bytes;
        }

        entry.field_count = @intCast(entry.value.count());
        self.serializeEntryLocked(key, entry, now_ms) catch |err| {
            std.log.err("failed to persist {s}: {t}", .{ key, err });
            return error.PersistFailed;
        };

        self.bumpKeyLocked(key);
        self.evictToBudgetLocked(null);
        return .{ .added = added };
    }

    pub fn hgetall(self: *Store, allocator: std.mem.Allocator, key: []const u8) Error!?HashCopy {
        self.lock();
        defer self.unlock();

        const now_ms = self.now();
        const entry = self.loadEntryLocked(key, now_ms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.PersistFailed,
        };
        if (entry == null) return null;

        const copy = hash_mod.copyTo(allocator, &entry.?.value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };

        // The caller owns a copy, so the cached entry may be evicted if the
        // budget is still over the limit (for example, a single oversized key).
        self.evictToBudgetLocked(null);
        return .{ .map = copy };
    }

    pub fn hdel(self: *Store, key: []const u8, fields: []const []const u8) Error!u64 {
        self.lock();
        defer self.unlock();

        const now_ms = self.now();
        const entry = self.loadEntryLocked(key, now_ms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.PersistFailed,
        };
        if (entry == null) return 0;

        var removed: u64 = 0;
        for (fields) |field| {
            if (entry.?.value.fetchRemove(field)) |kv| {
                removed += 1;
                self.gpa.free(kv.key);
                self.gpa.free(kv.value);
            }
        }

        if (removed == 0) return 0;

        if (entry.?.value.count() == 0) {
            _ = self.deleteKeyLocked(key, entry.?);
            return removed;
        }

        const old_bytes = entry.?.bytes;
        entry.?.field_count = @intCast(entry.?.value.count());
        entry.?.bytes = entryBytes(key.len, hash_mod.bytes(&entry.?.value));
        self.used_bytes -|= old_bytes;
        self.used_bytes +|= entry.?.bytes;
        self.touchLocked(entry.?);

        self.serializeEntryLocked(key, entry.?, now_ms) catch |err| {
            std.log.err("failed to persist {s}: {t}", .{ key, err });
            return error.PersistFailed;
        };

        self.bumpKeyLocked(key);
        self.evictToBudgetLocked(null);
        return removed;
    }

    pub fn hlen(self: *Store, key: []const u8) Error!u64 {
        self.lock();
        defer self.unlock();

        const now_ms = self.now();
        if (self.map.get(key)) |entry| {
            if (isExpired(entry, now_ms)) {
                _ = self.deleteKeyLocked(key, entry);
                return 0;
            }
            self.touchLocked(entry);
            return entry.field_count;
        }

        var meta_opt = self.persist.getMeta(self.gpa, key) catch |err| {
            std.log.err("metadata read failed for {s}: {t}", .{ key, err });
            return error.PersistFailed;
        };
        if (meta_opt) |*meta| {
            defer meta.deinit(self.gpa);
            if (meta.expires_at_ms) |expires| {
                if (expires <= now_ms) {
                    _ = self.expireKeyLocked(key, now_ms);
                    return 0;
                }
            }
            return meta.field_count;
        }
        return 0;
    }

    // ============================================================
    // Sweeping
    // ============================================================

    pub fn sweepExpired(self: *Store) void {
        self.lock();
        defer self.unlock();
        self.sweepExpiredLocked();
    }

    fn sweepExpiredLocked(self: *Store) void {
        const now_ms = self.now();

        // First drop expired cached entries. They are write-through, so this
        // also removes their metadata and object files.
        var cached_expired: std.ArrayList([]const u8) = .empty;
        defer cached_expired.deinit(self.gpa);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (isExpired(entry.value_ptr.*, now_ms)) {
                cached_expired.append(self.gpa, entry.value_ptr.*.key) catch break;
            }
        }
        for (cached_expired.items) |key| {
            if (self.map.get(key)) |entry| {
                _ = self.deleteKeyLocked(key, entry);
            }
        }

        // Then sweep disk-only rows.
        const expired = self.persist.listExpired(self.gpa, now_ms) catch |err| {
            std.log.err("expired-key scan failed: {t}", .{err});
            return;
        };
        defer persist_mod.Persist.freeExpired(self.gpa, expired);

        for (expired) |item| {
            if (self.map.get(item.key)) |entry| {
                self.bumpKeyLocked(item.key);
                self.removeEntryLocked(entry);
            }
            _ = self.persist.deleteMeta(item.key) catch |err| {
                std.log.err("metadata delete failed for {s}: {t}", .{ item.key, err });
            };
            self.persist.deleteObject(item.object_path) catch |err| {
                std.log.err("object delete failed for {s}: {t}", .{ item.object_path, err });
            };
            self.bumpKeyLocked(item.key);
        }
    }
};

const OwnedField = struct {
    field: ?[]u8,
    value: ?[]u8,
};

fn freePending(gpa: std.mem.Allocator, pending: []OwnedField) void {
    for (pending) |field| {
        if (field.field) |owned| gpa.free(owned);
        if (field.value) |owned| gpa.free(owned);
    }
}

fn duplicateFields(
    gpa: std.mem.Allocator,
    fields: []const Field,
    pending: *std.ArrayList(OwnedField),
) !void {
    var i: usize = 0;
    while (i < fields.len) : (i += 1) {
        if (hasLaterField(fields, i)) continue;
        const field = fields[i];
        const owned_field = try gpa.dupe(u8, field.field);
        errdefer gpa.free(owned_field);
        const owned_value = try gpa.dupe(u8, field.value);
        errdefer gpa.free(owned_value);
        try pending.append(gpa, .{ .field = owned_field, .value = owned_value });
    }
}

fn hashBytesAfterUpdates(old: ?*const Hash, fields: []const Field) usize {
    var total: usize = VALUE_OVERHEAD;
    if (old) |hash| total = hash_mod.bytes(hash);

    var i: usize = 0;
    while (i < fields.len) : (i += 1) {
        if (hasLaterField(fields, i)) continue;
        const field = fields[i];
        if (old) |hash| {
            if (hash.get(field.field)) |old_value| {
                total -|= FIELD_OVERHEAD +| field.field.len +| old_value.len;
            }
        }
        total +|= FIELD_OVERHEAD +| field.field.len +| field.value.len;
    }
    return total;
}

fn hasLaterField(fields: []const Field, index: usize) bool {
    var i = index + 1;
    while (i < fields.len) : (i += 1) {
        if (std.mem.eql(u8, fields[index].field, fields[i].field)) return true;
    }
    return false;
}
// ============================================================
// Tests
// ============================================================

const TestEnv = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Heap-allocated so the `Io` handle keeps a stable address.
    threaded: *std.Io.Threaded,
    tmp: persist_mod.TmpDir,
    store: Store,

    fn init(gpa: std.mem.Allocator, max_bytes: usize) !TestEnv {
        const threaded = try gpa.create(std.Io.Threaded);
        errdefer gpa.destroy(threaded);
        threaded.* = .init(gpa, .{});
        const io = threaded.io();

        var tmp = try persist_mod.makeTmpDir(gpa, io);
        errdefer {
            tmp.remove(io);
            gpa.free(tmp.path);
        }

        const store = try Store.init(gpa, io, max_bytes, 50, tmp.path);
        return .{ .gpa = gpa, .io = io, .threaded = threaded, .tmp = tmp, .store = store };
    }

    fn cleanup(self: *TestEnv) void {
        self.store.deinit();
        self.tmp.remove(self.io);
        self.gpa.free(self.tmp.path);
        self.threaded.deinit();
        self.gpa.destroy(self.threaded);
    }
};

test "store writes through to disk and reloads after a restart" {
    const gpa = std.testing.allocator;

    var env = try TestEnv.init(gpa, 1024 * 1024);
    defer env.cleanup();

    const fields = [_]Field{
        .{ .field = "slug", .value = "demo" },
        .{ .field = "content", .value = "hello from disk" },
    };
    _ = try env.store.hset("slug:demo", &fields);
    _ = env.store.expire("slug:demo", 600);

    try std.testing.expectEqual(@as(u64, 1), env.store.exists(&.{"slug:demo"}));
    try std.testing.expectEqual(@as(u64, 2), try env.store.hlen("slug:demo"));

    // Simulate a restart: tear the store down, then rebuild it over the same
    // data directory. The value must come back from disk.
    env.store.deinit();
    env.store = try Store.init(gpa, env.io, 1024 * 1024, 50, env.tmp.path);

    try std.testing.expectEqual(@as(u64, 1), env.store.exists(&.{"slug:demo"}));

    var copy = (try env.store.hgetall(gpa, "slug:demo")).?;
    defer copy.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), copy.map.count());
    try std.testing.expectEqualStrings("hello from disk", copy.map.get("content").?);
}

test "store evicts least recently used keys while staying on disk" {
    const gpa = std.testing.allocator;
    const max_bytes: usize = 2048;

    var env = try TestEnv.init(gpa, max_bytes);
    defer env.cleanup();

    var index: usize = 0;
    while (index < 60) : (index += 1) {
        var key_buffer: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "slug:room-{d}", .{index});
        var value_buffer: [96]u8 = undefined;
        const value = try std.fmt.bufPrint(&value_buffer, "payload-{d}-{s}", .{ index, "0123456789abcdef" });
        _ = try env.store.hset(key, &[_]Field{
            .{ .field = "slug", .value = key },
            .{ .field = "content", .value = value },
        });
        _ = env.store.expire(key, 600);
    }

    // The cache honours its budget even under sustained writes.
    try std.testing.expect(env.store.used_bytes <= env.store.max_bytes);

    // Everything is still readable: cached keys and evicted keys alike.
    index = 0;
    while (index < 60) : (index += 1) {
        var key_buffer: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "slug:room-{d}", .{index});
        try std.testing.expectEqual(@as(u64, 1), env.store.exists(&.{key}));

        var copy = (try env.store.hgetall(gpa, key)).?;
        defer copy.deinit(gpa);

        var expected_buffer: [96]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "payload-{d}-{s}", .{ index, "0123456789abcdef" });
        try std.testing.expectEqualStrings(expected, copy.map.get("content").?);
    }

    try std.testing.expect(env.store.used_bytes <= env.store.max_bytes);
}

test "store removes expired keys from memory and disk" {
    const gpa = std.testing.allocator;

    var env = try TestEnv.init(gpa, 1024 * 1024);
    defer env.cleanup();

    _ = try env.store.hset("slug:temp", &[_]Field{.{ .field = "content", .value = "short lived" }});
    _ = env.store.expire("slug:temp", 1);

    std.Io.sleep(env.io, std.Io.Duration.fromMilliseconds(1_200), .awake) catch {};
    env.store.sweepExpired();

    try std.testing.expectEqual(@as(u64, 0), env.store.exists(&.{"slug:temp"}));
    try std.testing.expectEqual(@as(u64, 0), try env.store.hlen("slug:temp"));

    // The metadata row is gone too.
    var meta_opt = try env.store.persist.getMeta(gpa, "slug:temp");
    defer if (meta_opt) |*meta| meta.deinit(gpa);
    try std.testing.expect(meta_opt == null);
}
