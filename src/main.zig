const std = @import("std");
const riscv = @import("zigriscv");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("usage: zigriscv <elf-binary>\n", .{});
        return;
    }

    const cwd: std.Io.Dir = .cwd();
    const elf_data = try cwd.readFileAllocOptions(io, args[1], arena, .unlimited, @enumFromInt(3), null);

    const machine = try riscv.Machine.init(elf_data, .{});
    defer machine.deinit();

    machine.run(0) catch |err| {
        std.debug.print("execution error: {}\n", .{err});
        return;
    };

    std.debug.print("exit code: {}\n", .{machine.returnValue()});
    std.debug.print("instructions: {}\n", .{machine.instructionCounter()});
}
