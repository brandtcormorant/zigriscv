const std = @import("std");
const riscv = @import("zigriscv");

/// The script the host wants to evaluate in the sandbox.
var g_script: []const u8 = "";

/// Buffer to capture the result from the guest.
var g_result: [64 * 1024]u8 = undefined;
var g_result_len: usize = 0;

/// Buffer to capture errors from the guest.
var g_error: [4096]u8 = undefined;
var g_error_len: usize = 0;

/// Syscall 500: get_script(buf_ptr, buf_cap) -> script_len
/// Host writes the script into guest memory.
fn handleGetScript(m: riscv.Machine) void {
    const buf_ptr = m.getReg(10);
    const buf_cap = m.getReg(11);
    const script = g_script;

    if (script.len == 0 or script.len > buf_cap) {
        m.setResult(0);
        return;
    }

    m.copyToGuest(buf_ptr, script) catch {
        m.setResult(0);
        return;
    };
    m.setResult(@intCast(script.len));
}

/// Syscall 501: put_result(ptr, len) -> 0
/// Host reads the result string from guest memory.
fn handlePutResult(m: riscv.Machine) void {
    const ptr = m.getReg(10);
    const len = m.getReg(11);

    if (len > g_result.len) {
        m.setResult(@as(i64, -1));
        return;
    }

    const view = m.memview(ptr, @intCast(len)) catch {
        m.setResult(@as(i64, -1));
        return;
    };
    @memcpy(g_result[0..view.len], view);
    g_result_len = view.len;
    m.setResult(0);
}

/// Syscall 502: put_error(ptr, len) -> 0
fn handlePutError(m: riscv.Machine) void {
    const ptr = m.getReg(10);
    const len = m.getReg(11);

    if (len > g_error.len) {
        m.setResult(@as(i64, -1));
        return;
    }

    const view = m.memview(ptr, @intCast(len)) catch {
        m.setResult(@as(i64, -1));
        return;
    };
    @memcpy(g_error[0..view.len], view);
    g_error_len = view.len;
    m.setResult(0);
}

fn eval(elf_data: []const u8, script: []const u8) ![]const u8 {
    g_script = script;
    g_result_len = 0;
    g_error_len = 0;

    const machine = riscv.Machine.init(elf_data, .{
        .max_memory = 64 * 1024 * 1024,
    }) catch return error.MachineInit;
    defer machine.deinit();

    machine.run(0) catch return error.RunFailed;

    const exit_code = machine.returnValue();

    if (g_error_len > 0) {
        std.debug.print("guest error: {s}\n", .{g_error[0..g_error_len]});
        return error.GuestError;
    }

    if (exit_code != 0) {
        std.debug.print("guest exit code: {} (no error message)\n", .{exit_code});
        return error.GuestExitNonZero;
    }

    return g_result[0..g_result_len];
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("usage: sandbox_test <lil-sandbox.elf>\n", .{});
        return;
    }

    // Register syscall handlers BEFORE creating any machines
    try riscv.setSyscallHandler(500, &handleGetScript);
    try riscv.setSyscallHandler(501, &handlePutResult);
    try riscv.setSyscallHandler(502, &handlePutError);

    const cwd: std.Io.Dir = .cwd();
    const elf_data = cwd.readFileAllocOptions(io, args[1], arena, .unlimited, @enumFromInt(3), null) catch |err| {
        std.debug.print("failed to read ELF: {}\n", .{err});
        return;
    };

    // Test 1: basic arithmetic
    const r1 = eval(elf_data, "1 + 2") catch |err| {
        std.debug.print("test 1 failed: {}\n", .{err});
        return;
    };
    std.debug.print("eval(\"1 + 2\") = \"{s}\"\n", .{r1});

    // Test 2: string
    const r2 = eval(elf_data, "\"hello sandbox\"") catch |err| {
        std.debug.print("test 2 failed: {}\n", .{err});
        return;
    };
    std.debug.print("eval('\"hello sandbox\"') = \"{s}\"\n", .{r2});

    // Test 3: variable + expression
    const r3 = eval(elf_data, "let x = 10\nx * 4 + 2") catch |err| {
        std.debug.print("test 3 failed: {}\n", .{err});
        return;
    };
    std.debug.print("eval(\"let x = 10\\nx * 4 + 2\") = \"{s}\"\n", .{r3});

    // Test 4: function definition and call
    const r4 = eval(elf_data, "let double = fn(n) { n * 2 }\ndouble(21)") catch |err| {
        std.debug.print("test 4 failed: {}\n", .{err});
        return;
    };
    std.debug.print("eval(double(21)) = \"{s}\"\n", .{r4});

    std.debug.print("all tests passed!\n", .{});
}
