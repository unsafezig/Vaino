//! ABI shared by the EL0 synchronous vector and the ARM64 syscall dispatcher.
//!
//! The frame preserves the full user integer context plus the FP/SIMD
//! context (q0-q31, FPCR/FPSR). The vector owns save/restore; the Zig
//! dispatcher only touches x0/x8/ELR/SPSR through this struct.

pub const Aarch64ExceptionFrame = extern struct {
    x0: u64,
    x1: u64,
    x2: u64,
    x3: u64,
    x4: u64,
    x5: u64,
    x6: u64,
    x7: u64,
    x8: u64,
    x9: u64,
    x10: u64,
    x11: u64,
    x12: u64,
    x13: u64,
    x14: u64,
    x15: u64,
    x16: u64,
    x17: u64,
    x18: u64,
    x19: u64,
    x20: u64,
    x21: u64,
    x22: u64,
    x23: u64,
    x24: u64,
    x25: u64,
    x26: u64,
    x27: u64,
    x28: u64,
    x29: u64,
    x30: u64,
    esr_el1: u64,
    elr_el1: u64,
    spsr_el1: u64,
    /// FP/SIMD registers q0-q31 as u64 pairs (little-endian lanes).
    q: [32][2]u64,
    fpcr: u64,
    fpsr: u64,
};

pub const x0_offset = @offsetOf(Aarch64ExceptionFrame, "x0");
pub const x8_offset = @offsetOf(Aarch64ExceptionFrame, "x8");
pub const x30_offset = @offsetOf(Aarch64ExceptionFrame, "x30");
pub const esr_el1_offset = @offsetOf(Aarch64ExceptionFrame, "esr_el1");
pub const elr_el1_offset = @offsetOf(Aarch64ExceptionFrame, "elr_el1");
pub const spsr_el1_offset = @offsetOf(Aarch64ExceptionFrame, "spsr_el1");
pub const q_offset = @offsetOf(Aarch64ExceptionFrame, "q");
pub const q31_offset = q_offset + 31 * 16;
pub const fpcr_offset = @offsetOf(Aarch64ExceptionFrame, "fpcr");
pub const fpsr_offset = @offsetOf(Aarch64ExceptionFrame, "fpsr");
pub const size = @sizeOf(Aarch64ExceptionFrame);

test "exception frame offsets match the vector ABI" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(usize, 0), x0_offset);
    try testing.expectEqual(@as(usize, 64), x8_offset);
    try testing.expectEqual(@as(usize, 240), x30_offset);
    try testing.expectEqual(@as(usize, 248), esr_el1_offset);
    try testing.expectEqual(@as(usize, 256), elr_el1_offset);
    try testing.expectEqual(@as(usize, 264), spsr_el1_offset);
    try testing.expectEqual(@as(usize, 272), q_offset);
    try testing.expectEqual(@as(usize, 272 + 31 * 16), q31_offset);
    try testing.expectEqual(@as(usize, 784), fpcr_offset);
    try testing.expectEqual(@as(usize, 792), fpsr_offset);
    try testing.expectEqual(@as(usize, 800), size);
}
