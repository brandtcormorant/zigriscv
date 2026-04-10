/// Guest-side ecall primitives for riscv64 targets.
///
/// These wrap the RISC-V `ecall` instruction for invoking host syscalls.
/// Only compiles on riscv64 targets (the inline assembly is target-specific).
/// For typed gate operations, use GateProtocol.Guest instead.

/// Invoke a syscall with 2 arguments.
pub fn ecall2(number: u32, a0: usize, a1: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [number] "{a7}" (number),
          [arg0] "{a0}" (a0),
          [arg1] "{a1}" (a1),
        : .{ .memory = true }
    );
}

/// Invoke a syscall with 4 arguments.
pub fn ecall4(number: u32, a0: usize, a1: usize, a2: usize, a3: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [number] "{a7}" (number),
          [arg0] "{a0}" (a0),
          [arg1] "{a1}" (a1),
          [arg2] "{a2}" (a2),
          [arg3] "{a3}" (a3),
        : .{ .memory = true }
    );
}
