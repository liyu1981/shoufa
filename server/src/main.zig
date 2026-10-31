//! Shoufa self-hosted Redis-compatible REST server.
//!
//! Implements the Upstash REST wire format used by `@upstash/redis`:
//!   POST /           body: ["HSET", "key", "field", "value"]
//!   POST /pipeline   body: [["PING"], ["GET", "key"]]
//!
//! Authentication uses Bearer tokens from the server config file
//! (~/.config/shoufad/config for a manual run, /etc/shoufad/config for systemd).

const std = @import("std");
const config = @import("config.zig");
const store_mod = @import("store.zig");
const protocol = @import("protocol.zig");
const service = @import("service.zig");

const Store = store_mod.Store;
const Config = config.Config;

const max_head_bytes = 16 * 1024;
const transfer_buffer_bytes = 32 * 1024;

const cors_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "cache-control", .value = "no-store" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-headers", .value = "authorization,content-type" },
    .{ .name = "access-control-allow-methods", .value = "GET,POST,OPTIONS" },
};

const health_body = "{\"ok\":true,\"service\":\"shoufad\"}";
const unauthorized_body = "{\"error\":\"Unauthorized\"}";
const internal_error_body = "{\"error\":\"ERR internal server error\"}";

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
            try std.Io.File.stdout().writeStreamingAll(init.io, "shoufad 0.1.0\n");
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

    var store = Store.init(init.gpa, io, cfg.max_memory_bytes, cfg.sweep_interval_ms);
    defer store.deinit();

    const address = try std.Io.net.IpAddress.parse(cfg.bind, cfg.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const sweeper = try std.Thread.spawn(.{}, sweepLoop, .{&store});
    sweeper.detach();

    std.log.info("shoufad listening on http://{s}:{d}", .{ cfg.bind, cfg.port });
    std.log.info("config: {s}", .{cfg.path});
    std.log.info("max_memory={d} bytes, sweep_interval={d} ms, auth={s}", .{
        cfg.max_memory_bytes,
        cfg.sweep_interval_ms,
        if (cfg.allow_anonymous) "anonymous" else "api-key",
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

fn loadConfig(init: std.process.Init) !Config {
    return config.load(init) catch |err| switch (err) {
        error.NoApiKey => {
            std.log.err("no api_key configured in the config file", .{});
            std.log.err("add a line like `api_key = sfr_...` or set `allow_anonymous = true`", .{});
            return err;
        },
        error.MaxMemoryTooLarge => {
            std.log.err("max_memory_bytes must be <= {d} (5 GiB)", .{config.MAX_MEMORY_CAP});
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
            respondStatic(&request, .internal_server_error, internal_error_body) catch {};
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
        request.respond("", .{
            .status = .no_content,
            .extra_headers = &cors_headers,
        }) catch return;
        return;
    }

    const target = request.head.target;
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..path_end];
    const query = if (path_end < target.len) target[path_end + 1 ..] else "";

    if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/healthz")) {
        try request.respond(health_body, .{
            .status = .ok,
            .extra_headers = &cors_headers,
        });
        return;
    }

    if (!authorized(cfg, request, query)) {
        try request.respond(unauthorized_body, .{
            .status = .unauthorized,
            .extra_headers = &cors_headers,
        });
        return;
    }

    // @upstash/redis sends `Upstash-Encoding: base64` and expects string
    // results to be base64-encoded. Capture this before reading the body
    // invalidates the header buffer.
    const string_encoding: protocol.StringEncoding = blk: {
        const header = headerValue(request, "upstash-encoding") orelse break :blk .plain;
        const trimmed = std.mem.trim(u8, header, " \t");
        break :blk if (std.ascii.eqlIgnoreCase(trimmed, "base64")) .base64 else .plain;
    };

    // Read the request body. The transfer buffer needs to stay alive while the
    // returned body reader is in use.
    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const body_reader = request.readerExpectContinue(&transfer_buffer) catch {
        try request.respond("{\"error\":\"ERR invalid request body\"}", .{
            .status = .bad_request,
            .extra_headers = &cors_headers,
        });
        return;
    };
    const body = body_reader.allocRemaining(gpa, .limited(cfg.max_request_bytes)) catch |err| {
        switch (err) {
            error.StreamTooLong => try request.respond("{\"error\":\"ERR request body too large\"}", .{
                .status = .payload_too_large,
                .extra_headers = &cors_headers,
            }),
            else => try request.respond("{\"error\":\"ERR failed to read request body\"}", .{
                .status = .bad_request,
                .extra_headers = &cors_headers,
            }),
        }
        return;
    };
    defer gpa.free(body);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    if (body.len == 0) {
        const argv = parsePathCommand(arena_allocator, path) catch {
            try request.respond("{\"error\":\"ERR empty request body\"}", .{
                .status = .bad_request,
                .extra_headers = &cors_headers,
            });
            return;
        };
        try executeSingle(gpa, store, request, argv, string_encoding);
        return;
    }

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena_allocator, body, .{}) catch {
        try request.respond("{\"error\":\"ERR invalid JSON body\"}", .{
            .status = .bad_request,
            .extra_headers = &cors_headers,
        });
        return;
    };

    switch (root) {
        .array => |array| {
            if (array.items.len == 0) {
                try request.respond("{\"error\":\"ERR empty command\"}", .{
                    .status = .bad_request,
                    .extra_headers = &cors_headers,
                });
                return;
            }

            const first_is_array = switch (array.items[0]) {
                .array => true,
                else => false,
            };

            if (first_is_array or std.mem.eql(u8, path, "/pipeline")) {
                try executePipeline(gpa, arena_allocator, store, request, array.items, string_encoding);
            } else {
                const argv = valueArrayToArgs(arena_allocator, array.items) catch {
                    try request.respond("{\"error\":\"ERR command arguments must be strings\"}", .{
                        .status = .bad_request,
                        .extra_headers = &cors_headers,
                    });
                    return;
                };
                try executeSingle(gpa, store, request, argv, string_encoding);
            }
        },
        else => {
            try request.respond("{\"error\":\"ERR expected a JSON command array\"}", .{
                .status = .bad_request,
                .extra_headers = &cors_headers,
            });
        },
    }
}

fn executeSingle(
    gpa: std.mem.Allocator,
    store: *Store,
    request: *std.http.Server.Request,
    argv: []const []const u8,
    encoding: protocol.StringEncoding,
) !void {
    const result = protocol.execute(store, gpa, argv, encoding) catch {
        try request.respond(internal_error_body, .{
            .status = .internal_server_error,
            .extra_headers = &cors_headers,
        });
        return;
    };
    defer gpa.free(result.body);

    try request.respond(result.body, .{
        .status = if (result.is_error) .bad_request else .ok,
        .extra_headers = &cors_headers,
    });
}

fn executePipeline(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    store: *Store,
    request: *std.http.Server.Request,
    commands: []const std.json.Value,
    encoding: protocol.StringEncoding,
) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try out.writer.writeAll("[");
    for (commands, 0..) |command, index| {
        if (index != 0) try out.writer.writeAll(",");

        var argv: []const []const u8 = &.{};
        switch (command) {
            .array => |args| {
                argv = valueArrayToArgs(arena, args.items) catch &.{};
            },
            else => {},
        }

        if (argv.len == 0) {
            try out.writer.writeAll("{\"error\":\"ERR each pipeline item must be a command array\"}");
            continue;
        }

        {
            const result = protocol.execute(store, gpa, argv, encoding) catch {
                try out.writer.writeAll(internal_error_body);
                continue;
            };
            defer gpa.free(result.body);
            try out.writer.writeAll(result.body);
        }
    }
    try out.writer.writeAll("]");

    const response_body = try out.toOwnedSlice();
    defer gpa.free(response_body);
    try request.respond(response_body, .{
        .status = .ok,
        .extra_headers = &cors_headers,
    });
}

fn respondStatic(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{
        .status = status,
        .extra_headers = &cors_headers,
    });
}

fn authorized(cfg: *const Config, request: *std.http.Server.Request, query: []const u8) bool {
    if (cfg.allow_anonymous) return true;

    var token: ?[]const u8 = null;
    if (headerValue(request, "authorization")) |value| {
        const trimmed = std.mem.trim(u8, value, " \t");
        if (trimmed.len > 7 and std.ascii.eqlIgnoreCase(trimmed[0..7], "Bearer ")) {
            token = std.mem.trim(u8, trimmed[7..], " \t");
        }
    }
    if (token == null) {
        token = queryParam(query, "token");
    }

    const provided = token orelse return false;
    if (provided.len == 0) return false;
    for (cfg.api_keys) |key| {
        if (std.mem.eql(u8, provided, key)) return true;
    }
    return false;
}

fn headerValue(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn parsePathCommand(arena: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, path, "/");
    if (trimmed.len == 0) return error.BadRequest;

    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, trimmed, '/');
    while (it.next()) |part| {
        const decoded = try percentDecode(arena, part);
        try parts.append(arena, decoded);
    }
    return parts.toOwnedSlice(arena);
}

fn percentDecode(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, value, '%') == null) return arena.dupe(u8, value);

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '%' and i + 2 < value.len) {
            const high = std.fmt.charToDigit(value[i + 1], 16) catch {
                try out.append(arena, value[i]);
                i += 1;
                continue;
            };
            const low = std.fmt.charToDigit(value[i + 2], 16) catch {
                try out.append(arena, value[i]);
                i += 1;
                continue;
            };
            try out.append(arena, (high << 4) | low);
            i += 3;
        } else {
            try out.append(arena, value[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

fn valueArrayToArgs(arena: std.mem.Allocator, values: []const std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.ensureTotalCapacity(arena, values.len);
    for (values) |value| {
        try out.append(arena, try valueToString(arena, value));
    }
    return out.toOwnedSlice(arena);
}

fn valueToString(arena: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        .bool => |b| if (b) "true" else "false",
        else => error.InvalidCommandArgument,
    };
}
