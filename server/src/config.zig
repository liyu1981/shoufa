//! Configuration loading for the self-hosted Shoufa server.
//!
//! Default location: ~/.config/shoufad/config
//!
//! The file is intentionally simple (`key = value` lines) and is created on
//! first run. The app and API are served from the same origin, so no API token
//! is required.

const std = @import("std");

pub const DEFAULT_PORT: u16 = 8079;
/// In-memory cache budget for new installs. Existing configs that set a larger
/// value keep working; `MAX_MEMORY_CAP` is the hard ceiling.
pub const DEFAULT_MAX_MEMORY: usize = 512 * 1024 * 1024; // 512 MiB
pub const DEFAULT_SWEEP_INTERVAL_MS: u64 = 1_000;
pub const DEFAULT_MAX_REQUEST_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_MEMORY_CAP: usize = 5 * 1024 * 1024 * 1024; // hard cap: 5 GiB
pub const DEFAULT_DATA_DIR: []const u8 = "~/.shoufa/data";

pub const Config = struct {
    /// Path of the config file that was loaded/created.
    path: []const u8,
    bind: []const u8 = "127.0.0.1",
    port: u16 = DEFAULT_PORT,
    /// Durable storage root: SQLite metadata plus the sharded object store.
    data_dir: []const u8 = "",
    /// In-memory cache budget. Eviction is least-recently-used.
    max_memory_bytes: usize = DEFAULT_MAX_MEMORY,
    max_request_bytes: usize = DEFAULT_MAX_REQUEST_BYTES,
    sweep_interval_ms: u64 = DEFAULT_SWEEP_INTERVAL_MS,
};

pub const LoadError = error{
    MaxMemoryTooLarge,
    InvalidPort,
    InvalidNumber,
    ConfigUnreadable,
} || std.mem.Allocator.Error || std.Io.Dir.ReadFileAllocError || std.Io.Dir.CreateDirPathError || std.Io.Dir.WriteFileError || std.Io.Writer.Error || std.Io.File.OpenError;

/// Loads configuration, creating a config file if it does not exist yet.
pub fn load(init: std.process.Init) LoadError!Config {
    const arena = init.arena.allocator();
    const io = init.io;

    const path = try configPath(arena, init);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const generated = try generate(arena);
            try writeDefaultConfig(io, path, generated);
            break :blk generated;
        },
        else => return err,
    };

    var cfg = try parse(arena, path, text);
    try applyCliOverrides(arena, init, &cfg);
    if (cfg.data_dir.len == 0) cfg.data_dir = try defaultDataDir(arena, init);
    cfg.data_dir = try expandHome(arena, init, cfg.data_dir);
    return cfg;
}

/// Expands a leading `~/` so config files may say `~/.shoufa/data`.
fn expandHome(arena: std.mem.Allocator, init: std.process.Init, value: []const u8) ![]const u8 {
    if (std.mem.eql(u8, value, "~")) {
        const home = init.environ_map.get("HOME") orelse return arena.dupe(u8, value);
        return arena.dupe(u8, home);
    }
    if (std.mem.startsWith(u8, value, "~/")) {
        const home = init.environ_map.get("HOME") orelse return arena.dupe(u8, value);
        return std.fs.path.join(arena, &.{ home, value[2..] });
    }
    return arena.dupe(u8, value);
}

/// Defaults to ~/.shoufa/data, overridable with SHOUFA_DATA or XDG_DATA_HOME.
fn defaultDataDir(arena: std.mem.Allocator, init: std.process.Init) ![]const u8 {
    if (init.environ_map.get("SHOUFA_DATA")) |p| {
        if (p.len > 0) return arena.dupe(u8, p);
    }
    if (init.environ_map.get("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(arena, &.{ xdg, "shoufa", "data" });
    }
    if (init.environ_map.get("HOME")) |home| {
        if (home.len > 0) return std.fs.path.join(arena, &.{ home, ".shoufa", "data" });
    }
    return arena.dupe(u8, ".shoufa/data");
}

fn applyCliOverrides(arena: std.mem.Allocator, init: std.process.Init, cfg: *Config) !void {
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--bind")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.InvalidNumber;
            cfg.bind = try arena.dupe(u8, args[i]);
        } else if (std.mem.startsWith(u8, arg, "--bind=")) {
            const value = arg["--bind=".len..];
            if (value.len == 0) return error.InvalidNumber;
            cfg.bind = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.InvalidPort;
            cfg.port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            cfg.port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--data")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.InvalidNumber;
            cfg.data_dir = try arena.dupe(u8, args[i]);
        } else if (std.mem.startsWith(u8, arg, "--data=")) {
            const value = arg["--data=".len..];
            if (value.len == 0) return error.InvalidNumber;
            cfg.data_dir = try arena.dupe(u8, value);
        }
    }
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
    if (init.environ_map.get("SHOUFA_CONFIG")) |p| {
        if (p.len > 0) return p;
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

pub fn generate(allocator: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print(
        \\# Shoufa self-hosted server
        \\# Generated automatically on first run.
        \\
        \\bind = 127.0.0.1
        \\port = {d}
        \\
        \\# Durable storage root: SQLite metadata plus the sharded object store.
        \\# Left unset here so the default (or $SHOUFA_DATA / $XDG_DATA_HOME)
        \\# applies. Uncomment to pin a location:
        \\# data_dir = {s}
        \\
        \\# In-memory cache budget with LRU eviction. Every value is also on disk.
        \\max_memory_bytes = {d}
        \\max_request_bytes = {d}
        \\sweep_interval_ms = {d}
        \\
    , .{
        DEFAULT_PORT,
        DEFAULT_DATA_DIR,
        DEFAULT_MAX_MEMORY,
        DEFAULT_MAX_REQUEST_BYTES,
        DEFAULT_SWEEP_INTERVAL_MS,
    });
    return out.toOwnedSlice();
}

fn writeDefaultConfig(io: std.Io, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = text,
        .flags = .{
            .permissions = @fromBackingInt(@intCast(0o600)),
            .exclusive = true,
        },
    });

    std.log.info("created config file: {s}", .{path});
}

fn parse(arena: std.mem.Allocator, path: []const u8, text: []const u8) LoadError!Config {
    var cfg: Config = .{ .path = path };

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
        } else if (std.ascii.eqlIgnoreCase(key, "data_dir") or std.ascii.eqlIgnoreCase(key, "data")) {
            if (value.len == 0) return error.InvalidNumber;
            cfg.data_dir = try arena.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "max_memory") or std.ascii.eqlIgnoreCase(key, "maxmemory")) {
            cfg.max_memory_bytes = parseSize(value) catch return error.InvalidNumber;
        } else if (std.ascii.eqlIgnoreCase(key, "max_memory_bytes")) {
            cfg.max_memory_bytes = std.fmt.parseInt(usize, value, 10) catch return error.InvalidNumber;
        } else if (std.ascii.eqlIgnoreCase(key, "max_request_bytes")) {
            cfg.max_request_bytes = parseSize(value) catch return error.InvalidNumber;
        } else if (std.ascii.eqlIgnoreCase(key, "sweep_interval_ms")) {
            cfg.sweep_interval_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidNumber;
        }
    }

    if (cfg.max_memory_bytes == 0) cfg.max_memory_bytes = DEFAULT_MAX_MEMORY;
    if (cfg.max_memory_bytes > MAX_MEMORY_CAP) return error.MaxMemoryTooLarge;
    if (cfg.max_request_bytes == 0) cfg.max_request_bytes = DEFAULT_MAX_REQUEST_BYTES;
    if (cfg.sweep_interval_ms == 0) cfg.sweep_interval_ms = DEFAULT_SWEEP_INTERVAL_MS;
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

fn parseSize(value: []const u8) !usize {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return error.InvalidNumber;

    var digits_end: usize = 0;
    while (digits_end < trimmed.len and (std.ascii.isDigit(trimmed[digits_end]) or trimmed[digits_end] == '.')) : (digits_end += 1) {}
    if (digits_end == 0) return error.InvalidNumber;

    const number_part = trimmed[0..digits_end];
    const suffix = std.mem.trim(u8, trimmed[digits_end..], " \t");

    var multiplier: usize = 1;
    if (suffix.len == 0 or std.ascii.eqlIgnoreCase(suffix, "b")) {
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
