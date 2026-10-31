//! Configuration loading for the self-hosted Shoufa Redis server.
//!
//! Default location: ~/.config/shoufad/config
//!
//! The file is intentionally simple (`key = value` lines) and is created with
//! a random API key on first run. Environment variables are not required.

const std = @import("std");

pub const DEFAULT_PORT: u16 = 8079;
pub const DEFAULT_MAX_MEMORY: usize = 5 * 1024 * 1024 * 1024; // 5 GiB
pub const DEFAULT_SWEEP_INTERVAL_MS: u64 = 1_000;
pub const DEFAULT_MAX_REQUEST_BYTES: usize = 128 * 1024 * 1024;
pub const MAX_MEMORY_CAP: usize = 5 * 1024 * 1024 * 1024; // hard cap: 5 GiB

pub const Config = struct {
    /// Path of the config file that was loaded/created.
    path: []const u8,
    bind: []const u8 = "127.0.0.1",
    port: u16 = DEFAULT_PORT,
    max_memory_bytes: usize = DEFAULT_MAX_MEMORY,
    max_request_bytes: usize = DEFAULT_MAX_REQUEST_BYTES,
    sweep_interval_ms: u64 = DEFAULT_SWEEP_INTERVAL_MS,
    allow_anonymous: bool = false,
    api_keys: []const []const u8 = &.{},
};

pub const LoadError = error{
    NoApiKey,
    MaxMemoryTooLarge,
    InvalidPort,
    InvalidNumber,
    InvalidBool,
    ConfigUnreadable,
} || std.mem.Allocator.Error || std.Io.Dir.ReadFileAllocError || std.Io.Dir.CreateDirPathError || std.Io.Dir.WriteFileError || std.Io.Writer.Error || std.Io.File.OpenError;

/// Loads configuration, creating a config file with a random API key if the
/// file does not exist yet.
pub fn load(init: std.process.Init) LoadError!Config {
    const arena = init.arena.allocator();
    const io = init.io;

    const path = try configPath(arena, init);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            const generated = try createDefaultConfig(arena, io, path);
            return parse(arena, path, generated);
        },
        else => return err,
    };

    return parse(arena, path, text);
}

fn configPath(arena: std.mem.Allocator, init: std.process.Init) ![]const u8 {
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config")) {
            i += 1;
            if (i >= args.len) return error.ConfigUnreadable;
            return args[i];
        }
        if (std.mem.startsWith(u8, args[i], "--config=")) {
            return args[i]["--config=".len..];
        }
    }
    if (init.environ_map.get("SHOUFA_REDIS_CONFIG")) |p| {
        if (p.len > 0) return p;
    }
    if (init.environ_map.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(arena, &.{ xdg, "shoufad", "config" });
    }
    if (init.environ_map.get("HOME")) |home| {
        if (home.len > 0) return std.fs.path.join(arena, &.{ home, ".config", "shoufad", "config" });
    }
    return ".config/shoufad/config";
}

pub const GeneratedConfig = struct {
    text: []const u8,
    /// Full key including the `sfr_` prefix.
    token: []const u8,
};

/// Builds a fresh config file body and a random API key. The caller owns the
/// returned memory (usually an arena).
pub fn generate(allocator: std.mem.Allocator, io: std.Io) !GeneratedConfig {
    var random: [24]u8 = undefined;
    io.random(&random);
    var encoded: [std.base64.url_safe_no_pad.Encoder.calcSize(random.len)]u8 = undefined;
    const encoded_token = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &random);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print(
        \\# Shoufa self-hosted Redis REST server
        \\# Generated automatically on first run. Keep this file private (0600).
        \\
        \\bind = 127.0.0.1
        \\port = {d}
        \\max_memory_bytes = {d}
        \\sweep_interval_ms = {d}
        \\
        \\# Add/rotate API keys here. Multiple api_key lines are supported.
        \\api_key = sfr_{s}
        \\
        \\# Set to true to disable authentication (not recommended).
        \\allow_anonymous = false
        \\
    , .{ DEFAULT_PORT, DEFAULT_MAX_MEMORY, DEFAULT_SWEEP_INTERVAL_MS, encoded_token });
    const text = try out.toOwnedSlice();
    const token = try std.fmt.allocPrint(allocator, "sfr_{s}", .{encoded_token});
    return .{ .text = text, .token = token };
}

fn createDefaultConfig(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const generated = try generate(arena, io);

    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = generated.text,
        .flags = .{
            .permissions = @fromBackingInt(@intCast(0o600)),
            .exclusive = true,
        },
    });

    std.log.info("created config file: {s}", .{path});
    std.log.info("generated API key: {s}", .{generated.token});
    return generated.text;
}

fn parse(arena: std.mem.Allocator, path: []const u8, text: []const u8) LoadError!Config {
    var cfg: Config = .{ .path = path };
    var keys: std.ArrayList([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = trimQuotes(std.mem.trim(u8, line[eq + 1 ..], " \t"));

        if (std.ascii.eqlIgnoreCase(key, "bind") or std.ascii.eqlIgnoreCase(key, "host") or std.ascii.eqlIgnoreCase(key, "address")) {
            if (value.len == 0) return error.InvalidNumber;
            cfg.bind = try arena.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "port")) {
            cfg.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
        } else if (std.ascii.eqlIgnoreCase(key, "max_memory") or std.ascii.eqlIgnoreCase(key, "maxmemory")) {
            cfg.max_memory_bytes = parseSize(value) catch return error.InvalidNumber;
        } else if (std.ascii.eqlIgnoreCase(key, "max_memory_bytes")) {
            cfg.max_memory_bytes = std.fmt.parseInt(usize, value, 10) catch return error.InvalidNumber;
        } else if (std.ascii.eqlIgnoreCase(key, "max_request_bytes")) {
            cfg.max_request_bytes = parseSize(value) catch return error.InvalidNumber;
        } else if (std.ascii.eqlIgnoreCase(key, "sweep_interval_ms")) {
            cfg.sweep_interval_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidNumber;
        } else if (std.ascii.eqlIgnoreCase(key, "allow_anonymous")) {
            cfg.allow_anonymous = parseBool(value) catch return error.InvalidBool;
        } else if (std.ascii.eqlIgnoreCase(key, "api_key") or std.ascii.eqlIgnoreCase(key, "token")) {
            if (value.len > 0) try keys.append(arena, try arena.dupe(u8, value));
        }
    }

    if (cfg.max_memory_bytes == 0) cfg.max_memory_bytes = DEFAULT_MAX_MEMORY;
    if (cfg.max_memory_bytes > MAX_MEMORY_CAP) return error.MaxMemoryTooLarge;
    if (cfg.max_request_bytes == 0) cfg.max_request_bytes = DEFAULT_MAX_REQUEST_BYTES;
    if (cfg.sweep_interval_ms == 0) cfg.sweep_interval_ms = DEFAULT_SWEEP_INTERVAL_MS;

    cfg.api_keys = try keys.toOwnedSlice(arena);
    if (!cfg.allow_anonymous and cfg.api_keys.len == 0) return error.NoApiKey;
    return cfg;
}

fn trimQuotes(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return value[1 .. value.len - 1];
        }
    }
    return value;
}

fn parseBool(value: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "no")) return false;
    return error.InvalidBool;
}

fn parseSize(value: []const u8) !usize {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return error.InvalidNumber;

    var digits_end: usize = 0;
    while (digits_end < trimmed.len and (std.ascii.isDigit(trimmed[digits_end]) or trimmed[digits_end] == '.')) : (digits_end += 1) {}
    if (digits_end == 0) return error.InvalidNumber;

    const number_part = trimmed[0..digits_end];
    const suffix = std.mem.trim(u8, trimmed[digits_end..], " \t");

    var multiplier: usize = 1;
    if (suffix.len == 0) {
        multiplier = 1;
    } else if (std.ascii.eqlIgnoreCase(suffix, "b")) {
        multiplier = 1;
    } else if (std.ascii.eqlIgnoreCase(suffix, "k") or std.ascii.eqlIgnoreCase(suffix, "kb")) {
        multiplier = 1000;
    } else if (std.ascii.eqlIgnoreCase(suffix, "ki") or std.ascii.eqlIgnoreCase(suffix, "kib")) {
        multiplier = 1024;
    } else if (std.ascii.eqlIgnoreCase(suffix, "m") or std.ascii.eqlIgnoreCase(suffix, "mb")) {
        multiplier = 1000 * 1000;
    } else if (std.ascii.eqlIgnoreCase(suffix, "mi") or std.ascii.eqlIgnoreCase(suffix, "mib")) {
        multiplier = 1024 * 1024;
    } else if (std.ascii.eqlIgnoreCase(suffix, "g") or std.ascii.eqlIgnoreCase(suffix, "gb")) {
        multiplier = 1000 * 1000 * 1000;
    } else if (std.ascii.eqlIgnoreCase(suffix, "gi") or std.ascii.eqlIgnoreCase(suffix, "gib")) {
        multiplier = 1024 * 1024 * 1024;
    } else {
        return error.InvalidNumber;
    }

    if (std.mem.indexOfScalar(u8, number_part, '.')) |_| {
        const float_value = std.fmt.parseFloat(f64, number_part) catch return error.InvalidNumber;
        const result = float_value * @as(f64, @floatFromInt(multiplier));
        if (result < 0 or result > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidNumber;
        return @intFromFloat(result);
    }

    const base = std.fmt.parseInt(usize, number_part, 10) catch return error.InvalidNumber;
    return std.math.mul(usize, base, multiplier) catch return error.InvalidNumber;
}
