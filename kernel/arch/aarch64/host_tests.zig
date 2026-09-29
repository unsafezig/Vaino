//! Host-test aggregator for the ARM64 guest kernel files.
//!
//! Why this exists: `tests/host/*_test.zig` wrappers import these files as
//! NAMED modules, and Zig does not run test blocks across a named-module
//! boundary — the wrappers compile but their tests never execute in
//! `zig build test`. This root lives next to the files so RELATIVE imports
//! stay inside the module path, and every test block below actually runs.
//! (`syscall.zig`/`main.zig` are excluded: their inline SVC asm cannot
//! compile for the host target; their ABI/marker tests run wherever the
//! files build for freestanding. `gringots/` is covered by the
//! `zinux-file-bridge` test binary instead.)

test {
    _ = @import("uart.zig");
    _ = @import("semihost.zig");
    _ = @import("semihost_file.zig");
    _ = @import("exception_frame.zig");
    _ = @import("process.zig");
    _ = @import("cap_ipc.zig");
    _ = @import("storage.zig");
    _ = @import("clock.zig");
    _ = @import("datagram.zig");
}
