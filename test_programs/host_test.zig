const std = @import("std");
const riscv = @import("zigriscv");

/// Syscall 500 handler: reads a0 and a1, sets a0 = a0 + a1.
fn handleAdd(m: riscv.Machine) void {
    const a0: i64 = @bitCast(m.getReg(10));
    const a1: i64 = @bitCast(m.getReg(11));
    m.setResult(a0 + a1);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("usage: host_test <elf-binary>\n", .{});
        return;
    }

    // Register syscall handler BEFORE creating machine
    try riscv.setSyscallHandler(500, &handleAdd);

    const cwd: std.Io.Dir = .cwd();
    const elf_data = cwd.readFileAllocOptions(io, args[1], arena, .unlimited, @enumFromInt(3), null) catch |err| {
        std.debug.print("failed to read ELF: {}\n", .{err});
        return;
    };

    const machine = riscv.Machine.init(elf_data, .{ .max_memory = 64 * 1024 * 1024 }) catch |err| {
        std.debug.print("failed to init machine: {}\n", .{err});
        return;
    };
    defer machine.deinit();

    // Run main() -- guest triggers syscall 500 with (17, 25), expects 42
    std.debug.print("--- running main ---\n", .{});
    machine.run(0) catch |err| {
        std.debug.print("run error: {}\n", .{err});
        return;
    };
    std.debug.print("exit code: {}\n", .{machine.returnValue()});

    // Vmcall to the exported triple() function
    const triple_addr = machine.addressOf("triple") orelse {
        std.debug.print("symbol 'triple' not found\n", .{});
        return;
    };
    std.debug.print("--- vmcall triple(7) ---\n", .{});
    try machine.setupVmcall(triple_addr);
    machine.setReg(10, @bitCast(@as(i64, 7))); // a0 = 7
    machine.run(0) catch |err| {
        std.debug.print("vmcall error: {}\n", .{err});
        return;
    };
    const result: i64 = @bitCast(machine.getReg(10));
    std.debug.print("triple(7) = {}\n", .{result});

    if (result == 21) {
        std.debug.print("vmcall ok\n", .{});
    } else {
        std.debug.print("vmcall FAILED (expected 21, got {})\n", .{result});
    }
}
