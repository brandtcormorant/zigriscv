const std = @import("std");
const c = @cImport({
    @cInclude("libriscv.h");
});

pub const protocol = @import("protocol.zig");
pub const GateProtocol = protocol.GateProtocol;
pub const Sandbox = protocol.Sandbox;

pub const Error = error{
    GeneralException,
    MachineException,
    MachineTimeout,
    NullMachine,
    MemoryAccessFailed,
};

pub const Registers = c.RISCVRegisters;

/// Syscall handler function type. Receives a Machine for register/memory access.
pub const SyscallHandler = *const fn (Machine) void;

/// Install a syscall handler for the given syscall number.
/// Handlers are global (shared by all machines) and must be registered
/// BEFORE creating machines. Numbers 500+ are safe for custom use.
/// The handler receives a Machine wrapper for reading/writing registers and memory.
pub fn setSyscallHandler(num: u32, comptime handler: SyscallHandler) Error!void {
    const Wrapper = struct {
        fn invoke(handle: ?*c.RISCVMachine) callconv(.c) void {
            handler(.{ .handle = handle.? });
        }
    };
    const ret = c.libriscv_set_syscall_handler(num, &Wrapper.invoke);
    try Machine.checkReturn(ret);
}

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

    /// Direct pointer to the live register file. Changes are immediate.
    /// RISC-V integer registers: r[0]=zero, r[1]=ra, r[2]=sp, r[10..17]=a0-a7.
    pub fn getRegisters(self: Machine) *Registers {
        return c.libriscv_get_registers(self.handle);
    }

    /// Read a single integer register (0-31).
    pub fn getReg(self: Machine, reg: u5) u64 {
        return self.getRegisters().r[reg];
    }

    /// Write a single integer register (0-31).
    pub fn setReg(self: Machine, reg: u5, value: u64) void {
        self.getRegisters().r[reg] = value;
    }

    /// Set the return value register (a0 / r10).
    pub fn setResult(self: Machine, value: i64) void {
        self.getRegisters().r[10] = @bitCast(value);
    }

    /// Read-only view of guest memory at addr for len bytes.
    /// The returned slice is only valid until the next libriscv call.
    pub fn memview(self: Machine, addr: u64, len: u32) Error![]const u8 {
        const ptr = c.libriscv_memview(self.handle, addr, len) orelse
            return Error.MemoryAccessFailed;
        return ptr[0..len];
    }

    /// Set up a VM function call to a guest-side function.
    /// After this, call run() to execute. Return value will be in a0 (r[10]).
    /// Sets RA to exit address so the machine stops when the function returns.
    /// Resets instruction counter.
    pub fn setupVmcall(self: Machine, address: u64) Error!void {
        const ret = c.libriscv_setup_vmcall(self.handle, address);
        try checkReturn(ret);
    }

    /// Stop execution. Only safe to call from within a syscall handler.
    pub fn stop(self: Machine) void {
        c.libriscv_stop(self.handle);
    }

    /// Retrieve the per-machine opaque pointer set via Options.
    /// Returns a typed pointer, or null if no opaque was set.
    pub fn getOpaque(self: Machine, comptime T: type) ?*T {
        const ptr = c.libriscv_opaque(self.handle);
        return if (ptr == null) null else @ptrCast(@alignCast(ptr));
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
    user_data: ?*anyopaque = null,

    fn toCOptions(self: Options) c.RISCVOptions {
        var opts: c.RISCVOptions = std.mem.zeroes(c.RISCVOptions);
        c.libriscv_set_defaults(&opts);
        opts.max_memory = self.max_memory;
        opts.stack_size = self.stack_size;
        opts.strict_sandbox = if (self.strict_sandbox) 1 else 0;
        opts.@"opaque" = self.user_data;
        return opts;
    }
};

test "libriscv linked" {
    var opts: c.RISCVOptions = undefined;
    c.libriscv_set_defaults(&opts);
    try std.testing.expect(opts.max_memory > 0);
}
