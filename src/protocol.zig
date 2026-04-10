/// Comptime gate protocol generator.
///
/// Generates both guest-side call stubs and host-side handler wiring
/// from a single protocol definition. Uses per-machine context via
/// libriscv's user_data pointer for instance safety.
///
///   const Proto = GateProtocol(.{
///       .sort = .{ .inputs = 1 },
///       .diff = .{ .inputs = 2 },
///   });
///
///   // Guest (riscv64):
///   const gate = Proto.Guest(504);
///   const sorted = gate.call("sort", .{text}, &buf);
///
///   // Host (native):
///   const GateHost = Proto.Host(504, riscv.Machine);
///   try GateHost.registerHandlers(riscv);
///   var ctx = GateHost.Context{};
///   GateHost.setImpl(&ctx, "sort", &mySortFn);
///   var machine = riscv.Machine.init(elf, .{ .user_data = @ptrCast(&ctx) });
const std = @import("std");

/// Function signature for 1-input gate implementations.
/// Takes an allocator and input bytes, returns allocated output or null.
pub const Impl1 = *const fn (std.mem.Allocator, []const u8) ?[]u8;

/// Function signature for 2-input gate implementations.
pub const Impl2 = *const fn (std.mem.Allocator, []const u8, []const u8) ?[]u8;

pub fn GateProtocol(comptime spec: anytype) type {
    const fields = @typeInfo(@TypeOf(spec)).@"struct".fields;

    return struct {
        pub const op_count = fields.len;

        pub fn syscallNum(comptime base: u32, comptime name: []const u8) u32 {
            inline for (fields, 0..) |field, i| {
                if (comptime std.mem.eql(u8, field.name, name)) return base + @as(u32, i);
            }
            @compileError("unknown gate operation: " ++ name);
        }

        pub fn inputCount(comptime name: []const u8) u32 {
            inline for (fields) |field| {
                if (comptime std.mem.eql(u8, field.name, name)) {
                    return @field(spec, field.name).inputs;
                }
            }
            @compileError("unknown gate operation: " ++ name);
        }

        pub fn opIndex(comptime name: []const u8) u32 {
            inline for (fields, 0..) |field, i| {
                if (comptime std.mem.eql(u8, field.name, name)) return @as(u32, i);
            }
            @compileError("unknown gate operation: " ++ name);
        }

        pub fn readResultNum(comptime base: u32) u32 {
            return base + fields.len;
        }

        // -------------------------------------------------------------------
        // Guest
        // -------------------------------------------------------------------

        pub fn Guest(comptime base: u32) type {
            return struct {
                /// Call a gate operation. inputs is a tuple of []const u8 slices.
                /// Returns the result slice into out_buf, or null on error.
                pub fn call(comptime name: []const u8, inputs: anytype, out_buf: []u8) ?[]const u8 {
                    const n_inputs = comptime inputCount(name);
                    const n_provided = @typeInfo(@TypeOf(inputs)).@"struct".fields.len;
                    if (n_inputs != n_provided) {
                        @compileError(std.fmt.comptimePrint(
                            "gate '{s}' expects {d} input(s), got {d}",
                            .{ name, n_inputs, n_provided },
                        ));
                    }

                    const num = comptime syscallNum(base, name);

                    if (n_inputs == 1) {
                        return ecallSingle(num, inputs[0], out_buf);
                    } else if (n_inputs == 2) {
                        return ecallDual(num, comptime readResultNum(base), inputs[0], inputs[1], out_buf);
                    } else {
                        @compileError("gate operations support 1 or 2 inputs");
                    }
                }

                fn ecallSingle(num: u32, input: []const u8, out_buf: []u8) ?[]const u8 {
                    const len = ecall4(num, @intFromPtr(input.ptr), input.len, @intFromPtr(out_buf.ptr), out_buf.len);
                    const signed: i64 = @bitCast(len);
                    if (signed < 0) return null;
                    return out_buf[0..len];
                }

                fn ecallDual(num: u32, read_num: u32, in1: []const u8, in2: []const u8, out_buf: []u8) ?[]const u8 {
                    const total = ecall4(num, @intFromPtr(in1.ptr), in1.len, @intFromPtr(in2.ptr), in2.len);
                    const signed: i64 = @bitCast(total);
                    if (signed < 0) return null;

                    const read_len = ecall4(read_num, @intFromPtr(out_buf.ptr), out_buf.len, 0, 0);
                    const read_signed: i64 = @bitCast(read_len);
                    if (read_signed < 0) return null;
                    return out_buf[0..read_len];
                }
            };
        }

        // -------------------------------------------------------------------
        // Host
        // -------------------------------------------------------------------

        pub fn Host(comptime base: u32, comptime Machine: type) type {
            return struct {
                /// Per-machine context. Holds result buffers and implementation
                /// function pointers. Create one per Machine instance, pass as
                /// user_data in Machine.init options.
                pub const Context = struct {
                    stored_result: [64 * 1024]u8 = undefined,
                    stored_result_len: usize = 0,
                    impls1: [op_count]?Impl1 = [_]?Impl1{null} ** op_count,
                    impls2: [op_count]?Impl2 = [_]?Impl2{null} ** op_count,
                };

                /// Register global syscall handlers. Call once before creating machines.
                /// The handlers read per-machine state via getOpaque.
                pub fn registerHandlers(comptime riscv_mod: type) !void {
                    inline for (fields, 0..) |field, i| {
                        const n_inputs = @field(spec, field.name).inputs;
                        const num: u32 = base + @as(u32, i);

                        if (n_inputs == 1) {
                            try riscv_mod.setSyscallHandler(num, &mkSingle(i));
                        } else if (n_inputs == 2) {
                            try riscv_mod.setSyscallHandler(num, &mkDual(i));
                        }
                    }

                    try riscv_mod.setSyscallHandler(comptime readResultNum(base), &handleReadResult);
                }

                /// Set an implementation on a context by operation name.
                /// Null function pointer = capability disabled (gate returns -1).
                pub fn setImpl(ctx: *Context, comptime name: []const u8, impl: anytype) void {
                    const idx = comptime opIndex(name);
                    const n_inputs = comptime inputCount(name);
                    if (n_inputs == 1) {
                        ctx.impls1[idx] = impl;
                    } else {
                        ctx.impls2[idx] = impl;
                    }
                }

                fn getCtx(m: Machine) ?*Context {
                    return m.getOpaque(Context);
                }

                fn mkSingle(comptime idx: u32) fn (Machine) void {
                    return struct {
                        fn handler(m: Machine) void {
                            const ctx = getCtx(m) orelse {
                                m.setResult(@as(i64, -1));
                                return;
                            };
                            const impl = ctx.impls1[idx] orelse {
                                m.setResult(@as(i64, -1));
                                return;
                            };

                            const in_ptr = m.getReg(10);
                            const in_len = m.getReg(11);
                            const out_ptr = m.getReg(12);
                            const out_cap = m.getReg(13);

                            const input = m.memview(in_ptr, @intCast(in_len)) catch {
                                m.setResult(@as(i64, -1));
                                return;
                            };

                            const allocator = std.heap.page_allocator;
                            const res = impl(allocator, input) orelse {
                                m.setResult(@as(i64, -1));
                                return;
                            };
                            defer allocator.free(res);

                            if (res.len > out_cap) {
                                m.setResult(@as(i64, -1));
                                return;
                            }

                            m.copyToGuest(out_ptr, res) catch {
                                m.setResult(@as(i64, -1));
                                return;
                            };
                            m.setResult(@intCast(res.len));
                        }
                    }.handler;
                }

                fn mkDual(comptime idx: u32) fn (Machine) void {
                    return struct {
                        fn handler(m: Machine) void {
                            const ctx = getCtx(m) orelse {
                                m.setResult(@as(i64, -1));
                                return;
                            };
                            const impl = ctx.impls2[idx] orelse {
                                m.setResult(@as(i64, -1));
                                return;
                            };

                            const in1_ptr = m.getReg(10);
                            const in1_len = m.getReg(11);
                            const in2_ptr = m.getReg(12);
                            const in2_len = m.getReg(13);

                            const input1 = m.memview(in1_ptr, @intCast(in1_len)) catch {
                                m.setResult(@as(i64, -1));
                                return;
                            };

                            const input2 = m.memview(in2_ptr, @intCast(in2_len)) catch {
                                m.setResult(@as(i64, -1));
                                return;
                            };

                            const allocator = std.heap.page_allocator;
                            const res = impl(allocator, input1, input2) orelse {
                                m.setResult(@as(i64, -1));
                                return;
                            };
                            defer allocator.free(res);

                            if (res.len > ctx.stored_result.len) {
                                m.setResult(@as(i64, -1));
                                return;
                            }

                            @memcpy(ctx.stored_result[0..res.len], res);
                            ctx.stored_result_len = res.len;
                            m.setResult(@intCast(res.len));
                        }
                    }.handler;
                }

                fn handleReadResult(m: Machine) void {
                    const ctx = getCtx(m) orelse {
                        m.setResult(@as(i64, -1));
                        return;
                    };

                    const out_ptr = m.getReg(10);
                    const out_cap = m.getReg(11);

                    if (ctx.stored_result_len > out_cap) {
                        m.setResult(@as(i64, -1));
                        return;
                    }

                    m.copyToGuest(out_ptr, ctx.stored_result[0..ctx.stored_result_len]) catch {
                        m.setResult(@as(i64, -1));
                        return;
                    };
                    m.setResult(@intCast(ctx.stored_result_len));
                }
            };
        }
    };
}

/// Combined sandbox type: control channel (500-503) + gate operations.
///
/// Composes a GateProtocol with the standard control channel into
/// a single type with one Context, one registerAll, and one user_data pointer.
///
///   const Sb = Sandbox(.{ .sort = .{ .inputs = 1 } }, 504, riscv.Machine);
///   try Sb.registerAll(riscv);
///   var ctx = Sb.Context{};
///   Sb.Gate.setImpl(&ctx.gate, "sort", &sortFn);
///   ctx.command = "sort";
///   var m = riscv.Machine.init(elf, .{ .user_data = @ptrCast(&ctx.gate) });
///   m.run(0);
///   const result = ctx.result();
pub fn Sandbox(comptime gate_spec: anytype, comptime gate_base: u32, comptime Machine: type) type {
    const Proto = GateProtocol(gate_spec);
    const GateHost = Proto.Host(gate_base, Machine);

    return struct {
        pub const Gate = GateHost;
        pub const GuestGate = Proto.Guest(gate_base);

        pub const Context = struct {
            gate: GateHost.Context = .{},
            command: []const u8 = "",
            result_buf: [64 * 1024]u8 = undefined,
            result_len: usize = 0,
            error_buf: [4096]u8 = undefined,
            error_len: usize = 0,
            output_buf: [64 * 1024]u8 = undefined,
            output_len: usize = 0,

            pub fn result(self: *const Context) []const u8 {
                return self.result_buf[0..self.result_len];
            }

            pub fn err(self: *const Context) []const u8 {
                return self.error_buf[0..self.error_len];
            }

            pub fn output(self: *const Context) []const u8 {
                return self.output_buf[0..self.output_len];
            }
        };

        fn getCtx(m: Machine) ?*Context {
            const gate_ctx = m.getOpaque(GateHost.Context) orelse return null;
            return @fieldParentPtr("gate", gate_ctx);
        }

        /// Register all handlers: control channel (500-503) + gate operations.
        pub fn registerAll(comptime riscv_mod: type) !void {
            try riscv_mod.setSyscallHandler(500, &handleGetCommand);
            try riscv_mod.setSyscallHandler(501, &handlePutResult);
            try riscv_mod.setSyscallHandler(502, &handlePutError);
            try riscv_mod.setSyscallHandler(503, &handlePutOutput);
            try GateHost.registerHandlers(riscv_mod);
        }

        fn handleGetCommand(m: Machine) void {
            const ctx = getCtx(m) orelse {
                m.setResult(0);
                return;
            };
            const buf_ptr = m.getReg(10);
            const buf_cap = m.getReg(11);
            if (ctx.command.len == 0 or ctx.command.len > buf_cap) {
                m.setResult(0);
                return;
            }
            m.copyToGuest(buf_ptr, ctx.command) catch {
                m.setResult(0);
                return;
            };
            m.setResult(@intCast(ctx.command.len));
        }

        fn handlePutResult(m: Machine) void {
            const ctx = getCtx(m) orelse {
                m.setResult(@as(i64, -1));
                return;
            };
            const ptr = m.getReg(10);
            const len = m.getReg(11);
            if (len > ctx.result_buf.len) {
                m.setResult(@as(i64, -1));
                return;
            }
            const view = m.memview(ptr, @intCast(len)) catch {
                m.setResult(@as(i64, -1));
                return;
            };
            @memcpy(ctx.result_buf[0..view.len], view);
            ctx.result_len = view.len;
            m.setResult(0);
        }

        fn handlePutError(m: Machine) void {
            const ctx = getCtx(m) orelse {
                m.setResult(@as(i64, -1));
                return;
            };
            const ptr = m.getReg(10);
            const len = m.getReg(11);
            if (len > ctx.error_buf.len) {
                m.setResult(@as(i64, -1));
                return;
            }
            const view = m.memview(ptr, @intCast(len)) catch {
                m.setResult(@as(i64, -1));
                return;
            };
            @memcpy(ctx.error_buf[0..view.len], view);
            ctx.error_len = view.len;
            m.setResult(0);
        }

        fn handlePutOutput(m: Machine) void {
            const ctx = getCtx(m) orelse {
                m.setResult(@as(i64, -1));
                return;
            };
            const ptr = m.getReg(10);
            const len = m.getReg(11);
            const remaining = ctx.output_buf.len - ctx.output_len;
            if (len > remaining) {
                m.setResult(@as(i64, -1));
                return;
            }
            const view = m.memview(ptr, @intCast(len)) catch {
                m.setResult(@as(i64, -1));
                return;
            };
            @memcpy(ctx.output_buf[ctx.output_len..][0..view.len], view);
            ctx.output_len += view.len;
            m.setResult(0);
        }
    };
}

fn ecall4(number: u32, a0: usize, a1: usize, a2: usize, a3: usize) usize {
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
