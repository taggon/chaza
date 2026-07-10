const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── chaza library module (public) ──
    const mod = b.addModule("chaza", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // ── runtime wasm: wasm32-freestanding, ReleaseSmall ──
    // Since export_symbol_names is configured, export symbols are preserved
    // during ReleaseSmall's lazy DCE (otherwise they disappear with -fno-entry).
    const runtime_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = runtime_target,
        .optimize = .ReleaseSmall,
    });
    runtime_mod.export_symbol_names = &.{ "alloc", "set_index", "search" };
    const runtime_exe = b.addExecutable(.{
        .name = "runtime",
        .root_module = runtime_mod,
    });
    runtime_exe.entry = .disabled;

    // Install runtime.wasm to zig-out/runtime.wasm
    const install_runtime = b.addInstallArtifact(runtime_exe, .{
        .dest_dir = .{ .override = .prefix },
    });
    b.getInstallStep().dependOn(&install_runtime.step);

    // ── chaza CLI executable ──
    // Create embed module to inject runtime.wasm and chaza.js via @embedFile.
    // WriteFile step copies files to cache directory, then designates that
    // directory as anonymous module root. main.zig accesses via @import("chaza_embeds").
    const embed_files = b.addWriteFiles();
    _ = embed_files.add("embeds.zig",
        \\pub const runtime_wasm: []const u8 = @embedFile("runtime.wasm");
        \\pub const loader_js: []const u8 = @embedFile("chaza.js");
        \\pub const default_stopwords: []const u8 = @embedFile("stopwords.txt");
    );
    _ = embed_files.addCopyFile(runtime_exe.getEmittedBin(), "runtime.wasm");
    _ = embed_files.addCopyFile(b.path("npm/chaza/dist/chaza.js"), "chaza.js");
    _ = embed_files.addCopyFile(b.path("stopwords.txt"), "stopwords.txt");

    const embeds_mod = b.createModule(.{
        .root_source_file = embed_files.getDirectory().path(b, "embeds.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "chaza",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "chaza", .module = mod },
                .{ .name = "chaza_embeds", .module = embeds_mod },
            },
        }),
    });
    exe.step.dependOn(&runtime_exe.step);
    b.installArtifact(exe);

    // ── run step ──
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ── test step ──
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // -- coverage step --
    const coverage_step = b.step("coverage", "Generate test coverage report");

    const kcov = b.addSystemCommand(&.{
        "kcov",
        "--include-pattern=/src/",
    });
    const cov_out = kcov.addOutputDirectoryArg("coverage");
    kcov.addArtifactArg(mod_tests);

    coverage_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = cov_out,
        .install_dir = .prefix,
        .install_subdir = "coverage",
    }).step);
}
