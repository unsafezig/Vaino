//! Host-testit checkpoint-säilön taulukolle (31.5.2).
//!
//! **Vastuu**: Allokaatio/etsintä/vapautus ilman laitteistoa.
//! Kehys- (PMM) ja PTE-polut ovat boot-katettuja (`snapshot_syscall.zig`).

const std = @import("std");
const ckpt = @import("snapshot_ckpt_core");

test "ckpt empty table answers null and zero" {
    // Tuntematon cpid → null/false/0 ilman sivuvaikutusta.
    try std.testing.expect(ckpt.findForPid(7) == null);
    try std.testing.expect(ckpt.pageCount(1) == null);
    try std.testing.expect(ckpt.pageVirt(1, 0) == null);
    try std.testing.expect(ckpt.pageFrame(1, 0) == null);
    try std.testing.expect(ckpt.pageWasWritable(1, 0) == null);
    try std.testing.expect(!ckpt.releaseSlot(1));
    try std.testing.expect(!ckpt.releaseSlot(0));
    try std.testing.expect(!ckpt.releaseSlot(99));
    try std.testing.expect(ckpt.slotByCpid(1) == null);
    // Laskuri nolla.
    try std.testing.expectEqual(@as(usize, 0), ckpt.count());
}

test "ckpt alloc find release reuse" {
    // Varaa paikka pidille 9 (cpid 1).
    const c1 = ckpt.allocSlot(9, 0x1000) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 1), c1);
    // Löytyy pidillä.
    try std.testing.expectEqual(c1, ckpt.findForPid(9) orelse return error.TestFailed);
    // Laskuri kasvanut.
    try std.testing.expectEqual(@as(usize, 1), ckpt.count());
    // Tyhjän paikan sivuluku → null (page_count 0).
    try std.testing.expectEqual(@as(usize, 0), ckpt.pageCount(c1) orelse return error.TestFailed);
    try std.testing.expect(ckpt.pageVirt(c1, 0) == null);
    // Vapauta → ei löydy, laskuri nolla.
    try std.testing.expect(ckpt.releaseSlot(c1));
    try std.testing.expect(ckpt.findForPid(9) == null);
    try std.testing.expectEqual(@as(usize, 0), ckpt.count());
    // Vapaa paikka uudelleenkäytetään (sama cpid).
    const c2 = ckpt.allocSlot(10, 0x2000) orelse return error.TestFailed;
    try std.testing.expectEqual(c1, c2);
    // Siivoa.
    try std.testing.expect(ckpt.releaseSlot(c2));
}

test "ckpt table full rejects fifth" {
    // Täytä kaikki 4 paikkaa eri pideillä.
    var ids: [4]u32 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        ids[i] = ckpt.allocSlot(100 + @as(u64, i), 0x3000) orelse return error.TestFailed;
    }
    // Laskuri täynnä.
    try std.testing.expectEqual(@as(usize, 4), ckpt.count());
    // Viides → null (TableFull-polku handlerissa).
    try std.testing.expect(ckpt.allocSlot(999, 0x4000) == null);
    // Vapauta yksi → tilaa yhdelle.
    try std.testing.expect(ckpt.releaseSlot(ids[1]));
    const c = ckpt.allocSlot(999, 0x4000) orelse return error.TestFailed;
    try std.testing.expectEqual(ids[1], c);
    // Siivoa loput.
    try std.testing.expect(ckpt.releaseSlot(ids[0]));
    try std.testing.expect(ckpt.releaseSlot(ids[2]));
    try std.testing.expect(ckpt.releaseSlot(ids[3]));
    try std.testing.expect(ckpt.releaseSlot(c));
    try std.testing.expectEqual(@as(usize, 0), ckpt.count());
}
