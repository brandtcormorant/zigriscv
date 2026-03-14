pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\li a7, 64
        \\li a0, 1
        \\la a1, msg
        \\li a2, 22
        \\ecall
        \\li a7, 93
        \\li a0, 42
        \\ecall
        :
        :
        : "a0", "a1", "a2", "a7"
    );
    unreachable;
}

export const msg: [22]u8 = "hello from the sandbox".*;
