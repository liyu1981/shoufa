//! Shoufa self-hosted server: JSON API, change notifications, and the
//! embedded Vite frontend, all on one origin.

const std = @import("std");
const config = @import("config.zig");
const store_mod = @import("store.zig");
const api = @import("api.zig");
const web = @import("web_assets.zig");
const service = @import("service.zig");
const version_info = @import("version.zig");

const Store = store_mod.Store;
const Config = config.Config;

const max_head_bytes = 16 * 1024;
const transfer_buffer_bytes = 32 * 1024;

const security_headers = [_]std.http.Header{
    .{ .name = "content-security-policy", .value = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; worker-src 'self'; manifest-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "referrer-policy", .value = "strict-origin-when-cross-origin" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "permissions-policy", .value = "camera=(), microphone=(), geolocation=(), payment=()" },
    .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
    .{ .name = "cross-origin-resource-policy", .value = "same-origin" },
    .{ .name = "strict-transport-security", .value = "max-age=63072000; includeSubDomains" },
};

const health_body = "{\"ok\":true,\"service\":\"shoufad\",\"version\":\"" ++ version_info.version ++ "\"}";
const internal_error_body = "{\"ok\":false,\"error\":\"Internal server error\"}";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len > 1) {
        const command = args[1];
        if (std.mem.eql(u8, command, "service-install")) {
            service.install(init, args[2..]) catch |err| {
                std.log.err("service-install failed: {t}", .{err});
                std.process.exit(1);
            };
            return;
        }
        if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
            try service.printUsage(init.io);
            return;
        }
        if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-V")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "shoufad " ++ version_info.version ++ "\n");
            return;
        }
        if (!std.mem.startsWith(u8, command, "-")) {
            std.log.err("unknown command: {s}", .{command});
            try service.printUsage(init.io);
            std.process.exit(1);
        }
    }

    try runServer(init);
}

fn runServer(init: std.process.Init) !void {
    const cfg = try loadConfig(init);
    const io = init.io;

    const instance_lock = try acquireInstanceLock(io, cfg.port);
    defer if (instance_lock) |file| file.close(io);

    var store = Store.init(init.gpa, io, cfg.max_memory_bytes, cfg.sweep_interval_ms, cfg.data_dir) catch |err| {
        std.log.err("failed to open data directory {s}: {t}", .{ cfg.data_dir, err });
        return err;
    };
    defer store.deinit();

    const address = try std.Io.net.IpAddress.parse(cfg.bind, cfg.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const sweeper = try std.Thread.spawn(.{}, sweepLoop, .{&store});
    sweeper.detach();

    std.log.info("shoufad {s} listening on http://{s}:{d}", .{ version_info.version, cfg.bind, cfg.port });
    std.log.info("config: {s}", .{cfg.path});
    std.log.info("data dir: {s}", .{cfg.data_dir});
    std.log.info("memory cache={d} bytes (LRU), sweep_interval={d} ms", .{
        cfg.max_memory_bytes,
        cfg.sweep_interval_ms,
    });

    while (true) {
        const stream = listener.accept(io) catch |err| {
            std.log.warn("accept failed: {t}", .{err});
            continue;
        };
        const thread = std.Thread.spawn(.{}, connectionThread, .{
            init.gpa,
            io,
            stream,
            &store,
            &cfg,
        }) catch |err| {
            std.log.warn("failed to spawn connection thread: {t}", .{err});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn acquireInstanceLock(io: std.Io, port: u16) !?std.Io.File {
    var buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "/tmp/shoufad-{d}.lock", .{port});
    const file = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
    });

    const locked = file.tryLock(io, .exclusive) catch |err| switch (err) {
        error.FileLocksUnsupported => {
            file.close(io);
            std.log.warn("file locks are unsupported here; cannot enforce single-instance mode", .{});
            return null;
        },
        else => {
            file.close(io);
            return err;
        },
    };

    if (!locked) {
        file.close(io);
        std.log.err("another shoufad instance is already running on port {d}", .{port});
        return error.AlreadyRunning;
    }

    return file;
}

fn loadConfig(init: std.process.Init) !Config {
    return config.load(init) catch |err| switch (err) {
        error.MaxMemoryTooLarge => {
            std.log.err("max_memory_bytes (memory cache budget) must be <= {d} (5 GiB)", .{config.MAX_MEMORY_CAP});
            return err;
        },
        else => return err,
    };
}

fn sweepLoop(store: *Store) void {
    while (true) {
        std.Io.sleep(store.io, std.Io.Duration.fromMilliseconds(@intCast(store.sweep_interval_ms)), .awake) catch {};
        store.sweepExpired();
    }
}

fn connectionThread(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    store: *Store,
    cfg: *const Config,
) void {
    defer stream.close(io);
    handleConnection(gpa, io, stream, store, cfg) catch |err| {
        std.log.debug("connection closed: {t}", .{err});
    };
}

fn handleConnection(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    store: *Store,
    cfg: *const Config,
) !void {
    var read_buffer: [max_head_bytes]u8 = undefined;
    var write_buffer: [max_head_bytes]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            error.HttpRequestTruncated => return,
            error.HttpHeadersOversize => return,
            else => return,
        };

        handleRequest(gpa, store, cfg, &request) catch |err| {
            std.log.debug("request failed: {t}", .{err});
            sendResponse(&request, .internal_server_error, internal_error_body, "application/json; charset=utf-8", "no-store") catch {};
            return;
        };

        if (!request.head.keep_alive) return;
    }
}

fn handleRequest(
    gpa: std.mem.Allocator,
    store: *Store,
    cfg: *const Config,
    request: *std.http.Server.Request,
) !void {
    if (request.head.method == .OPTIONS) {
        try sendResponse(request, .method_not_allowed, "{\"ok\":false,\"error\":\"Method not allowed\"}", "application/json; charset=utf-8", "no-store");
        return;
    }

    const target = request.head.target;
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..path_end];
    const query = if (path_end < target.len) target[path_end + 1 ..] else "";

    if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/healthz")) {
        try sendResponse(request, .ok, health_body, "application/json; charset=utf-8", "no-store");
        return;
    }

    if (std.mem.eql(u8, path, "/wait")) {
        try handleWait(store, request, query);
        return;
    }

    if (std.mem.startsWith(u8, path, "/api/") or std.mem.eql(u8, path, "/api")) {
        if (request.head.method != .GET and request.head.method != .POST and request.head.method != .DELETE) {
            try sendResponse(request, .method_not_allowed, "{\"ok\":false,\"error\":\"Method not allowed\"}", "application/json; charset=utf-8", "no-store");
            return;
        }

        if (request.head.method != .GET and !isSameOrigin(request)) {
            try sendResponse(request, .forbidden, "{\"ok\":false,\"error\":\"Cross-origin request rejected\"}", "application/json; charset=utf-8", "no-store");
            return;
        }

        // Capture headers before reading the body; reading invalidates the
        // request head buffer and header iteration.
        const content_type = headerValue(request, "content-type") orelse "";
        if (request.head.method == .POST and !isJsonContentType(content_type)) {
            try sendResponse(request, .unsupported_media_type, "{\"ok\":false,\"error\":\"Expected application/json\"}", "application/json; charset=utf-8", "no-store");
            return;
        }

        // Copy path segments before reading the body. Reading the body
        // invalidates the request head buffer, and a large upload can
        // otherwise corrupt the route segments.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const arena_allocator = arena.allocator();
        const segments = splitPath(arena_allocator, path) catch {
            try sendResponse(request, .bad_request, "{\"ok\":false,\"error\":\"Invalid path\"}", "application/json; charset=utf-8", "no-store");
            return;
        };

        var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
        const body_reader = request.readerExpectContinue(&transfer_buffer) catch {
            try sendResponse(request, .bad_request, "{\"ok\":false,\"error\":\"Invalid request body\"}", "application/json; charset=utf-8", "no-store");
            return;
        };
        const body = body_reader.allocRemaining(gpa, .limited(cfg.max_request_bytes)) catch |err| switch (err) {
            error.StreamTooLong => {
                try sendResponse(request, .payload_too_large, "{\"ok\":false,\"error\":\"Request body too large\"}", "application/json; charset=utf-8", "no-store");
                return;
            },
            else => {
                try sendResponse(request, .bad_request, "{\"ok\":false,\"error\":\"Failed to read request body\"}", "application/json; charset=utf-8", "no-store");
                return;
            },
        };
        defer gpa.free(body);

        const result = api.handle(store, arena_allocator, request.head.method, segments, body) catch |err| {
            std.log.err("api error: {t}", .{err});
            try sendResponse(request, .internal_server_error, internal_error_body, "application/json; charset=utf-8", "no-store");
            return;
        };

        try sendResponse(request, result.status, result.body, "application/json; charset=utf-8", "no-store");
        return;
    }

    if (request.head.method != .GET and request.head.method != .HEAD) {
        try sendResponse(request, .method_not_allowed, "{\"ok\":false,\"error\":\"Method not allowed\"}", "application/json; charset=utf-8", "no-store");
        return;
    }

    try serveStatic(request, path);
}

fn handleWait(store: *Store, request: *std.http.Server.Request, query: []const u8) !void {
    if (request.head.method != .GET) {
        try sendResponse(request, .method_not_allowed, "{\"ok\":false,\"error\":\"Method not allowed\"}", "application/json; charset=utf-8", "no-store");
        return;
    }

    const slug = queryParam(query, "slug") orelse {
        try sendResponse(request, .bad_request, "{\"ok\":false,\"error\":\"Missing slug\"}", "application/json; charset=utf-8", "no-store");
        return;
    };
    if (!api.isValidSlug(slug)) {
        try sendResponse(request, .bad_request, "{\"ok\":false,\"error\":\"Invalid slug\"}", "application/json; charset=utf-8", "no-store");
        return;
    }

    const since_raw = queryParam(query, "rev");
    var buffer: [128]u8 = undefined;
    const body = if (since_raw) |raw| blk: {
        const since = std.fmt.parseInt(u64, raw, 10) catch 0;
        const revision = store.waitForRevision(slug, since, 25_000);
        break :blk std.fmt.bufPrint(&buffer, "{{\"rev\":{d},\"changed\":{s}}}", .{
            revision,
            if (revision != since) "true" else "false",
        }) catch "{\"rev\":0,\"changed\":false}";
    } else blk: {
        const revision = store.revision(slug);
        break :blk std.fmt.bufPrint(&buffer, "{{\"rev\":{d},\"changed\":false}}", .{revision}) catch "{\"rev\":0,\"changed\":false}";
    };

    try sendResponse(request, .ok, body, "application/json; charset=utf-8", "no-store");
}

fn serveStatic(request: *std.http.Server.Request, path: []const u8) !void {
    if (findAsset(path)) |asset| {
        try sendResponse(request, .ok, asset.data, asset.content_type, asset.cache_control);
        return;
    }

    // SPA fallback for /s/<slug> and other client-side routes.
    if (!looksLikeAsset(path)) {
        if (findAsset("/index.html")) |index| {
            try sendResponse(request, .ok, index.data, index.content_type, index.cache_control);
            return;
        }
    }

    try sendResponse(request, .not_found, "Not found", "text/plain; charset=utf-8", "no-store");
}

fn findAsset(path: []const u8) ?web.Asset {
    const normalized = if (std.mem.eql(u8, path, "/")) "/index.html" else path;
    for (web.assets) |asset| {
        if (std.mem.eql(u8, asset.path, normalized)) return asset;
    }
    return null;
}

fn looksLikeAsset(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "/assets/") or std.mem.startsWith(u8, path, "/icons/")) return true;
    if (std.mem.eql(u8, path, "/sw.js") or std.mem.eql(u8, path, "/manifest.webmanifest") or std.mem.eql(u8, path, "/robots.txt")) return true;

    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const last_segment = path[last_slash + 1 ..];
    return std.mem.indexOfScalar(u8, last_segment, '.') != null;
}

fn sendResponse(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
    content_type: []const u8,
    cache_control: []const u8,
) !void {
    var headers: [security_headers.len + 2]std.http.Header = undefined;
    var count: usize = 0;
    for (security_headers) |header| {
        headers[count] = header;
        count += 1;
    }
    headers[count] = .{ .name = "content-type", .value = content_type };
    count += 1;
    headers[count] = .{ .name = "cache-control", .value = cache_control };
    count += 1;

    try request.respond(body, .{
        .status = status,
        .extra_headers = headers[0..count],
    });
}

fn splitPath(arena: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, path, "/"), '/');
    while (it.next()) |part| {
        if (part.len > 0) try parts.append(arena, try arena.dupe(u8, part));
    }
    return parts.toOwnedSlice(arena);
}

fn isSameOrigin(request: *std.http.Server.Request) bool {
    if (headerValue(request, "sec-fetch-site")) |site| {
        if (std.ascii.eqlIgnoreCase(site, "cross-site")) return false;
    }

    const origin = headerValue(request, "origin") orelse return true;
    if (std.mem.eql(u8, origin, "null")) return false;

    const host = headerValue(request, "host") orelse return false;
    const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return false;
    var origin_host = origin[scheme_end + 3 ..];
    if (std.mem.indexOfScalar(u8, origin_host, '/')) |slash| origin_host = origin_host[0..slash];

    return std.ascii.eqlIgnoreCase(stripPort(origin_host), stripPort(host));
}

fn stripPort(value: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, value, ':')) |colon| {
        // Preserve IPv6 literals such as [::1].
        if (std.mem.indexOfScalar(u8, value, ']')) |bracket| {
            if (colon < bracket) return value;
        }
        return value[0..colon];
    }
    return value;
}

fn headerValue(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return std.mem.trim(u8, header.value, " \t");
        }
    }
    return null;
}

fn isJsonContentType(value: []const u8) bool {
    return value.len >= 16 and std.ascii.eqlIgnoreCase(value[0..16], "application/json");
}

fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}
