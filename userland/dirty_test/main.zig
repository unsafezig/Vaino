//! Dirty-test ELF — tyhjä Zig-juuri (koodi start.S:ssä).
//!
//! **Vastuu**: Pakottaa linkittäjän sisällyttämään start.S:n.
//! **Riippuvuudet**: ei
//! **Käytetään**: build.zig → dirty-test ELF (31.5.4, embedded_id=2)

// Ei Zig-koodia — kaikki logiikka start.S:ssä freestanding-kutsuina.
pub export fn dirtyTestAnchor() void {}
