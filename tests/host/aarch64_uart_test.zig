//! ARM64-guest-ydinten host-testit (PL011 + semihosting-vakiot).
//!
//! **Vastuu**: Aja `kernel/arch/aarch64/`-tiedostojen testilohkot hostilla.
//! MMIO-koodi kääntyy hostille mutta sitä ei ajeta — testit kattavat
//! rekisterikartan ja CI-sopimusmerkkijonot.

// Tuo PL011-ajurin testit (rekisterikartta).
test {
    _ = @import("aarch64_uart");
}

// Tuo semihosting-numeroiden testit (ARM-speksi).
test {
    _ = @import("aarch64_semihost");
}
