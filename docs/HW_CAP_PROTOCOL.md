# Hardware Capability Protocol (Phase 36.1)

> **Goal**: A device declares what it can do; Zinux generates a temporary
> interface for exactly that. No persistent driver files.
> **Status**: Phase 36 — protocol + plan schema + template expansion against a
> fake sensor; real MMIO binding is 36.x.
> **Principle**: `AI proposes. Kernel decides.` — the descriptor and the plan
> are both *requests*; the kernel intersects them with its own policy
> (including the Phase 1 console UART, which is never re-generated).

---

## 1. Roles (AGENTS.md layer split)

| # | Concept | Lives in | Decided by |
|---|---------|----------|------------|
| 1 | Task (what is needed) | `DriverPlan` (user/AI) | requester |
| 2 | Hardware information (what exists) | `HwDescriptor` (device) | device declaration, kernel-verified |
| 3 | Driver Plan (machine-readable request) | `DriverPlan` struct | requester |
| 4 | Kernel Policy (what is allowed) | `validate()` + reserved regions | **kernel** |
| 5 | Capabilities (granted ranges) | `BoundDriver` addresses | kernel (subset of 2 ∩ 4) |
| 6 | Generated implementation (device-specific map) | `BoundDriver` (regs + sequence) | kernel expansion, deterministic |
| 7 | Validation (did it behave) | `expect` value + `execSequence` | kernel, measured |
| 8 | Isolation / sandbox | one active record, LIFO destroy | kernel |
| 9 | Hardware execution | `sensorRead/sensorWrite` (fake in 36) | device model |

Collapsing 3+4 ("the plan grants itself") or 6+9 ("generated code touches
hardware directly") is forbidden by this spec, no matter how convenient.

---

## 2. Device declaration (`HwDescriptor`)

A device announces:

```zig
HwDescriptor {
    mmio_base: u64, mmio_len: u32,   // one window (multi-window is 36.x)
    caps[8]: { name[16], reg: u8, access: READ/WRITE },
}
```

- `caps` are **named registers with direction**: `temperature@0x10:R`,
  `humidity@0x11:R`. Names are informational; the kernel binds by
  `(reg, access)`, never by name alone (a lying name grants nothing).
- The descriptor is untrusted input until validated: zero-length windows,
  wrapping windows, and unreadable caps are rejected before any plan runs.
- Real hardware (36.x) delivers this descriptor via bus enumeration
  (Phase 6 PCI as reference); in Phase 36 the fake sensor hardcodes its own.

---

## 3. Driver Plan (`DriverPlan`)

The first-class request object (AGENTS.md: *prefer explicit machine-readable
representations over vague prompts*):

```zig
DriverPlan {
    name[32], version = 1,
    ranges[4]: { base, len },        // requested MMIO (subset of window)
    forbidden[4]: { base, len },     // caller-known no-go areas
    steps[16]: { range_idx, reg, value },  // bounded init sequence (no loops)
    read_caps[8]: u8,                // descriptor cap indices to read
    expect: { cap_idx, value },      // promised behavior (counterexample hook)
}
```

Validation order (stable, one cause per rejection):

```
BadName → BadVersion → BadRange/TooManyRanges → ForbiddenOverlap
  → TooManySteps → StepOutOfRange → BadReads → BadCapAccess
```

Policy highlights:

- **P1 — Console protection.** `[0x3F8, 0x400)` (Phase 1 UART) always
  overlaps-forbidden, even if the device window covers it. The kernel never
  generates away its own console.
- **P2 — Window subset.** Every requested range must lie inside the declared
  window (`base+len` without wrap, `len ≤ 0x1000`). A plan cannot mint address
  space the device did not declare.
- **P3 — Bounded execution.** ≤16 init steps, no jumps/loops/conditionals.
  A plan is a straight-line script, analyzable by inspection.
- **P4 — Purpose.** ≥1 read cap: a driver with no measurement is not a
  driver. The `expect` pair is mandatory — every generation promises an
  observable, and the run checks it (AGENTS.md counterexamples).

---

## 4. Template expansion (`generate`)

The kernel holds the **framework** (registration, lifecycle, error frames);
the plan supplies only the **hardware-specific map**. Expansion is pure and
deterministic: same `(plan, descriptor)` → same `BoundDriver` with
precomputed absolute addresses (`base + reg*2` for 16-bit registers).
There is no codegen, no JIT, no embedded compiler — claiming otherwise would
be research-dishonest (research integrity: *never hide what the experiment
actually tests*). What the experiment tests is whether a *minimal declarative
map* suffices to drive hardware through kernel-checked gates — and Phase 36
answers yes for the register-PIO class.

Out of scope for the template class (documented, not silently dropped):
DMA descriptors, interrupt-driven state machines, firmware upload,
multi-window devices, timing-critical sequences. Each is a named 36.x
experiment, not a gap in this one.

---

## 5. Execution + counterexample (`execSequence`)

The bound driver runs straight-line: init writes in order, then reads, then
the `expect` comparison. Any sensor refusal (`OutOfRange`, `ReadOnly`,
`WriteOnly`, `NotReady`) or an `expect` mismatch fails the whole run —
no partial drivers stay active. The failure names its cause (AGENTS.md:
*make failures informative*), e.g. `NotReady` tells the planner "arm first",
not "driver rejected".

---

## 6. Measurement (AGENTS.md)

Per generation, Phase 36 records:

- requested ranges vs. granted ranges (equal or refused — never widened),
- init steps executed vs. promised (equal),
- `expect` hits vs. runs (1:1 required),
- faults by cause on the fake device (the `faults` counter),
- human specification burden for the demo: one plan
  (1 range + 1 step + 2 reads + 1 expect) → working temperature driver,
  zero hand-written loader/registration/IPC lines.

---

## 7. Prior art (standing on shoulders)

Register-map-driven driver synthesis is not a Zinux invention: Termite and
Termite-2 formalized device access, synthesis from specifications, and the
specification burden / state-explosion limits. Phase 36 stays deliberately
*below* Termite's ambition (no full-stack synthesis, no formal proofs) and
measures instead the cheapest useful point: a bounded register script plus a
kernel-checked expectation. The DMA/concurrency problems Termite documented
are exactly why they are excluded in §4 rather than hand-waved.
