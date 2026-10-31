//! `shoufad service-install` — install/update a systemd unit on Linux.
//!
//! Runs as a system service when executed as root, and as a per-user service
//! otherwise. Both modes copy the running binary, provision a config with a
//! config, write the unit, and enable/start it.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

const Scope = enum { system, user };

const RawOptions = struct {
    scope: ?Scope = null,
    binary: ?[]const u8 = null,
    config: ?[]const u8 = null,
    service_name: ?[]const u8 = null,
    user: ?[]const u8 = null,
    no_start: bool = false,
    force: bool = false,
    dry_run: bool = false,
    help: bool = false,
};

const Options = struct {
    scope: Scope,
    binary: []const u8,
    config: []const u8,
    unit_dir: []const u8,
    service_name: []const u8,
    /// Service account for system scope; current user for user scope.
    user: []const u8,
    no_start: bool = false,
    force: bool = false,
    dry_run: bool = false,
};

pub fn install(init: std.process.Init, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const gpa = init.gpa;

    const raw = try parseOptions(args);
    if (raw.help) {
        try printUsage(io);
        return;
    }

    if (builtin.os.tag != .linux) {
        std.log.err("service-install is only supported on Linux", .{});
        return error.UnsupportedPlatform;
    }

    const options = try resolveOptions(init, raw);
    try validateOptions(&options);

    const unit_name = try std.fmt.allocPrint(arena, "{s}.service", .{options.service_name});
    const unit_path = try std.fs.path.join(arena, &.{ options.unit_dir, unit_name });
    const unit = try buildUnit(arena, &options);

    if (options.dry_run) {
        const exe_path = try std.process.executablePathAlloc(io, arena);
        try printPlan(io, arena, &options, exe_path, unit_name, unit_path, unit);
        return;
    }

    if (options.scope == .system and !isRoot()) {
        std.log.err("--scope system requires root (try: sudo shoufad service-install)", .{});
        return error.NotRoot;
    }

    try ensureSystemd(io);

    if (options.scope == .user) {
        if (init.environ_map.get("XDG_RUNTIME_DIR") == null) {
            std.log.err("XDG_RUNTIME_DIR is not set; a systemd user manager is not available", .{});
            return error.UserSystemdUnavailable;
        }
    } else {
        try ensureSystemUser(io, gpa, &options);
    }

    const exe_path = try std.process.executablePathAlloc(io, arena);
    try installBinary(io, &options, exe_path);
    const created_config = try installConfig(io, gpa, arena, &options);

    try writeFile(io, unit_path, unit, 0o644);
    std.log.info("wrote systemd unit: {s}", .{unit_path});

    try runSystemctl(io, gpa, options.scope, "daemon-reload", null);
    try runSystemctl(io, gpa, options.scope, "enable", unit_name);
    if (options.no_start) {
        const start_hint = try std.fmt.allocPrint(arena, "{s} start {s}", .{
            systemctlPrefix(options.scope), unit_name,
        });
        std.log.info("service enabled; start it with: {s}", .{start_hint});
    } else {
        try runSystemctl(io, gpa, options.scope, "restart", unit_name);
        std.log.info("service started: {s}", .{unit_name});
    }

    if (options.scope == .user) {
        enableLinger(io, gpa, options.user);
    }

    // Summary.
    std.log.info("scope: {s}", .{scopeLabel(options.scope)});
    std.log.info("binary: {s}", .{options.binary});
    std.log.info("config: {s}", .{options.config});
    std.log.info("config state: {s}", .{if (created_config) "created" else "kept existing"});
    std.log.info("frontend: served from the embedded web assets", .{});
    const status_hint = try std.fmt.allocPrint(arena, "{s} status {s}", .{
        systemctlPrefix(options.scope), unit_name,
    });
    std.log.info("check status with: {s}", .{status_hint});
}

fn resolveOptions(init: std.process.Init, raw: RawOptions) !Options {
    const arena = init.arena.allocator();
    const scope: Scope = raw.scope orelse if (isRoot()) Scope.system else Scope.user;

    var options: Options = .{
        .scope = scope,
        .binary = undefined,
        .config = undefined,
        .unit_dir = undefined,
        .service_name = raw.service_name orelse "shoufad",
        .user = undefined,
        .no_start = raw.no_start,
        .force = raw.force,
        .dry_run = raw.dry_run,
    };

    switch (scope) {
        .system => {
            options.binary = raw.binary orelse "/usr/local/bin/shoufad";
            options.config = raw.config orelse "/etc/shoufad/config";
            options.unit_dir = "/etc/systemd/system";
            options.user = raw.user orelse "shoufad";
        },
        .user => {
            if (raw.user != null) {
                std.log.err("--user NAME is only valid with --scope system", .{});
                return error.InvalidArgument;
            }
            const home = init.environ_map.get("HOME") orelse {
                std.log.err("HOME is not set; cannot determine user install paths", .{});
                return error.HomeNotSet;
            };
            const config_home = init.environ_map.get("XDG_CONFIG_HOME") orelse
                try std.fs.path.join(arena, &.{ home, ".config" });

            options.binary = raw.binary orelse
                try std.fs.path.join(arena, &.{ home, ".local", "bin", "shoufad" });
            options.config = raw.config orelse
                try std.fs.path.join(arena, &.{ config_home, "shoufad", "config" });
            options.unit_dir = try std.fs.path.join(arena, &.{ config_home, "systemd", "user" });
            options.user = try currentUserName(init, arena);
        },
    }

    return options;
}

fn currentUserName(init: std.process.Init, arena: std.mem.Allocator) ![]const u8 {
    if (init.environ_map.get("USER")) |user| {
        if (user.len > 0) return try arena.dupe(u8, user);
    }

    const result = std.process.run(init.gpa, init.io, .{
        .argv = &.{ "id", "-un" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return error.UserNameUnknown;
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (!result.term.success()) return error.UserNameUnknown;

    return try arena.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

fn parseOptions(args: []const []const u8) !RawOptions {
    var options: RawOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--no-start")) {
            options.no_start = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--scope")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.scope = try parseScope(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--scope=")) {
            options.scope = try parseScope(arg["--scope=".len..]);
        } else if (std.mem.eql(u8, arg, "--binary") or std.mem.eql(u8, arg, "--bin")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.binary = args[i];
        } else if (std.mem.startsWith(u8, arg, "--binary=")) {
            options.binary = arg["--binary=".len..];
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.config = args[i];
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            options.config = arg["--config=".len..];
        } else if (std.mem.eql(u8, arg, "--service") or std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.service_name = args[i];
        } else if (std.mem.startsWith(u8, arg, "--service=")) {
            options.service_name = arg["--service=".len..];
        } else if (std.mem.eql(u8, arg, "--user")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.user = args[i];
        } else if (std.mem.startsWith(u8, arg, "--user=")) {
            options.user = arg["--user=".len..];
        } else {
            std.log.err("unknown option: {s}", .{arg});
            return error.UnknownOption;
        }
    }
    return options;
}

fn parseScope(value: []const u8) !Scope {
    if (std.mem.eql(u8, value, "system")) return .system;
    if (std.mem.eql(u8, value, "user")) return .user;
    std.log.err("invalid --scope value (use 'system' or 'user'): {s}", .{value});
    return error.InvalidArgument;
}

fn validateOptions(options: *const Options) !void {
    try validateAbsolutePath(options.binary, "--binary");
    try validateAbsolutePath(options.config, "--config");
    try validateAbsolutePath(options.unit_dir, "--unit-dir");

    if (options.service_name.len == 0) return error.InvalidArgument;
    for (options.service_name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) {
            std.log.err("invalid service name (use letters, digits, '-', '_', '.'): {s}", .{options.service_name});
            return error.InvalidArgument;
        }
    }

    if (options.scope == .system) {
        if (options.user.len == 0 or std.mem.indexOfAny(u8, options.user, " \t\n:/") != null) {
            std.log.err("invalid user name: {s}", .{options.user});
            return error.InvalidArgument;
        }
    }
}

fn validateAbsolutePath(path: []const u8, label: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        std.log.err("{s} must be an absolute path: {s}", .{ label, path });
        return error.InvalidArgument;
    }
    for (path) |c| {
        if (c == '"' or c == '\n' or c == '\r') {
            std.log.err("{s} contains characters that cannot be quoted in a systemd unit", .{label});
            return error.InvalidArgument;
        }
    }
}

fn ensureSystemd(io: std.Io) !void {
    std.Io.Dir.accessAbsolute(io, "/run/systemd/system", .{}) catch {
        std.log.err("systemd does not appear to be running (missing /run/systemd/system)", .{});
        return error.SystemdUnavailable;
    };
}

fn ensureSystemUser(io: std.Io, gpa: std.mem.Allocator, options: *const Options) !void {
    if (std.mem.eql(u8, options.user, "root")) return;
    if (userExists(io, gpa, options.user)) return;

    std.log.info("creating system user: {s}", .{options.user});
    const argv = [_][]const u8{
        "useradd",
        "--system",
        "--user-group",
        "--no-create-home",
        "--home-dir",
        "/nonexistent",
        "--shell",
        "/usr/sbin/nologin",
        options.user,
    };
    try runChecked(io, gpa, &argv);
}

fn installBinary(io: std.Io, options: *const Options, exe_path: []const u8) !void {
    if (std.mem.eql(u8, exe_path, options.binary)) return;

    if (std.fs.path.dirname(options.binary)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    std.log.info("installing binary: {s} -> {s}", .{ exe_path, options.binary });
    try std.Io.Dir.copyFileAbsolute(exe_path, options.binary, io, .{
        .permissions = @fromBackingInt(@intCast(0o755)),
        .replace = true,
    });
}

fn installConfig(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    options: *const Options,
) !bool {
    if (std.fs.path.dirname(options.config)) |dir| {
        if (dir.len > 0) {
            const dir_existed = existsAbsolute(io, dir);
            try std.Io.Dir.cwd().createDirPath(io, dir);
            // Only relax permissions on a directory we just created. Never
            // chmod pre-existing system directories such as /etc.
            if (options.scope == .system and !dir_existed and !std.mem.eql(u8, dir, "/")) {
                try runChmod(io, gpa, dir, 0o755);
            }
        }
    }

    const config_exists = existsAbsolute(io, options.config);
    var created_config = false;
    if (!config_exists or options.force) {
        if (config_exists) {
            std.log.warn("overwriting existing config (--force)", .{});
        }
        const generated = try config.generate(arena);
        try writeFile(io, options.config, generated, 0o600);
        created_config = true;
        std.log.info("created config: {s}", .{options.config});
    } else {
        std.log.info("keeping existing config: {s}", .{options.config});
    }

    if (options.scope == .system) {
        const owner = try std.fmt.allocPrint(arena, "{s}:", .{options.user});
        const chown_argv = [_][]const u8{ "chown", owner, options.config };
        try runChecked(io, gpa, &chown_argv);
    }
    try runChmod(io, gpa, options.config, 0o600);
    return created_config;
}

fn buildUnit(arena: std.mem.Allocator, options: *const Options) ![]const u8 {
    return switch (options.scope) {
        .system => std.fmt.allocPrint(arena,
            \\# Managed by `shoufad service-install`. Re-run that command to update.
            \\[Unit]
            \\Description=Shoufa self-hosted server
            \\After=network-online.target
            \\Wants=network-online.target
            \\
            \\[Service]
            \\Type=simple
            \\User={s}
            \\ExecStart="{s}" --config "{s}"
            \\Restart=always
            \\RestartSec=2
            \\LimitNOFILE=65536
            \\NoNewPrivileges=true
            \\PrivateTmp=true
            \\ProtectHome=true
            \\ProtectSystem=strict
            \\RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
            \\
            \\[Install]
            \\WantedBy=multi-user.target
            \\
        , .{ options.user, options.binary, options.config }),
        .user => std.fmt.allocPrint(arena,
            \\# Managed by `shoufad service-install`. Re-run that command to update.
            \\[Unit]
            \\Description=Shoufa self-hosted server (user)
            \\After=network-online.target
            \\Wants=network-online.target
            \\
            \\[Service]
            \\Type=simple
            \\ExecStart="{s}" --config "{s}"
            \\Restart=always
            \\RestartSec=2
            \\LimitNOFILE=65536
            \\NoNewPrivileges=true
            \\PrivateTmp=true
            \\RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
            \\
            \\[Install]
            \\WantedBy=default.target
            \\
        , .{ options.binary, options.config }),
    };
}

fn printPlan(
    io: std.Io,
    arena: std.mem.Allocator,
    options: *const Options,
    exe_path: []const u8,
    unit_name: []const u8,
    unit_path: []const u8,
    unit: []const u8,
) !void {
    const config_action = if (existsAbsolute(io, options.config))
        "keep existing config"
    else
        "create config";
    const prefix = if (options.scope == .user) "systemctl --user" else "systemctl";
    const reload = try std.fmt.allocPrint(arena, "{s} daemon-reload", .{prefix});
    const start_command = if (options.no_start)
        try std.fmt.allocPrint(arena, "{s} enable {s}", .{ prefix, unit_name })
    else
        try std.fmt.allocPrint(arena, "{s} enable {s} && {s} restart {s}", .{ prefix, unit_name, prefix, unit_name });
    const linger = if (options.scope == .user)
        try std.fmt.allocPrint(arena, "loginctl enable-linger {s}", .{options.user})
    else
        "";

    const plan = try std.fmt.allocPrint(arena,
        \\Service install plan (dry run):
        \\  scope:          {s}
        \\  current binary: {s}
        \\  install binary: {s}
        \\  config:         {s}
        \\  config action:  {s}
        \\  service user:   {s}
        \\  systemd unit:   {s}
        \\
        \\Commands:
        \\  {s}
        \\  {s}
        \\  {s}
        \\
        \\Unit file:
        \\{s}
        \\
    , .{
        scopeLabel(options.scope),
        exe_path,
        options.binary,
        options.config,
        config_action,
        options.user,
        unit_path,
        reload,
        start_command,
        linger,
        unit,
    });
    try std.Io.File.stdout().writeStreamingAll(io, plan);
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8, mode: u32) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
        .flags = .{
            .permissions = @fromBackingInt(@intCast(mode)),
            .truncate = true,
        },
    });
}

fn existsAbsolute(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn runChmod(io: std.Io, gpa: std.mem.Allocator, path: []const u8, mode: u32) !void {
    const mode_text = try std.fmt.allocPrint(gpa, "{o:0>4}", .{mode});
    defer gpa.free(mode_text);
    const argv = [_][]const u8{ "chmod", mode_text, path };
    try runChecked(io, gpa, &argv);
}

fn runSystemctl(io: std.Io, gpa: std.mem.Allocator, scope: Scope, action: []const u8, unit: ?[]const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    try argv.append(gpa, "systemctl");
    if (scope == .user) try argv.append(gpa, "--user");
    try argv.append(gpa, action);
    if (unit) |value| try argv.append(gpa, value);
    try runChecked(io, gpa, argv.items);
}

fn enableLinger(io: std.Io, gpa: std.mem.Allocator, user: []const u8) void {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "loginctl", "enable-linger", user },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch |err| {
        std.log.warn("could not enable linger for {s}: {t}", .{ user, err });
        std.log.warn("run `sudo loginctl enable-linger {s}` to start the service at boot", .{user});
        return;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) {
        std.log.warn("could not enable linger for {s}", .{user});
        std.log.warn("run `sudo loginctl enable-linger {s}` to start the service at boot", .{user});
        return;
    }
    std.log.info("linger enabled for {s}; user service will start at boot", .{user});
}

fn userExists(io: std.Io, gpa: std.mem.Allocator, user: []const u8) bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "id", "-u", user },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return result.term.success();
}

fn runChecked(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) !void {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        std.log.err("failed to run {s}: {t}", .{ argv[0], err });
        return err;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) {
        const detail = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (detail.len > 0) {
            std.log.err("{s} failed: {s}", .{ argv[0], detail });
        } else {
            std.log.err("{s} failed", .{argv[0]});
        }
        return error.CommandFailed;
    }
}

fn isRoot() bool {
    if (comptime builtin.os.tag == .linux) {
        return std.os.linux.geteuid() == 0;
    }
    return false;
}

fn scopeLabel(scope: Scope) []const u8 {
    return switch (scope) {
        .system => "system",
        .user => "user",
    };
}

fn systemctlPrefix(scope: Scope) []const u8 {
    return if (scope == .user) "systemctl --user" else "systemctl";
}

pub fn printUsage(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        \\Usage:
        \\  shoufad [--config PATH]
        \\  shoufad service-install [options]
        \\
        \\Commands:
        \\  (none)          Run the Shoufa server
        \\  service-install Install/update the systemd service (Linux only)
        \\
        \\service-install options:
        \\  --scope MODE    'system' (root) or 'user' (non-root)
        \\                  default: system for root, user otherwise
        \\  --binary PATH   default /usr/local/bin/shoufad (system)
        \\                  or ~/.local/bin/shoufad (user)
        \\  --config PATH   default /etc/shoufad/config (system)
        \\                  or ~/.config/shoufad/config (user)
        \\  --service NAME  systemd unit name (default shoufad)
        \\  --user NAME     Service user for --scope system (default shoufad)
        \\  --no-start      Enable at boot but do not start/restart now
        \\  --force         Overwrite an existing config
        \\  --dry-run, -n   Print the planned install without changing the system
        \\  -h, --help      Show this help
        \\
    );
}
