const std = @import("std");

const core_sources: []const []const u8 = &.{
    "libriscv/cpu.cpp",
    "libriscv/debug.cpp",
    "libriscv/decode_bytecodes.cpp",
    "libriscv/decoder_cache.cpp",
    "libriscv/machine.cpp",
    "libriscv/machine_defaults.cpp",
    "libriscv/memory.cpp",
    "libriscv/memory_elf.cpp",
    "libriscv/memory_mmap.cpp",
    "libriscv/memory_rw.cpp",
    "libriscv/native_libc.cpp",
    "libriscv/native_threads.cpp",
    "libriscv/posix/minimal.cpp",
    "libriscv/posix/signals.cpp",
    "libriscv/posix/threads.cpp",
    "libriscv/posix/socket_calls.cpp",
    "libriscv/serialize.cpp",
    "libriscv/util/crc32c.cpp",
    "libriscv/rv64i.cpp",
    "libriscv/bytecode_dispatch.cpp",
    "libriscv/linux/system_calls.cpp",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libriscv_dep = b.dependency("libriscv", .{});

    const libriscv_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    libriscv_mod.addCSourceFiles(.{
        .root = libriscv_dep.path("lib/"),
        .files = core_sources,
        .flags = &.{
            "-std=c++20",
            "-Wall",
            "-Wextra",
        },
    });

    // C API wrapper (handles macOS stdout macro clash)
    libriscv_mod.addCSourceFiles(.{
        .root = b.path("."),
        .files = &.{"libriscv_capi.cpp"},
        .flags = &.{
            "-std=c++20",
        },
    });

    libriscv_mod.addIncludePath(libriscv_dep.path("lib/"));
    libriscv_mod.addIncludePath(b.path(".")); // libriscv_settings.h
    libriscv_mod.addIncludePath(libriscv_dep.path("c")); // libriscv.h
    libriscv_mod.linkSystemLibrary("c++", .{});
    if (target.result.os.tag == .macos) {
        libriscv_mod.linkFramework("Security", .{});
        libriscv_mod.linkFramework("Foundation", .{});
    }

    const libriscv = b.addLibrary(.{
        .name = "riscv",
        .root_module = libriscv_mod,
        .linkage = .static,
    });

    const mod = b.addModule("zigriscv", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addIncludePath(libriscv_dep.path("c"));
    mod.linkLibrary(libriscv);

    const exe = b.addExecutable(.{
        .name = "zigriscv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigriscv", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const host_test = b.addExecutable(.{
        .name = "host_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_programs/host_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigriscv", .module = mod },
            },
        }),
    });
    b.installArtifact(host_test);

    const sandbox_test = b.addExecutable(.{
        .name = "sandbox_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_programs/sandbox_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigriscv", .module = mod },
            },
        }),
    });
    b.installArtifact(sandbox_test);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
