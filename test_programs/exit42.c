void _start() {
    asm volatile(
        "li a7, 93\n"
        "li a0, 42\n"
        "ecall\n"
    );
    __builtin_unreachable();
}
