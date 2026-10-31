//! Same-origin JSON API for the Shoufa web UI.

const std = @import("std");
const store_mod = @import("store.zig");
const words = @import("words.zig");

const Store = store_mod.Store;

pub const Response = struct {
    status: std.http.Status,
    body: []const u8,
};

const MAX_TTL: i64 = 3600;
const MIN_TTL: i64 = 10;
const MAX_REQUEST_BYTES: usize = 10 * 1024 * 1024;
const MAX_IMAGE_BYTES: usize = 5 * 1024 * 1024;
const MAX_TEXT_BYTES: usize = 9 * 1024 * 1024;
const GRACE_SECONDS: i64 = 15 * 60;

const ParsedAsset = struct {
    value: std.json.Value,
    createdAt: i64,
};

pub fn handle(
    store: *Store,
    arena: std.mem.Allocator,
    method: std.http.Method,
    segments: []const []const u8,
    body: []const u8,
) !Response {
    // /api/slugs
    if (segments.len == 2 and eql(segments[1], "slugs") and method == .POST) {
        return createSlug(store, arena, body);
    }

    if (segments.len < 2) return errorResponse(arena, .not_found, "Not found");

    const slug = segments[1];
    if (!isValidSlug(slug)) {
        return errorResponse(arena, .bad_request, "Invalid slug");
    }

    // /api/:slug
    if (segments.len == 2 and method == .DELETE) {
        return deleteSlug(store, arena, slug);
    }

    // /api/:slug/exists
    if (segments.len == 3 and eql(segments[2], "exists") and method == .GET) {
        const key = try std.fmt.allocPrint(arena, "slug:{s}", .{slug});
        const exists = store.exists(&[_][]const u8{key}) > 0;
        const response_body = try std.fmt.allocPrint(arena, "{{\"ok\":true,\"data\":{{\"exists\":{s}}}}}", .{
            if (exists) "true" else "false",
        });
        return .{ .status = .ok, .body = response_body };
    }

    // /api/:slug/status
    if (segments.len == 3 and eql(segments[2], "status") and method == .GET) {
        return getStatus(store, arena, slug);
    }

    // /api/:slug/assets
    if (segments.len == 3 and eql(segments[2], "assets")) {
        if (method == .GET) return getAssets(store, arena, slug);
        if (method == .POST) return addAsset(store, arena, slug, body);
    }

    // /api/:slug/assets/:id
    if (segments.len == 4 and eql(segments[2], "assets") and method == .DELETE) {
        return deleteAsset(store, arena, slug, segments[3]);
    }

    return errorResponse(arena, .not_found, "Not found");
}

fn createSlug(store: *Store, arena: std.mem.Allocator, body: []const u8) !Response {
    var requested: ?[]const u8 = null;

    if (body.len > 0) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
            return errorResponse(arena, .bad_request, "Invalid JSON body");
        };
        if (jsonString(parsed, "slug")) |slug| requested = slug;
    }

    const slug = if (requested) |candidate| blk: {
        if (!isValidSlug(candidate)) {
            return errorResponse(arena, .bad_request, "Invalid slug. Use lowercase letters, numbers, and single hyphens (2-32 chars).");
        }
        if (slugExists(store, candidate)) {
            return errorResponse(arena, .conflict, "This slug is already taken.");
        }
        break :blk candidate;
    } else try generateSlug(store, arena, store.io);

    const now = nowMs(store.io);
    const key = try std.fmt.allocPrint(arena, "slug:{s}", .{slug});
    const created = try std.fmt.allocPrint(arena, "{d}", .{now});
    const fields = [_]store_mod.Field{
        .{ .field = "slug", .value = slug },
        .{ .field = "createdAt", .value = created },
    };
    _ = store.hset(key, &fields) catch {
        return errorResponse(arena, .internal_server_error, "Failed to create slug");
    };
    _ = store.expire(key, 3600);

    const response = try std.fmt.allocPrint(arena, "{{\"ok\":true,\"data\":{{\"slug\":\"{s}\"}}}}", .{slug});
    return .{ .status = .ok, .body = response };
}

fn deleteSlug(store: *Store, arena: std.mem.Allocator, slug: []const u8) !Response {
    const slug_key = try std.fmt.allocPrint(arena, "slug:{s}", .{slug});
    const assets_key = try std.fmt.allocPrint(arena, "slug:{s}:assets", .{slug});

    const deleted = store.del(&[_][]const u8{slug_key});
    _ = store.del(&[_][]const u8{assets_key});
    if (deleted == 0) return errorResponse(arena, .not_found, "Space not found");

    return .{ .status = .ok, .body = "{\"ok\":true}" };
}

fn getStatus(store: *Store, arena: std.mem.Allocator, slug: []const u8) !Response {
    const slug_key = try std.fmt.allocPrint(arena, "slug:{s}", .{slug});
    const assets_key = try std.fmt.allocPrint(arena, "slug:{s}:assets", .{slug});

    if (store.exists(&[_][]const u8{slug_key}) == 0) {
        return .{
            .status = .ok,
            .body = "{\"ok\":true,\"data\":{\"exists\":false,\"disappearing\":false,\"disappearAt\":null,\"assetsCount\":0}}",
        };
    }

    const count = store.hlen(assets_key) catch 0;
    var empty_since: ?i64 = null;
    const meta_opt: ?store_mod.HashCopy = store.hgetall(arena, slug_key) catch null;
    if (meta_opt) |*meta| {
        if (meta.map.get("emptySince")) |value| {
            empty_since = std.fmt.parseInt(i64, value, 10) catch null;
        }
    }

    const disappearing = count == 0 and empty_since != null;
    const disappear_at = if (disappearing) empty_since.? + GRACE_SECONDS * 1000 else null;

    const body = if (disappear_at) |at|
        try std.fmt.allocPrint(arena, "{{\"ok\":true,\"data\":{{\"exists\":true,\"disappearing\":true,\"disappearAt\":{d},\"assetsCount\":0}}}}", .{at})
    else
        try std.fmt.allocPrint(arena, "{{\"ok\":true,\"data\":{{\"exists\":true,\"disappearing\":false,\"disappearAt\":null,\"assetsCount\":{d}}}}}", .{count});

    return .{ .status = .ok, .body = body };
}

fn getAssets(store: *Store, arena: std.mem.Allocator, slug: []const u8) !Response {
    const slug_key = try std.fmt.allocPrint(arena, "slug:{s}", .{slug});
    const assets_key = try std.fmt.allocPrint(arena, "slug:{s}:assets", .{slug});

    if (store.exists(&[_][]const u8{slug_key}) == 0) {
        return errorResponse(arena, .not_found, "Space not found");
    }

    var parsed: std.ArrayList(ParsedAsset) = .empty;
    defer parsed.deinit(arena);

    const now = nowMs(store.io);
    const copy_opt: ?store_mod.HashCopy = store.hgetall(arena, assets_key) catch null;
    if (copy_opt) |*copy| {
        var it = copy.map.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            const raw = entry.value_ptr.*;
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch continue;
            const expires = jsonInt(value, "expiresAt") orelse 0;

            if (expires <= now) {
                _ = store.hdel(assets_key, &[_][]const u8{id}) catch 0;
                continue;
            }

            try parsed.append(arena, .{
                .value = value,
                .createdAt = jsonInt(value, "createdAt") orelse 0,
            });
        }
    }

    std.mem.sort(ParsedAsset, parsed.items, {}, struct {
        fn lessThan(_: void, a: ParsedAsset, b: ParsedAsset) bool {
            return a.createdAt < b.createdAt;
        }
    }.lessThan);

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"ok\":true,\"data\":[");
    for (parsed.items, 0..) |item, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(item.value, .{}, &out.writer);
    }
    try out.writer.writeAll("]}");

    return .{ .status = .ok, .body = try out.toOwnedSlice() };
}

fn addAsset(store: *Store, arena: std.mem.Allocator, slug: []const u8, body: []const u8) !Response {
    const slug_key = try std.fmt.allocPrint(arena, "slug:{s}", .{slug});
    const assets_key = try std.fmt.allocPrint(arena, "slug:{s}:assets", .{slug});

    if (store.exists(&[_][]const u8{slug_key}) == 0) {
        return errorResponse(arena, .not_found, "Space not found");
    }

    if (body.len == 0) return errorResponse(arena, .bad_request, "Empty request body");

    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
        return errorResponse(arena, .bad_request, "Invalid JSON body");
    };
    switch (value) {
        .object => {},
        else => return errorResponse(arena, .bad_request, "Expected a JSON object"),
    }

    const ttl = clampTtl(jsonInt(value, "ttl") orelse 300);
    const id = try makeId(arena, store.io);
    const now = nowMs(store.io);
    const expires_at = now + ttl * 1000;

    var asset_json: []const u8 = undefined;
    if (jsonString(value, "content")) |content| {
        if (content.len == 0) return errorResponse(arena, .bad_request, "Content cannot be empty");
        if (content.len > MAX_TEXT_BYTES) return errorResponse(arena, .payload_too_large, "Text too large");
        asset_json = try buildAssetJson(arena, .{
            .id = id,
            .asset_type = "text",
            .content = content,
            .ttl = ttl,
            .created_at = now,
            .expires_at = expires_at,
        });
    } else {
        const data = jsonString(value, "data") orelse return errorResponse(arena, .bad_request, "Missing content or data");
        if (!std.mem.startsWith(u8, data, "data:")) return errorResponse(arena, .bad_request, "Invalid data URL");
        if (data.len > MAX_REQUEST_BYTES) return errorResponse(arena, .payload_too_large, "File too large");

        const requested_type = jsonString(value, "type") orelse "file";
        if (!eql(requested_type, "image") and !eql(requested_type, "file")) {
            return errorResponse(arena, .bad_request, "Invalid asset type");
        }

        const mime = jsonString(value, "mimeType") orelse mimeFromDataUrl(data);
        const file_name = jsonString(value, "fileName") orelse "";
        const size = jsonInt(value, "size") orelse 0;
        const estimated_size = decodedDataUrlSize(data);
        if (size < 0 or size > MAX_IMAGE_BYTES or estimated_size > MAX_IMAGE_BYTES) {
            return errorResponse(arena, .payload_too_large, "File too large");
        }

        asset_json = try buildAssetJson(arena, .{
            .id = id,
            .asset_type = requested_type,
            .data = data,
            .mime_type = mime,
            .file_name = file_name,
            .size = size,
            .ttl = ttl,
            .created_at = now,
            .expires_at = expires_at,
        });
    }

    const fields = [_]store_mod.Field{.{ .field = id, .value = asset_json }};
    _ = store.hset(assets_key, &fields) catch {
        return errorResponse(arena, .internal_server_error, "Failed to save asset");
    };
    _ = store.expire(assets_key, @intCast(ttl + 60));
    _ = store.hdel(slug_key, &[_][]const u8{"emptySince"}) catch 0;
    _ = store.expire(slug_key, @intCast(@max(ttl + 60, 3600)));

    const response = try std.fmt.allocPrint(arena, "{{\"ok\":true,\"data\":{s}}}", .{asset_json});
    return .{ .status = .ok, .body = response };
}

const AssetJson = struct {
    id: []const u8,
    asset_type: []const u8,
    content: ?[]const u8 = null,
    data: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    file_name: ?[]const u8 = null,
    size: ?i64 = null,
    ttl: i64,
    created_at: i64,
    expires_at: i64,
};

fn buildAssetJson(arena: std.mem.Allocator, asset: AssetJson) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    try stringify.beginObject();
    try stringify.objectField("id");
    try stringify.write(asset.id);
    try stringify.objectField("type");
    try stringify.write(asset.asset_type);

    if (asset.content) |content| {
        try stringify.objectField("content");
        try stringify.write(content);
    }
    if (asset.data) |data| {
        try stringify.objectField("data");
        try stringify.write(data);
    }
    if (asset.mime_type) |mime| {
        try stringify.objectField("mimeType");
        try stringify.write(mime);
    }
    if (asset.file_name) |file_name| {
        try stringify.objectField("fileName");
        try stringify.write(file_name);
    }
    if (asset.size) |size| {
        try stringify.objectField("size");
        try stringify.write(size);
    }

    try stringify.objectField("ttl");
    try stringify.write(asset.ttl);
    try stringify.objectField("createdAt");
    try stringify.write(asset.created_at);
    try stringify.objectField("expiresAt");
    try stringify.write(asset.expires_at);
    try stringify.endObject();

    return out.toOwnedSlice();
}

fn deleteAsset(store: *Store, arena: std.mem.Allocator, slug: []const u8, asset_id: []const u8) !Response {
    const slug_key = try std.fmt.allocPrint(arena, "slug:{s}", .{slug});
    const assets_key = try std.fmt.allocPrint(arena, "slug:{s}:assets", .{slug});

    const removed = store.hdel(assets_key, &[_][]const u8{asset_id}) catch 0;
    if (removed == 0) return errorResponse(arena, .not_found, "Asset not found");

    const remaining = store.hlen(assets_key) catch 0;
    if (remaining == 0) {
        const now = nowMs(store.io);
        const value = try std.fmt.allocPrint(arena, "{d}", .{now});
        const fields = [_]store_mod.Field{.{ .field = "emptySince", .value = value }};
        _ = store.hset(slug_key, &fields) catch {};
        _ = store.expire(slug_key, GRACE_SECONDS + 60);
    }

    return .{ .status = .ok, .body = "{\"ok\":true}" };
}

fn generateSlug(store: *Store, arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var attempts: usize = 0;
    while (attempts < 30) : (attempts += 1) {
        const adjective = words.adjectives[randomIndex(io, words.adjectives.len)];
        const noun = words.nouns[randomIndex(io, words.nouns.len)];
        const candidate = try std.fmt.allocPrint(arena, "{s}-{s}", .{ adjective, noun });
        if (isValidSlug(candidate) and !slugExists(store, candidate)) return candidate;
    }

    const all_words = words.adjectives ++ words.nouns;
    const base = all_words[randomIndex(io, all_words.len)];
    var number: usize = 1;
    while (number <= 999) : (number += 1) {
        const candidate = try std.fmt.allocPrint(arena, "{s}{d}", .{ base, number });
        if (isValidSlug(candidate) and !slugExists(store, candidate)) return candidate;
    }

    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    attempts = 0;
    while (attempts < 100) : (attempts += 1) {
        var candidate: [6]u8 = undefined;
        for (&candidate) |*char| char.* = alphabet[randomIndex(io, alphabet.len)];
        const owned = try arena.dupe(u8, &candidate);
        if (!slugExists(store, owned)) return owned;
    }

    return error.SlugGenerationFailed;
}

fn slugExists(store: *Store, slug: []const u8) bool {
    var buffer: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&buffer, "slug:{s}", .{slug}) catch return true;
    return store.exists(&[_][]const u8{key}) > 0;
}

pub fn isValidSlug(slug: []const u8) bool {
    if (slug.len < 2 or slug.len > 32) return false;
    var last_was_hyphen = false;
    for (slug, 0..) |char, index| {
        if (char == '-') {
            if (index == 0 or index == slug.len - 1 or last_was_hyphen) return false;
            last_was_hyphen = true;
        } else if (std.ascii.isLower(char) or std.ascii.isDigit(char)) {
            last_was_hyphen = false;
        } else {
            return false;
        }
    }
    return true;
}

fn randomIndex(io: std.Io, length: usize) usize {
    var bytes: [4]u8 = undefined;
    io.random(&bytes);
    const value = std.mem.readInt(u32, &bytes, .little);
    return value % @as(u32, @intCast(length));
}

fn makeId(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var random: [9]u8 = undefined;
    io.random(&random);
    var encoded: [12]u8 = undefined;
    const value = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &random);
    return arena.dupe(u8, value);
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn clampTtl(ttl: i64) i64 {
    return @min(MAX_TTL, @max(MIN_TTL, ttl));
}

fn decodedDataUrlSize(data: []const u8) usize {
    const comma = std.mem.indexOfScalar(u8, data, ',') orelse return data.len;
    const payload = data[comma + 1 ..];
    if (payload.len == 0) return 0;

    const padding: usize = if (payload[payload.len - 1] == '=')
        (if (payload.len > 1 and payload[payload.len - 2] == '=') 2 else 1)
    else
        0;
    return (payload.len / 4) * 3 - padding;
}

fn mimeFromDataUrl(data: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, data, "data:")) return "";
    const rest = data["data:".len..];
    const end = std.mem.indexOfAny(u8, rest, ";,") orelse return "";
    return rest[0..end];
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn jsonString(value: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (value) {
        .object => |object| switch (object.get(key) orelse return null) {
            .string => |string| string,
            else => null,
        },
        else => null,
    };
}

fn jsonInt(value: std.json.Value, key: []const u8) ?i64 {
    return switch (value) {
        .object => |object| switch (object.get(key) orelse return null) {
            .integer => |integer| integer,
            .float => |float| if (std.math.isFinite(float) and
                float >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
                float <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
                @intFromFloat(float)
            else
                null,
            else => null,
        },
        else => null,
    };
}

fn errorResponse(arena: std.mem.Allocator, status: std.http.Status, message: []const u8) !Response {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"ok\":false,\"error\":");
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeByte('}');
    return .{ .status = status, .body = try out.toOwnedSlice() };
}
