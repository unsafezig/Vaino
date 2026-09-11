//! Crash-test ELF — tyhjä Zig-juuri (koodi start.S:ssä).
//!
//! **Vastuu**: Pakottaa linkittäjän sisällyttämään start.S:n.
//! **Riippuvuudet**: ei
//! **Käytetään**: build.zig → crash-test ELF (31.5.5, embedded_id=3)

// Ei Zig-koodia — kaikki logiikka start.S:ssä freestanding-kutsuina.
pub export fn crashTestAnchor() void {}
