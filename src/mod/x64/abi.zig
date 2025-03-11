
//! # Abi
//! This module is a namespace defining the register conventions used by Ribbon on X64 platforms;
//! values will be different depending if `pl.ABI` is set to `.sys_v` or `.win`.
//!
//! ## X64 Register reference
//! | Byte 0 | Byte 1 | Bytes 0-1 | Bytes 0-3 | Bytes 0-8 | Must save | ABI Notes |
//! |-|-|-|-|-|-|-|
//! | `al`   | `ah`    | `ax`   | `eax`  | `rax` | **Caller**   | C ABI return value                       |
//! | `dil`  | **n/a** | `di`   | `edi`  | `rdi` | **Caller**   | SYS-V ABI argument 1                     |
//! | `sil`  | **n/a** | `si`   | `esi`  | `rsi` | **Caller**   | SYS-V ABI argument 2                     |
//! | `dl`   | `dh`    | `dx`   | `edx`  | `rdx` | **Caller**   | SYS-V ABI argument 3, WIN ABI argument 2 |
//! | `cl`   | `ch`    | `cx`   | `ecx`  | `rcx` | **Caller**   | SYS-V ABI argument 4, WIN ABI argument 1 |
//! | `r8b`  | **n/a** | `r8w`  | `r8d`  | `r8`  | **Caller**   | SYS-V ABI argument 5, WIN ABI argument 3 |
//! | `r9b`  | **n/a** | `r9w`  | `r9d`  | `r9`  | **Caller**   | SYS-V ABI argument 6, WIN ABI argument 4 |
//! | `r10b` | **n/a** | `r10w` | `r10d` | `r10` | **Caller**   | General purpose                          |
//! | `r11b` | **n/a** | `r11w` | `r11d` | `r11` | **Caller**   | General purpose                          |
//! | `r12b` | **n/a** | `r12w` | `r12d` | `r12` | **Callee**   | General purpose                          |
//! | `r13b` | **n/a** | `r13w` | `r13d` | `r13` | **Callee**   | General purpose                          |
//! | `r14b` | **n/a** | `r14w` | `r14d` | `r14` | **Callee**   | General purpose                          |
//! | `r15b` | **n/a** | `r15w` | `r15d` | `r15` | **Callee**   | General purpose                          |
//! | `bl`   | `bh`    | `bx`   | `ebx`  | `rbx` | **Callee**   | General purpose                          |
//! | `spl`  | **n/a** | `sp`   | `esp`  | `rsp` | C ABI stack pointer                                     |
//! | `bpl`  | **n/a** | `bp`   | `ebp`  | `rbp` | C ABI frame pointer                                     |
const Abi = @This();

const std = @import("std");
const log = std.log.scoped(.X64Abi);

const pl = @import("platform");
const assembler = @import("assembler");

test {
    std.testing.refAllDeclsRecursive(@This());
}

/// A hardware register; `rax`
///
/// this is used as the primary hardware register where
/// intermediate values are manipulated.
///
/// * caller saved
/// * in C ABI, this is used for returning values from function calls.
pub const ACC = assembler.Register.rax;

/// A hardware register; `rbx`
///
/// always contains a pointer to the `Rvm.Fiber`
/// which the `X64Jit`-generated code is executing in.
///
/// * callee-saved
/// * value is copied from `AUX1` in the prelude
pub const FIBER = assembler.Register.rbx;

/// A hardware register; `r12`
///
/// always contains a pointer to the current `Rvm.RegisterArray`.
///
/// * callee-saved
/// * value is computed from `FIBER` in the prelude,
pub const VREG = assembler.Register.r12;

/// A hardware register; `r13`
///
/// always contains a pointer to the current `Rvm.CallFrame`.
///
/// * callee-saved
/// * value is computed from `FIBER` in the prelude,
pub const FRAME = assembler.Register.r13;

/// A hardware register; `r13`
///
/// always contains a pointer to the current `Rvm.CallFrame`.
///
/// * callee-saved
/// * value is computed from `FIBER` in the prelude,
pub const IP = assembler.Register.r15;

/// A hardware register; SYS-V: `rdi`, WIN: `rcx`
///
/// this is used as the first auxiliary register.
///
/// * caller saved
/// * general purpose
/// * primarily used for passing arguments to foreign calls
/// * may be used for other purposes, so long as it is not relied upon across calls
/// * In C ABI, this is the first argument to a function call
pub const AUX1 = switch (pl.ABI) { .sys_v => assembler.Register.rdi, .win => assembler.Register.rcx };

/// A hardware register; SYS-V: `rsi`, WIN: `rdx`
///
/// this is used as the second auxiliary register.
///
/// * caller saved
/// * general purpose
/// * primarily used for passing arguments to foreign calls
/// * may be used for other purposes, so long as it is not relied upon across calls
/// * in C ABI, this is the second argument to a function call
pub const AUX2 = switch (pl.ABI) { .sys_v => assembler.Register.rsi, .win => assembler.Register.rdx };

/// A hardware register; `rdx`
///
/// this is used as the third auxiliary register.
///
/// * caller saved
/// * general purpose
/// * primarily used for passing arguments to foreign calls
/// * may be used for other purposes, so long as it is not relied upon across calls
/// * in C ABI, this is the third argument to a function call
pub const AUX3 = switch (pl.ABI) { .sys_v => assembler.Register.rdx, .win => assembler.Register.r8 };

/// A hardware register; `rcx`
///
/// this is used as the fourth auxiliary register.
///
/// * caller saved
/// * general purpose
/// * primarily used for passing arguments to foreign calls.
/// * may be used for other purposes, so long as it is not relied upon across calls
/// * in C ABI, this is used for the fourth argument to a function call
pub const AUX4 = switch (pl.ABI) { .sys_v => assembler.Register.rcx, .win => assembler.Register.r9 };

/// A hardware register; `r8`
///
/// this is used as the fifth auxiliary register.
///
/// * caller saved
/// * general purpose
/// * primarily used for passing arguments to foreign calls
/// * may be used for other purposes, so long as it is not relied upon across calls
/// * in SYS-V ABI, this is used for the fifth argument to a function call
pub const AUX5 = switch (pl.ABI) { .sys_v => assembler.Register.r8, .win => assembler.Register.rdi };

/// A hardware register; `r9`
///
/// this is used as the sixth auxiliary register.
///
/// * caller saved
/// * general purpose
/// * primarily used for passing arguments to foreign calls
/// * may be used for other purposes, so long as it is not relied upon across calls
/// * in SYS-V ABI, this is used for the sixth argument to a function call
pub const AUX6 = switch (pl.ABI) { .sys_v => assembler.Register.r9, .win => assembler.Register.rsi };

/// A hardware register; `r10`
///
/// this is used as the primary tertiary register.
///
/// * caller saved
/// * general purpose
/// * primarily used to store intermediate references into data structures
/// * may be used for other purposes, so long as it is not relied upon across calls
pub const TER_A = assembler.Register.r10;

/// A hardware register; `r11`
///
/// this is used as the secondary tertiary register.
///
/// * caller saved
/// * general purpose
/// * primarily used to store intermediate references into data structures
/// * may be used for other purposes, so long as it is not relied upon across calls
pub const TER_B = assembler.Register.r11;

