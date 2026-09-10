//! VSL-plugin ELF — tyhjä Zig-juuri (koodi start.S:ssä).
//!
//! **Vastuu**: Pakottaa linkittäjän sisällyttämään start.S:n.
//! **Riippuvuudet**: ei
//! **Käytetään**: build.zig → VSL-plugin ELF (embedded_id=1, VSL-0)

 // Ei Zig-koodia — kaikki logiikka start.S:ssä freestanding-kutsuina.
pub export fn vslAnchor() void {}
