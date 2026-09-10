//! VSL mini-shell — puhdas komentojen jäsennys (VSL-2).
//!
//! **Vastuu**: Muunna `vsl>`-rivisyöte koneelliseksi komennoksi ilman
//!   syscalleja/I/O:ta. Suoritus (VFS open/read) elää kernelin boot-polussa
//!   (`vsl_fs_syscall.zig`); tämä on pyyntö, ei lupa.
//! **Riippuvuudet**: ei (freestanding + host-testattava).
//! **Käytetään**: host-testit, tuleva ring-3-shell (VSL-4).
//!
//! ## Kielioppi (tarkoituksella pieni — AGENTS.md: pienet kokeet)
//! - `help` → luettele komennot
//! - `ls <polku>` → listaa mountin sisältö (`ls /tmp`)
//! - `cat <polku>` → tulosta tiedosto (`cat /tmp/welcome`)
//! - tyhjä rivi → NoOp (kehote uudelleen)
//! - muu → Unknown (informative failure, ei hiljaista hylkäystä)

// Tunnetut komennot koneellisena unionina.
pub const Command = union(enum) {
    // `help` — ei argumentteja.
    help,
    // `ls <polku>` — polku sellaisenaan (max 64, fd-pariteetti).
    ls: []const u8,
    // `cat <polku>` — polku sellaisenaan.
    cat: []const u8,
    // Tyhjä rivi — kehote uudelleen.
    noop,
    // Tuntematon komento — vastalause nimeää sen (counterexample).
    unknown: []const u8,
};

// Jäsennysvirheet — vakaa järjestys kuten manifestissa/TDL:ssä.
pub const ParseError = error{
    // Polku puuttuu (`ls` ilman argumenttia).
    MissingPath,
    // Polku liian pitkä puskuriin.
    PathTooLong,
};

// Polun maksimipituus (fd MAX_FD_PATH -pariteetti).
pub const MAX_SHELL_PATH: usize = 64;

// Ohita alun välilyönnit/tabit — palauttaa leikatun viipaleen.
fn skipSpaces(line: []const u8) []const u8 {
    // Indeksi ensimmäiseen ei-tyhjään.
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    // Palauta loppu.
    return line[i..];
}

// Leikkaa lopun whitespace + `\n` — palauttaa siistin viipaleen.
fn trimEnd(line: []const u8) []const u8 {
    // Loppuindeksi (exclusive).
    var end: usize = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\n' or line[end - 1] == '\r')) : (end -= 1) {}
    // Palauta alku.
    return line[0..end];
}

// Jäsennä yksi shell-rivi komennoksi — puhdas, ei sivuvaikutuksia.
pub fn parseLine(raw: []const u8) ParseError!Command {
    // Leikkaa molemmat päät.
    const line = trimEnd(skipSpaces(raw));
    // Tyhjä rivi → kehote uudelleen.
    if (line.len == 0) return .noop;
    // Erota ensimmäinen sana (komento) lopusta.
    var split: usize = 0;
    while (split < line.len and line[split] != ' ' and line[split] != '\t') : (split += 1) {}
    // Komentosana.
    const word = line[0..split];
    // Loppuosa argumentiksi (leikattuna).
    const rest = trimEnd(skipSpaces(line[split..]));
    // Vertaa tunnettuihin komentoihin (pituus ensin — halpa hylkäys).
    if (word.len == 4 and word[0] == 'h' and word[1] == 'e' and word[2] == 'l' and word[3] == 'p') {
        // `help` — argumentit ohitetaan (tuleva strictness VSL-4:ssä).
        return .help;
    }
    if (word.len == 2 and word[0] == 'l' and word[1] == 's') {
        // Polku pakollinen.
        if (rest.len == 0) return ParseError.MissingPath;
        // Liian pitkä ei mahdu fd-tauluun.
        if (rest.len >= MAX_SHELL_PATH) return ParseError.PathTooLong;
        // Listaa polku.
        return .{ .ls = rest };
    }
    if (word.len == 3 and word[0] == 'c' and word[1] == 'a' and word[2] == 't') {
        // Polku pakollinen.
        if (rest.len == 0) return ParseError.MissingPath;
        // Liian pitkä ei mahdu fd-tauluun.
        if (rest.len >= MAX_SHELL_PATH) return ParseError.PathTooLong;
        // Tulosta polku.
        return .{ .cat = rest };
    }
    // Tuntematon — palauta sana vastalauseeksi.
    return .{ .unknown = word };
}
