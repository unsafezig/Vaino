//! IPC-porttien ydin — kiinteä jonon send/recv (host-testattava).
//!
//! **Vastuu**: Porttitaulukko, viestijono, send/recv.
//! **Riippuvuudet**: ei
//! **Käytetään**: `port.zig`, host-testit

// Yhden viestin maksimipituus tavuina.
pub const MAX_MSG_SIZE: usize = 32;
// Jonon syvyys viestejä per portti.
pub const MAX_QUEUE: usize = 4;
// Maksimi porttien määrä kernelissä.
pub const MAX_PORTS: usize = 32;

// Yksittäinen viesti portin jonossa.
pub const Message = struct {
    // Todellinen datan pituus (≤ MAX_MSG_SIZE).
    len: u8,
    // Kiinteä datapuskuri.
    data: [MAX_MSG_SIZE]u8,
};

// IPC-portti — rengasjonopohjainen viestijono.
pub const Port = struct {
    // Onko porttipaikka käytössä.
    used: bool,
    // Viestit rengasjonossa.
    queue: [MAX_QUEUE]Message,
    // Jonon pää (seuraava recv).
    head: u8,
    // Jonon häntä (seuraava send).
    tail: u8,
    // Viestien määrä jonossa.
    count: u8,
};

// Send/recv-virheet — Zig error set error union -tyyppiä varten.
pub const PortError = error{
    // Porttia ei löydy id:llä.
    NotFound,
    // Jono täynnä (send).
    Full,
    // Jono tyhjä (recv).
    Empty,
    // Viesti liian suuri MAX_MSG_SIZE:lle.
    TooLarge,
    // Ydin ei alustettu.
    NotInitialized,
};

// Globaalit portit — indeksi = port_id.
var ports: [MAX_PORTS]Port = undefined;
// Montako porttia on luotu (seuraava id).
var next_port_id: u32 = 0;
// Onko porttiydin alustettu.
var initialized: bool = false;

// Nollaa kaikki portit — boot ja testit.
pub fn initCore() void {
    // Tyhjennä jokainen porttipaikka.
    for (&ports) |*p| {
        // Merkitse vapaa.
        p.used = false;
        // Nollaa jono.
        p.queue = undefined;
        // Nollaa head.
        p.head = 0;
        // Nollaa tail.
        p.tail = 0;
        // Tyhjä jono.
        p.count = 0;
    }
    // Ensimmäinen id alkaa 0:sta.
    next_port_id = 0;
    // Merkitse alustetuksi.
    initialized = true;
}

// Luo uusi portti — palauttaa port_id (taulukon indeksi).
pub fn createPort() ?u32 {
    // Vaadi alustus.
    if (!initialized) return null;
    // Etsi vapaa paikka.
    var i: usize = 0;
    while (i < ports.len) : (i += 1) {
        // Ohita käytössä olevat.
        if (ports[i].used) continue;
        // Alusta portti.
        ports[i] = .{
            // Paikka käytössä.
            .used = true,
            // Tyhjä jono alussa.
            .queue = undefined,
            // head = 0.
            .head = 0,
            // tail = 0.
            .tail = 0,
            // count = 0.
            .count = 0,
        };
        // Port_id = indeksi.
        const id: u32 = @intCast(i);
        // Päivitä seuraava id tilastoa varten.
        if (id >= next_port_id) next_port_id = id + 1;
        // Palauta uusi port_id.
        return id;
    }
    // Taulukko täynnä.
    return null;
}

// Hae portti id:llä.
fn getPort(port_id: u32) ?*Port {
    // Vaadi alustus.
    if (!initialized) return null;
    // Id rajojen sisällä.
    if (port_id >= ports.len) return null;
    // Hae portti.
    const p = &ports[@intCast(port_id)];
    // Palauta vain jos käytössä.
    if (!p.used) return null;
    // Kelvollinen portti.
    return p;
}

// Lähetä viesti porttiin (enqueue).
// "Niin kuin te tahdotte ihmisten tekevän teille, niin tehkää te heille."
// Luuk. 6:31
pub fn send(port_id: u32, payload: []const u8) PortError!usize {
    // Vaadi alustus.
    if (!initialized) return error.NotInitialized;
    // Hae portti.
    const p = getPort(port_id) orelse return error.NotFound;
    // Tyhjä viesti on OK (0 tavua).
    if (payload.len == 0) return 0;
    // Viesti ei saa ylittää MAX_MSG_SIZE.
    if (payload.len > MAX_MSG_SIZE) return error.TooLarge;
    // Jono täynnä → ei tilaa.
    if (p.count >= MAX_QUEUE) return error.Full;
    // Kirjoita viesti tail-indeksin kohdalle.
    const slot = &p.queue[p.tail];
    // Tallenna pituus.
    slot.len = @intCast(payload.len);
    // Kopioi tavut puskuriin.
    @memcpy(slot.data[0..payload.len], payload);
    // Siirrä tail eteenpäin rengasjonossa.
    p.tail = @intCast((@as(usize, p.tail) + 1) % MAX_QUEUE);
    // Kasvata viestien määrää.
    p.count +%= 1;
    // Muistiesto — IRQ-lähetys näkyy recv-kuuntelijalle.
    asm volatile ("" ::: .{ .memory = true });
    // Palauta lähetettyjen tavujen määrä.
    return payload.len;
}

// Vastaanota viesti portista (dequeue).
// "Jokainen, joka pyytää, saa, ja joka etsii, löytää."
// Matt. 7:8
pub fn recv(port_id: u32, buf: []u8) PortError!usize {
    // Vaadi alustus.
    if (!initialized) return error.NotInitialized;
    // Hae portti.
    const p = getPort(port_id) orelse return error.NotFound;
    // Muistiesto — näe IRQ-päivitetty jono.
    asm volatile ("" ::: .{ .memory = true });
    // Tyhjä jono → ei viestejä.
    if (p.count == 0) return error.Empty;
    // Hae viesti head-indeksistä.
    const msg = p.queue[p.head];
    // Kopioitavien tavujen määrä (min msg.len, buf.len).
    const copy_len = @min(@as(usize, msg.len), buf.len);
    // Kopioi viesti vastaanottopuskuriin.
    @memcpy(buf[0..copy_len], msg.data[0..copy_len]);
    // Siirrä head eteenpäin.
    p.head = @intCast((@as(usize, p.head) + 1) % MAX_QUEUE);
    // Vähennä jonon pituutta.
    p.count -%= 1;
    // Palauta viestin alkuperäinen pituus (ei vain copy_len).
    return msg.len;
}

// Montako viestiä portin jonossa (diagnostiikka).
pub fn pendingCount(port_id: u32) ?u8 {
    // Hae portti.
    const p = getPort(port_id) orelse return null;
    // Palauta jonon pituus.
    return p.count;
}

// Palauta portin viestijonon maksimisyvyys (vakio MAX_QUEUE).
pub fn queueCapacity(port_id: u32) ?u8 {
    // Vaadi alustus.
    if (!initialized) return null;
    // Portin pitää olla olemassa.
    if (getPort(port_id) == null) return null;
    // Kiinteä rengasjonon koko kaikille porteille.
    return MAX_QUEUE;
}

// Tyhjennä portin viestijono poistamatta porttia — palauttaa poistettujen viestien määrä.
pub fn flushQueue(port_id: u32) PortError!u8 {
    // Vaadi alustus.
    if (!initialized) return error.NotInitialized;
    // Hae portti.
    const p = getPort(port_id) orelse return error.NotFound;
    // Tallenna poistettavien viestien määrä ennen nollausta.
    const flushed = p.count;
    // Nollaa rengasjono.
    p.head = 0;
    // Nollaa tail.
    p.tail = 0;
    // Tyhjä jono.
    p.count = 0;
    // Muistiesto — flush näkyy recv-kuuntelijalle.
    asm volatile ("" ::: .{ .memory = true });
    // Palauta poistettujen viestien määrä.
    return flushed;
}

// Tuhoa portti — tyhjentää jonon.
// "Minun sieluni janoaa Jumalaa."
// Ps. 42:3
pub fn destroyPort(port_id: u32) bool {
    // Hae portti.
    const p = getPort(port_id) orelse return false;
    // Merkitse vapaa.
    p.used = false;
    // Nollaa jono.
    p.count = 0;
    // Nollaa head.
    p.head = 0;
    // Nollaa tail.
    p.tail = 0;
    // Onnistui.
    return true;
}
