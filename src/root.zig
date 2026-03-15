const std = @import("std");
const c = @cImport({
    @cInclude("libriscv.h");
});

pub const Error = error{
    GeneralException,
    MachineException,
    MachineTimeout,
    NullMachine,
    MemoryAccessFailed,
};

/// Opaque handle to a RISC-V virtual machine.
pub const Machine = struct {
    handle: *c.RISCVMachine,

    /// Create a new 64-bit RISC-V machine from an ELF binary.
    /// The elf_data slice must outlive the Machine.
    pub fn init(elf_data: []const u8, options: Options) Error!Machine {
        var opts = options.toCOptions();
        const m = c.libriscv_new(
            elf_data.ptr,
            @intCast(elf_data.len),
            &opts,
        ) orelse return Error.NullMachine;
        return .{ .handle = m };
    }

    pub fn deinit(self: Machine) void {
        _ = c.libriscv_delete(self.handle);
    }

    /// Run the machine for up to instruction_limit instructions.
    /// Pass 0 for unlimited (runs until exit or error).
    pub fn run(self: Machine, instruction_limit: u64) Error!void {
        const ret = c.libriscv_run(self.handle, instruction_limit);
        try checkReturn(ret);
    }

    /// Return value from register a0 after execution.
    pub fn returnValue(self: Machine) i64 {
        return c.libriscv_return_value(self.handle);
    }

    /// Number of instructions executed.
    pub fn instructionCounter(self: Machine) u64 {
        return c.libriscv_instruction_counter(self.handle);
    }

    /// Read a zero-terminated string from guest memory.
    pub fn memstring(self: Machine, addr: u64, max_len: u32) Error![]const u8 {
        var length: c_uint = 0;
        const ptr = c.libriscv_memstring(self.handle, addr, max_len, &length) orelse
            return Error.MemoryAccessFailed;
        return ptr[0..length];
    }

    /// Copy bytes from guest memory into a host buffer.
    pub fn copyFromGuest(self: Machine, dst: []u8, src_addr: u64) Error!void {
        const ret = c.libriscv_copy_from_guest(self.handle, dst.ptr, src_addr, @intCast(dst.len));
        try checkReturn(ret);
    }

    /// Copy bytes from host into guest memory.
    pub fn copyToGuest(self: Machine, dst_addr: u64, src: []const u8) Error!void {
        const ret = c.libriscv_copy_to_guest(self.handle, dst_addr, src.ptr, @intCast(src.len));
        try checkReturn(ret);
    }

    /// Look up a symbol address by name. Returns null if not found.
    pub fn addressOf(self: Machine, name: [*:0]const u8) ?u64 {
        const addr = c.libriscv_address_of(self.handle, name);
        return if (addr == 0) null else addr;
    }

    fn checkReturn(ret: c_int) Error!void {
        switch (ret) {
            0 => {},
            c.RISCV_ERROR_TYPE_GENERAL_EXCEPTION => return Error.GeneralException,
            c.RISCV_ERROR_TYPE_MACHINE_EXCEPTION => return Error.MachineException,
            c.RISCV_ERROR_TYPE_MACHINE_TIMEOUT => return Error.MachineTimeout,
            else => return Error.GeneralException,
        }
    }
};

pub const Options = struct {
    max_memory: u64 = 8 * 1024 * 1024,
    stack_size: u32 = 256 * 1024,
    strict_sandbox: bool = true,

    fn toCOptions(self: Options) c.RISCVOptions {
        var opts: c.RISCVOptions = std.mem.zeroes(c.RISCVOptions);
        c.libriscv_set_defaults(&opts);
        opts.max_memory = self.max_memory;
        opts.stack_size = self.stack_size;
        opts.strict_sandbox = if (self.strict_sandbox) 1 else 0;
        return opts;
    }
};

test "libriscv linked" {
    var opts: c.RISCVOptions = undefined;
    c.libriscv_set_defaults(&opts);
    try std.testing.expect(opts.max_memory > 0);
}

test "exit42 integration" {
    const elf_data = @embedFile("../test_programs/exit42");
    const machine = try Machine.init(elf_data, .{});
    defer machine.deinit();
    try machine.run(0);
    try std.testing.expectEqual(@as(i64, 42), machine.returnValue());
}
