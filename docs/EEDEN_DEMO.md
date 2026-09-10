# Eeden Demo — 30-Day Autonomous Lifecycle, Fast-Forwarded (Phase 37.1)

> **Goal**: Prove that Zinux is born for its task, lives by it, and allows
> itself to decompose — without a human in the loop.
> **Status**: Phase 37 — host simulation (`tests/eeden_metrics` +
> `zig build eeden-gate`) plus QEMU lifecycle mechanism (`kernel/eeden.zig`).
> **Principle**: *A small, measurable experiment beats a large, unverifiable
> claim.* Nobody waits 30 days: the same pure decision code runs on a virtual
> clock in milliseconds, and the verdict is a number, not a feeling.

---

## 1. Two halves (neither suffices alone)

| Half | Runs where | Proves | Command |
|------|-----------|--------|---------|
| Simulation | Host (CI, ms) | 30-day autonomy: faults→heals, migration, node loss→failover, core-only end | `zig build eeden-gate` |
| Mechanism | QEMU (CI, ~min) | Each lifecycle joint works on real kernel: compose→run→decompose via scope gates | `zig build boot-test` (contains `Eeden Gate: PASSED`) |

The simulation cannot load ELFs or switch page tables (no loader on host);
QEMU cannot wait 30 days. Together they cover decisions + mechanism. The CI
gate (`eeden_gate.yml`) requires **both** — passing one half is not passing.

---

## 2. Timeline (30 days, `DAY_TICKS = 1000`)

| Day(s) | Event | Core exercised | Expected metric delta |
|--------|-------|----------------|----------------------|
| 0 | Boot; task `serve` parsed + resolved (2 needs → 2 plugins); cluster A+B join; replica home=A spare=B; tunnel peers joined; diag registered | task, resolve, cluster, tunnel, diag | boot_ok, task_ok, compositions_started=1 |
| 3, 7, 19, 26 | Single fault injected → detected (degraded) → healed same day | diag record/health/reset | faults+1, heals+1 each |
| 12 | **Double** fault → hard crash → healed same day | diag saturation + reset | faults+2, crashes+1, heals+1 |
| 14 | Sealed A→B push opened + verified; plan staged→pushed→restored→done; spare serving | tunnel, migrate, replica | tunnel_grants_ok=1, migrations=1 |
| 21 | Node A goes silent (last beat day 20) | cluster heartbeat gap | — (no detection yet: age 1000 < 1500) |
| 22 | Sweep proves A dead → spare promoted | cluster sweep + replica | failovers=1 |
| 29 | Task complete → leaves, peer removals, diag deregister, composition done | cluster/tunnel/diag/composer-decision | compositions_done=1, core_only |
| 30 | Verdict: deadline honored, core alone | decomposer predicate | uptime_days=30, deadline_ok |

Final report (real numbers from the run, printed by the tool):

```
compositions=1/1 faults=6 crashes=1 heals=5 migrations=1
failovers=1 tunnel_grants=1 uptime_days=30
```

Healing invariant: `heals >= fault_days` (5 ≥ 5) — one reset closes all of a
day's injections. The crash on day 12 is deliberate: the schedule proves the
`crashed` path is reachable *and* recoverable, not just the `degraded` path.

---

## 3. Fast-forward mapping (honest)

- 1 day = 1000 virtual ticks; heartbeats daily; sweep timeout 1500 ticks
  (1.5 days) — loss detected exactly 2 days after silence (day 22 for a
  day-21 loss). No wall-clock, no sleep, no randomness: `sim.run()` twice
  yields byte-identical reports (host-tested with `std.meta.eql`).
- The TEST-ONLY tunnel key (`1..32`) lives inside the sim (same honesty as
  Phase 32 fixtures and the Phase 35 boot key — key exchange is 35.x).
- Simulated pids (100/101) stand in for loader pids: diag/migrate/cluster
  never touch page tables, so the substitution is exact for the decisions
  under test. Loading itself is QEMU's job.

---

## 4. Gate criteria (`metrics.zig` — 10 checks, mask 0 = PASSED)

```
boot_ok, task_ok, compositions_done>=1, heals>=fault_days,
migrations>=1, failovers==1, tunnel_grants_ok>=1,
uptime_days>=30, deadline_ok, core_only
```

`failovers==1` is exact (one loss simulated — more would mean a second,
unmodeled outage; fewer a missed detection). Every failure names its check
(`eeden-gate: FAILED check '...'`), non-zero exit closes the gate.

---

## 5. What would falsify this (research first)

- A fault day ending non-healthy → `heals>=fault_days` fails (healing broken).
- Sweep never firing → `failovers==1` fails (detection broken).
- Leftover peer/slot/diag row → `core_only` fails (decomposition leaks).
- `run()` twice differing → determinism test fails (hidden state/time source).

A failed gate is a valid result: it names the broken lifecycle joint.
