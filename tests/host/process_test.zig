//! Host-testit prosessitaulukon ytimelle.

const std = @import("std");
const proc = @import("process_core");
const cap = @import("capability_core");

test "process table alloc and current pid" {
    // Puhdas tila.
    proc.initCore();
    // Boot-prosessi rekisteröity automaattisesti.
    try std.testing.expectEqual(@as(usize, 1), proc.processCount());
    try std.testing.expectEqual(@as(u64, 1), proc.currentPid());
    // Toinen prosessi.
    try std.testing.expect(proc.allocProcess(2));
    try std.testing.expectEqual(@as(usize, 2), proc.processCount());
    // Vaihda current pid.
    try std.testing.expect(proc.setCurrentPid(2));
    try std.testing.expectEqual(@as(u64, 2), proc.currentPid());
    // Tuntematon pid hylätään.
    try std.testing.expect(!proc.setCurrentPid(99));
}

test "allocNextPid skips used pids" {
    // Puhdas tila.
    proc.initCore();
    // Boot pid 1 jo rekisteröity — seuraava pitäisi olla 2.
    const pid2 = proc.allocNextPid() orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u64, 2), pid2);
    // Seuraava vapaa on 3 (2 jo käytössä).
    const pid3 = proc.allocNextPid() orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u64, 3), pid3);
}

test "setLoaded and getLoadedInfo" {
    // Puhdas tila.
    proc.initCore();
    // Allokoi prosessi 5.
    try std.testing.expect(proc.allocProcess(5));
    // Ei vielä ladattu.
    try std.testing.expect(proc.getLoadedInfo(5) == null);
    // Tallenna ladatut kentät.
    try std.testing.expect(proc.setLoaded(5, 0x1000, 0x2000, 77));
    // Hae tiedot.
    const info = proc.getLoadedInfo(5) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u64, 0x1000), info.entry);
    try std.testing.expectEqual(@as(u64, 0x2000), info.stack_top);
    try std.testing.expectEqual(@as(u64, 77), info.stack_slot);
}

test "capability slots isolated per process" {    // Puhdas tila — prosessi 1 + capability.
    cap.initCore();
    // Rekisteröi prosessi 2.
    try std.testing.expect(proc.allocProcess(2));
    // Objekti prosessille 1.
    const obj1 = cap.createObject(.port, 1, 11) orelse return error.TestFailed;
    const slot1 = cap.installSlotForPid(1, obj1, .{ .send = true }) orelse return error.TestFailed;
    // Objekti prosessille 2.
    const obj2 = cap.createObject(.port, 2, 22) orelse return error.TestFailed;
    const slot2 = cap.installSlotForPid(2, obj2, .{ .recv = true }) orelse return error.TestFailed;
    // Sama slot-indeksi molemmilla prosesseilla (0).
    try std.testing.expectEqual(@as(u32, 0), slot1);
    try std.testing.expectEqual(@as(u32, 0), slot2);
    // Eri objektit lookupSlotForPid:llä.
    const ref1 = cap.lookupSlotForPid(1, slot1) orelse return error.TestFailed;
    const ref2 = cap.lookupSlotForPid(2, slot2) orelse return error.TestFailed;
    try std.testing.expect(ref1.object_id != ref2.object_id);
    // lookupSlot käyttää current pid:tä.
    try std.testing.expect(proc.setCurrentPid(2));
    const cur = cap.lookupSlot(slot2) orelse return error.TestFailed;
    try std.testing.expectEqual(ref2.object_id, cur.object_id);
}

test "non-LIFO free keeps tail reachable (K1)" {
    // Puhdas tila (boot pid 1).
    proc.initCore();
    // Kaksi peräkkäistä: A=2 (vanhempi), B=3 (häntä).
    try std.testing.expect(proc.allocProcess(2));
    try std.testing.expect(proc.allocProcess(3));
    // Vapauta VANHEMPI ensin (migraation lähde ennen varaajaa).
    try std.testing.expect(proc.freePid(2));
    // Häntä yhä löydettävissä (ei orpoudu used_count-rajalla).
    try std.testing.expect(proc.exists(3));
    try std.testing.expect(proc.setCurrentPid(3));
    // Laskuri on elävien määrä (1 boot + B).
    try std.testing.expectEqual(@as(usize, 2), proc.processCount());
    // Uusi allokaatio EI kirjoita hännän päälle (reikäuudelleenkäyttö).
    try std.testing.expect(proc.allocProcess(4));
    try std.testing.expect(proc.exists(3));
    try std.testing.expect(proc.exists(4));
    try std.testing.expectEqual(@as(usize, 3), proc.processCount());
}

test "pidAt enumerates live ordinals across holes" {
    // Puhdas tila + kolme prosessia.
    proc.initCore();
    try std.testing.expect(proc.allocProcess(2));
    try std.testing.expect(proc.allocProcess(3));
    try std.testing.expect(proc.allocProcess(4));
    // Vapauta keskimmäinen (reikä).
    try std.testing.expect(proc.freePid(3));
    // Ordinaalit tiheinä: 0→boot, 1→2, 2→4 (ei reikää).
    try std.testing.expectEqual(@as(u64, 1), (proc.pidAt(0) orelse return error.TestFailed));
    try std.testing.expectEqual(@as(u64, 2), (proc.pidAt(1) orelse return error.TestFailed));
    try std.testing.expectEqual(@as(u64, 4), (proc.pidAt(2) orelse return error.TestFailed));
    // Alueen ulkopuolella → null.
    try std.testing.expect(proc.pidAt(3) == null);
}
