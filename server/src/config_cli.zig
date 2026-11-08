//! `shoufad config` — create or upgrade a config file in the working
//! directory.
//!
//!     shoufad config            create ./config with default values
//!     shoufad config --upgrade  rewrite ./config in the current format,
//!                               keeping the values it already had
//!
//! The file is plain `key = value` text. Upgrading normalises key names and
//! value spellings (for example `max_memory = 5GB` becomes
//! `max_memory_bytes = 5000000000`), adds the keys a current build expects,
//! and reports anything it could not carry over.

const std = @import("std");
const config = @import("config.zig");

const default_path = "config";
const max_config_bytes: usize = 1024 * 1024;

/// Keys older shoufad builds read but the current one does not. They are
/// reported on upgrade and never copied into the new file.
const retired_keys = [_][]const u8{ "api_key", "token", "allow_anonymous" };

const Options = struct {
    upgrade: bool = false,
    help: bool = false,
    path: []const u8 = default_path,
};

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const options = try parseOptions(init.io, args);
    if (options.help) {
        try printUsage(init.io);
        return;
    }

    if (options.upgrade) {
        try upgrade(init, options);
    } else {
        try create(init, options);
    }
}

fn parseOptions(io: std.Io, args: []const []const u8) !Options {
    var options: Options = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--upgrade")) {
            options.upgrade = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "--path")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) {
                std.log.err("missing path after {s}", .{arg});
                std.process.exit(1);
            }
            options.path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            options.path = arg["--config=".len..];
            if (options.path.len == 0) return failEmptyPath();
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            options.path = arg["--path=".len..];
            if (options.path.len == 0) return failEmptyPath();
        } else {
            std.log.err("unknown config option: {s}", .{arg});
            try printUsage(io);
            std.process.exit(1);
        }
    }

    return options;
}

fn failEmptyPath() Options {
    std.log.err("missing path for --config/--path", .{});
    std.process.exit(1);
}

fn create(init: std.process.Init, options: Options) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    if (exists(io, options.path)) {
        std.log.err("{s} already exists; delete it to start over, or run `shoufad config --upgrade` to migrate it", .{options.path});
        std.process.exit(1);
    }

    const text = try config.generate(arena);
    try writeNew(io, options.path, text);

    std.log.info("created {s}", .{options.path});

    var hint_buffer: [512]u8 = undefined;
    const hint = try std.fmt.bufPrint(&hint_buffer,
        \\Next steps:
        \\  run with:   shoufad --config {s}
        \\  migrate:    shoufad config --upgrade
        \\
    , .{options.path});
    try std.Io.File.stdout().writeStreamingAll(io, hint);
}

fn upgrade(init: std.process.Init, options: Options) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const text = std.Io.Dir.cwd().readFileAlloc(io, options.path, arena, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("no config found at {s}; run `shoufad config` to create one", .{options.path});
            std.process.exit(1);
        },
        else => return err,
    };

    const report = config.parseWithReport(arena, options.path, text) catch |err| switch (err) {
        error.MaxMemoryTooLarge => {
            std.log.err("{s}: max_memory_bytes is above the {d} byte cap", .{ options.path, config.MAX_MEMORY_CAP });
            std.process.exit(1);
        },
        error.InvalidPort => {
            std.log.err("{s}: invalid port", .{options.path});
            std.process.exit(1);
        },
        error.InvalidNumber => {
            std.log.err("{s}: invalid value", .{options.path});
            std.process.exit(1);
        },
        else => return err,
    };

    if (!looksLikeShoufaConfig(text, report)) {
        std.log.err("{s} does not look like a shoufa config; refusing to overwrite it", .{options.path});
        std.process.exit(1);
    }

    const rendered = try config.render(arena, .{ .cfg = report.cfg });

    // Refuse to write anything that would not read back to the same values.
    const roundtrip = config.parseWithReport(arena, options.path, rendered) catch |err| {
        std.log.err("{s}: could not verify the upgraded config: {t}", .{ options.path, err });
        std.process.exit(1);
    };
    if (!sameValues(report.cfg, roundtrip.cfg)) {
        std.log.err("{s}: upgraded config would not read back to the same values; leaving the file untouched", .{options.path});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, text, rendered)) {
        std.log.info("{s} is already in the current format", .{options.path});
        return;
    }

    const backup_path = try std.fmt.allocPrint(arena, "{s}.bak", .{options.path});
    try writeOver(io, backup_path, text);
    try writeOver(io, options.path, rendered);

    std.log.info("upgraded {s} (previous copy: {s})", .{ options.path, backup_path });
    try printSummary(io, arena, report);
}

fn looksLikeShoufaConfig(text: []const u8, report: config.Report) bool {
    // A key shoufad understands, or a key an older build understood.
    if (report.present.any()) return true;
    for (report.unknown) |key| {
        for (retired_keys) |retired| {
            if (std.ascii.eqlIgnoreCase(key, retired)) return true;
        }
    }
    // Otherwise fall back to the header shoufad writes.
    for ([_][]const u8{ "Shoufa", "shoufa", "SHOUFA" }) |needle| {
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

fn sameValues(a: config.Config, b: config.Config) bool {
    return std.mem.eql(u8, a.bind, b.bind) and
        a.port == b.port and
        std.mem.eql(u8, a.data_dir, b.data_dir) and
        a.max_memory_bytes == b.max_memory_bytes and
        a.max_request_bytes == b.max_request_bytes and
        a.sweep_interval_ms == b.sweep_interval_ms;
}

fn printSummary(io: std.Io, arena: std.mem.Allocator, report: config.Report) !void {
    const kept = try keyList(arena, report, true);
    const defaults = try keyList(arena, report, false);

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("  kept:      ");
    try out.writer.writeAll(kept);
    try out.writer.writeAll("\n  defaults:  ");
    try out.writer.writeAll(defaults);

    if (report.unknown.len > 0) {
        var dropped: std.ArrayList([]const u8) = .empty;
        var ignored: std.ArrayList([]const u8) = .empty;
        defer dropped.deinit(arena);
        defer ignored.deinit(arena);

        for (report.unknown) |key| {
            const retired = blk: {
                for (retired_keys) |candidate| {
                    if (std.ascii.eqlIgnoreCase(key, candidate)) break :blk true;
                }
                break :blk false;
            };
            if (retired) {
                try dropped.append(arena, key);
            } else {
                try ignored.append(arena, key);
            }
        }

        if (dropped.items.len > 0) {
            try out.writer.writeAll("\n  dropped:   ");
            try out.writer.writeAll(try join(arena, dropped.items));
            try out.writer.writeAll(" (removed; shoufad no longer reads them)");
        }
        if (ignored.items.len > 0) {
            try out.writer.writeAll("\n  ignored:   ");
            try out.writer.writeAll(try join(arena, ignored.items));
            try out.writer.writeAll(" (not a shoufa key)");
        }
    }

    try out.writer.writeAll("\n");
    try std.Io.File.stdout().writeStreamingAll(io, try out.toOwnedSlice());
}

/// Renders `name=value` for every key, using the parsed config: keys the file
/// set keep their value, keys it did not carry the parse defaults.
fn keyList(arena: std.mem.Allocator, report: config.Report, want_present: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var first = true;

    inline for (@typeInfo(config.Present).@"struct".field_names) |field_name| {
        if (@field(report.present, field_name) == want_present) {
            if (!first) try out.writer.writeAll(", ");
            first = false;
            try out.writer.print("{s}={s}", .{ field_name, try formatValue(arena, report.cfg, field_name) });
        }
    }

    if (first) try out.writer.writeAll("(none)");
    return out.toOwnedSlice();
}

fn formatValue(arena: std.mem.Allocator, cfg: config.Config, comptime key: []const u8) ![]const u8 {
    if (std.mem.eql(u8, key, "bind")) return try arena.dupe(u8, cfg.bind);
    if (std.mem.eql(u8, key, "data_dir")) {
        if (cfg.data_dir.len == 0) return try std.fmt.allocPrint(arena, "{s} (default)", .{config.DEFAULT_DATA_DIR});
        return try arena.dupe(u8, cfg.data_dir);
    }
    if (std.mem.eql(u8, key, "port")) return try std.fmt.allocPrint(arena, "{d}", .{cfg.port});
    if (std.mem.eql(u8, key, "max_memory")) return try std.fmt.allocPrint(arena, "{d}", .{cfg.max_memory_bytes});
    if (std.mem.eql(u8, key, "max_request_bytes")) return try std.fmt.allocPrint(arena, "{d}", .{cfg.max_request_bytes});
    if (std.mem.eql(u8, key, "sweep_interval_ms")) return try std.fmt.allocPrint(arena, "{d}", .{cfg.sweep_interval_ms});
    return "";
}

fn join(arena: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (items, 0..) |item, index| {
        if (index > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(item);
    }
    return out.toOwnedSlice();
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn writeNew(io: std.Io, path: []const u8, text: []const u8) !void {
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
}

fn writeOver(io: std.Io, path: []const u8, text: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = text,
        .flags = .{
            .permissions = @fromBackingInt(@intCast(0o600)),
            .truncate = true,
        },
    });
}

pub fn printUsage(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        \\Usage:
        \\  shoufad config              Create ./config with default values
        \\  shoufad config --upgrade    Rewrite ./config in the current format,
        \\                              keeping the values it already had
        \\
        \\Options:
        \\  --config PATH, --path PATH  File to create or upgrade (default ./config)
        \\  -h, --help                  Show this help
        \\
        \\An upgrade copies the original to <path>.bak first and reports keys it
        \\could not carry over. The file is refused if it does not look like a
        \\shoufa config.
        \\
    );
}
