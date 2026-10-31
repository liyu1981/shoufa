//! Minimal Upstash-compatible Redis command execution.
//!
//! A command is a slice of string arguments, e.g. `["HSET", "slug:x", "a", "1"]`.
//! The result is a JSON envelope: `{"result":...}` or `{"error":"..."}`.

const std = @import("std");
const store_mod = @import("store.zig");
const Store = store_mod.Store;

pub const OneResult = struct {
    body: []u8,
    is_error: bool,
};

/// Upstash clients send `Upstash-Encoding: base64` and expect every string in
/// a successful result to be base64-encoded. Clients that do not send the
/// header receive plain JSON strings.
pub const StringEncoding = enum { plain, base64 };

pub const Error = error{
    WrongArgs,
    Syntax,
    InvalidInteger,
    UnknownCommand,
} || store_mod.Error || std.Io.Writer.Error;

/// Executes one command and returns its JSON envelope.
/// Only allocation failures are returned; protocol errors become error envelopes.
pub fn execute(
    store: *Store,
    gpa: std.mem.Allocator,
    args: []const []const u8,
    encoding: StringEncoding,
) !OneResult {
    const body = executeInner(store, gpa, args, encoding) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{
            .body = try makeError(gpa, errorMessage(err)),
            .is_error = true,
        },
    };
    return .{ .body = body, .is_error = false };
}

fn executeInner(
    store: *Store,
    gpa: std.mem.Allocator,
    args: []const []const u8,
    encoding: StringEncoding,
) Error![]u8 {
    if (args.len == 0) return error.WrongArgs;
    const cmd = args[0];

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    if (eq(cmd, "PING")) {
        try requireMin(args, 1);
        try requireMax(args, 2);
        try beginResult(&out.writer);
        if (args.len == 2) {
            try writeString(&out.writer, args[1], encoding);
        } else {
            try writeString(&out.writer, "PONG", encoding);
        }
        try endResult(&out.writer);
    } else if (eq(cmd, "ECHO")) {
        try requireExact(args, 2);
        try beginResult(&out.writer);
        try writeString(&out.writer, args[1], encoding);
        try endResult(&out.writer);
    } else if (eq(cmd, "EXISTS")) {
        try requireMin(args, 2);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{store.exists(args[1..])});
        try endResult(&out.writer);
    } else if (eq(cmd, "DEL") or eq(cmd, "UNLINK")) {
        try requireMin(args, 2);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{store.del(args[1..])});
        try endResult(&out.writer);
    } else if (eq(cmd, "EXPIRE")) {
        try requireExact(args, 3);
        const seconds = try parseInt(args[2]);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{store.expire(args[1], seconds)});
        try endResult(&out.writer);
    } else if (eq(cmd, "PEXPIRE")) {
        try requireExact(args, 3);
        const ms = try parseInt(args[2]);
        const at = nowMs(store) +| ms;
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{store.expireAt(args[1], at)});
        try endResult(&out.writer);
    } else if (eq(cmd, "EXPIREAT")) {
        try requireExact(args, 3);
        const seconds = try parseInt(args[2]);
        const at = std.math.mul(i64, seconds, 1000) catch std.math.maxInt(i64);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{store.expireAt(args[1], at)});
        try endResult(&out.writer);
    } else if (eq(cmd, "PEXPIREAT")) {
        try requireExact(args, 3);
        const at = try parseInt(args[2]);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{store.expireAt(args[1], at)});
        try endResult(&out.writer);
    } else if (eq(cmd, "TTL")) {
        try requireExact(args, 2);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{store.ttl(args[1])});
        try endResult(&out.writer);
    } else if (eq(cmd, "PTTL")) {
        try requireExact(args, 2);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{store.pttl(args[1])});
        try endResult(&out.writer);
    } else if (eq(cmd, "PERSIST")) {
        try requireExact(args, 2);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{store.persist(args[1])});
        try endResult(&out.writer);
    } else if (eq(cmd, "TYPE")) {
        try requireExact(args, 2);
        try beginResult(&out.writer);
        try writeString(&out.writer, store.typeOf(args[1]), encoding);
        try endResult(&out.writer);
    } else if (eq(cmd, "GET")) {
        try requireExact(args, 2);
        try beginResult(&out.writer);
        if (try store.get(gpa, args[1])) |value| {
            defer gpa.free(value);
            try writeString(&out.writer, value, encoding);
        } else {
            try out.writer.writeAll("null");
        }
        try endResult(&out.writer);
    } else if (eq(cmd, "SET")) {
        try requireMin(args, 3);
        var options: store_mod.SetOptions = .{};
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            const opt = args[i];
            if (eq(opt, "EX")) {
                i += 1;
                if (i >= args.len) return error.Syntax;
                const seconds = try parseInt(args[i]);
                if (seconds <= 0) return error.InvalidInteger;
                const ms = std.math.mul(i64, seconds, 1000) catch std.math.maxInt(i64);
                options.expires_at_ms = nowMs(store) +| ms;
            } else if (eq(opt, "PX")) {
                i += 1;
                if (i >= args.len) return error.Syntax;
                const ms = try parseInt(args[i]);
                if (ms <= 0) return error.InvalidInteger;
                options.expires_at_ms = nowMs(store) +| ms;
            } else if (eq(opt, "NX")) {
                options.nx = true;
            } else if (eq(opt, "XX")) {
                options.xx = true;
            } else if (eq(opt, "KEEPTTL")) {
                options.keep_ttl = true;
            } else if (eq(opt, "GET")) {
                // Not supported; the app never uses it.
                return error.Syntax;
            } else {
                return error.Syntax;
            }
        }
        const outcome = try store.set(args[1], args[2], options);
        try beginResult(&out.writer);
        if (outcome == .ok) {
            try writeString(&out.writer, "OK", encoding);
        } else {
            try out.writer.writeAll("null");
        }
        try endResult(&out.writer);
    } else if (eq(cmd, "INCR")) {
        try requireExact(args, 2);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{try store.incrBy(args[1], 1)});
        try endResult(&out.writer);
    } else if (eq(cmd, "DECR")) {
        try requireExact(args, 2);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{try store.incrBy(args[1], -1)});
        try endResult(&out.writer);
    } else if (eq(cmd, "INCRBY")) {
        try requireExact(args, 3);
        const delta = try parseInt(args[2]);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{try store.incrBy(args[1], delta)});
        try endResult(&out.writer);
    } else if (eq(cmd, "DECRBY")) {
        try requireExact(args, 3);
        const delta = try parseInt(args[2]);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{try store.incrBy(args[1], -delta)});
        try endResult(&out.writer);
    } else if (eq(cmd, "HSET") or eq(cmd, "HMSET")) {
        try requireMin(args, 4);
        if ((args.len - 2) % 2 != 0) return error.WrongArgs;
        var fields = try gpa.alloc(store_mod.Field, (args.len - 2) / 2);
        defer gpa.free(fields);
        var i: usize = 2;
        var n: usize = 0;
        while (i + 1 < args.len) : (i += 2) {
            fields[n] = .{ .field = args[i], .value = args[i + 1] };
            n += 1;
        }
        const outcome = try store.hset(args[1], fields);
        try beginResult(&out.writer);
        if (eq(cmd, "HMSET")) {
            try writeString(&out.writer, "OK", encoding);
        } else {
            try out.writer.print("{d}", .{outcome.added});
        }
        try endResult(&out.writer);
    } else if (eq(cmd, "HGET")) {
        try requireExact(args, 3);
        try beginResult(&out.writer);
        if (try store.hget(gpa, args[1], args[2])) |value| {
            defer gpa.free(value);
            try writeString(&out.writer, value, encoding);
        } else {
            try out.writer.writeAll("null");
        }
        try endResult(&out.writer);
    } else if (eq(cmd, "HGETALL") or eq(cmd, "HGETALL_WITH_VALUES")) {
        try requireExact(args, 2);
        try beginResult(&out.writer);
        var copy = try store.hgetall(gpa, args[1]);
        if (copy) |*hash| {
            defer hash.deinit(gpa);
            // Upstash returns HGETALL as a flat [field, value, ...] array; the
            // client library converts it to an object.
            try out.writer.writeAll("[");
            var first = true;
            var it = hash.map.iterator();
            while (it.next()) |e| {
                if (!first) try out.writer.writeAll(",");
                first = false;
                try writeString(&out.writer, e.key_ptr.*, encoding);
                try out.writer.writeAll(",");
                try writeString(&out.writer, e.value_ptr.*, encoding);
            }
            try out.writer.writeAll("]");
        } else {
            try out.writer.writeAll("[]");
        }
        try endResult(&out.writer);
    } else if (eq(cmd, "HDEL")) {
        try requireMin(args, 3);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{try store.hdel(args[1], args[2..])});
        try endResult(&out.writer);
    } else if (eq(cmd, "HEXISTS")) {
        try requireExact(args, 3);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{@intFromBool(try store.hexists(args[1], args[2]))});
        try endResult(&out.writer);
    } else if (eq(cmd, "HLEN")) {
        try requireExact(args, 2);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{try store.hlen(args[1])});
        try endResult(&out.writer);
    } else if (eq(cmd, "HKEYS")) {
        try requireExact(args, 2);
        try beginResult(&out.writer);
        try writeStringArray(&out.writer, gpa, try store.hkeys(gpa, args[1]), encoding);
        try endResult(&out.writer);
    } else if (eq(cmd, "HVALS")) {
        try requireExact(args, 2);
        try beginResult(&out.writer);
        try writeStringArray(&out.writer, gpa, try store.hvals(gpa, args[1]), encoding);
        try endResult(&out.writer);
    } else if (eq(cmd, "DBSIZE")) {
        try requireExact(args, 1);
        try beginResult(&out.writer);
        try out.writer.print("{d}", .{store.dbsize()});
        try endResult(&out.writer);
    } else if (eq(cmd, "FLUSHDB") or eq(cmd, "FLUSHALL")) {
        try requireMin(args, 1);
        store.flush();
        try beginResult(&out.writer);
        try writeString(&out.writer, "OK", encoding);
        try endResult(&out.writer);
    } else if (eq(cmd, "INFO")) {
        try requireMin(args, 1);
        const stats = store.stats();
        var human_buf: [32]u8 = undefined;
        const human = formatBytes(&human_buf, stats.used_bytes);
        const info = try std.fmt.allocPrint(gpa,
            \\# Server
            \\shoufa_redis_version:0.1.0
            \\redis_version:7.0.0
            \\uptime_in_seconds:{d}
            \\# Memory
            \\used_memory:{d}
            \\used_memory_human:{s}
            \\maxmemory:{d}
            \\maxmemory_policy:noeviction
            \\# Stats
            \\keyspace_hits:{d}
            \\keyspace_misses:{d}
            \\expired_keys:{d}
            \\# Keyspace
            \\db0:keys={d},expires=0,avg_ttl=0
        , .{
            store.uptimeSeconds(),
            stats.used_bytes,
            human,
            stats.max_bytes,
            stats.hits,
            stats.misses,
            stats.expired,
            stats.keys,
        });
        defer gpa.free(info);
        try beginResult(&out.writer);
        try writeString(&out.writer, info, encoding);
        try endResult(&out.writer);
    } else if (eq(cmd, "AUTH") or eq(cmd, "SELECT") or eq(cmd, "CLIENT")) {
        // Authentication is handled by the HTTP layer. Accept these for
        // compatibility with clients that send them.
        try beginResult(&out.writer);
        try writeString(&out.writer, "OK", encoding);
        try endResult(&out.writer);
    } else if (eq(cmd, "COMMAND")) {
        try beginResult(&out.writer);
        try out.writer.writeAll("[]");
        try endResult(&out.writer);
    } else {
        return error.UnknownCommand;
    }

    return try out.toOwnedSlice();
}

fn nowMs(store: *Store) i64 {
    return std.Io.Timestamp.now(store.io, .real).toMilliseconds();
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn requireExact(args: []const []const u8, n: usize) Error!void {
    if (args.len != n) return error.WrongArgs;
}

fn requireMin(args: []const []const u8, n: usize) Error!void {
    if (args.len < n) return error.WrongArgs;
}

fn requireMax(args: []const []const u8, n: usize) Error!void {
    if (args.len > n) return error.WrongArgs;
}

fn parseInt(value: []const u8) Error!i64 {
    return std.fmt.parseInt(i64, value, 10) catch error.InvalidInteger;
}

fn beginResult(w: *std.Io.Writer) !void {
    try w.writeAll("{\"result\":");
}

fn endResult(w: *std.Io.Writer) !void {
    try w.writeAll("}");
}

fn writeString(w: *std.Io.Writer, value: []const u8, encoding: StringEncoding) !void {
    switch (encoding) {
        .plain => try std.json.Stringify.value(value, .{}, w),
        .base64 => {
            try w.writeAll("\"");
            try std.base64.standard.Encoder.encodeWriter(w, value);
            try w.writeAll("\"");
        },
    }
}

fn writeStringArray(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    items: []const []const u8,
    encoding: StringEncoding,
) !void {
    defer {
        for (items) |item| gpa.free(item);
        if (items.len > 0) gpa.free(items);
    }
    try w.writeAll("[");
    for (items, 0..) |item, i| {
        if (i != 0) try w.writeAll(",");
        try writeString(w, item, encoding);
    }
    try w.writeAll("]");
}

fn makeError(gpa: std.mem.Allocator, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll("{\"error\":");
    try writeString(&out.writer, message, .plain);
    try out.writer.writeAll("}");
    return try out.toOwnedSlice();
}

fn errorMessage(err: Error) []const u8 {
    return switch (err) {
        error.WrongArgs => "ERR wrong number of arguments",
        error.Syntax => "ERR syntax error",
        error.InvalidInteger => "ERR value is not an integer or out of range",
        error.UnknownCommand => "ERR unknown command",
        error.WrongType => "WRONGTYPE Operation against a key holding the wrong kind of value",
        error.MaxMemory => "OOM command not allowed when used memory > 'maxmemory'.",
        error.OutOfMemory => "ERR out of memory",
        error.WriteFailed => "ERR failed to encode response",
    };
}

fn formatBytes(buf: []u8, bytes: usize) []const u8 {
    const fbytes: f64 = @floatFromInt(bytes);
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch "?";
    } else if (bytes < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.2}K", .{fbytes / 1024.0}) catch "?";
    } else if (bytes < 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.2}M", .{fbytes / (1024.0 * 1024.0)}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.2}G", .{fbytes / (1024.0 * 1024.0 * 1024.0)}) catch "?";
}
