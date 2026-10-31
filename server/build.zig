const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "shoufad",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

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
}
