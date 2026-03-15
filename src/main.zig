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
    // @enumFromInt(3) = page alignment (2^3 = 8 bytes) for ELF file reading
    const elf_data = cwd.readFileAllocOptions(io, args[1], arena, .unlimited, @enumFromInt(3), null) catch |err| {
        std.debug.print("failed to read ELF file: {}\n", .{err});
        return;
    };

    const machine = riscv.Machine.init(elf_data, .{}) catch |err| {
        std.debug.print("failed to initialize machine: {}\n", .{err});
        return;
    };
    defer machine.deinit();

    machine.run(0) catch |err| {
        std.debug.print("execution error: {}\n", .{err});
        return;
    };

    std.debug.print("exit code: {}\n", .{machine.returnValue()});
    std.debug.print("instructions: {}\n", .{machine.instructionCounter()});
}
