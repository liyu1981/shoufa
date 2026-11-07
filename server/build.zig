const std = @import("std");

/// Flags for the vendored SQLite amalgamation.
const sqlite_source = "vendor/sqlite/sqlite3.c";
const sqlite_include = "vendor/sqlite";
const sqlite_flags = [_][]const u8{
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_DEFAULT_MEMSTATUS=0",
    "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
    "-DSQLITE_DQS=0",
    "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_LOAD_EXTENSION",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "shoufad",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    addSqlite(exe.root_module, b);

    const gen_version = b.addSystemCommand(&.{ "node", "../scripts/generate-version.mjs" });
    const gen_web = b.addSystemCommand(&.{ "node", "../scripts/generate-web-assets.mjs" });
    exe.step.dependOn(&gen_version.step);
    exe.step.dependOn(&gen_web.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // Unit tests cover the object format, the SQLite metadata index, and the
    // LRU/disk fallback behaviour of the store.
    const tests = b.addTest(.{
        .name = "shoufad-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/store.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    addSqlite(tests.root_module, b);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run server unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Compile the vendored SQLite amalgamation into a module. This keeps release
/// builds self-contained and lets cross-compilation to musl work without a
/// system SQLite installation.
fn addSqlite(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path(sqlite_include));
    module.addCSourceFile(.{
        .file = b.path(sqlite_source),
        .flags = &sqlite_flags,
    });
}
