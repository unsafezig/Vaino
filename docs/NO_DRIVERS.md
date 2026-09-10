# No Persistent Driver Files (Phase 36.4)

> **Goal**: There are no `.ko` files in Zinux. There is only the *capacity to
> generate* a driver when a task needs hardware.
> **Status**: Phase 36 design note — enforced by construction in
> `kernel/hw_lifecycle.zig` (one active record, destroy zeroes it).
> **Principle**: *Do not store what can safely be constructed when needed.*

---

## 1. The rule

A bound driver exists **only** between `generateBind` and `destroy`:

```
generate → bind → exec → destroy
   │         │       │        │
   │         │       │        └─ record zeroed, sensor detached, nothing on disk
   │         │       └─ straight-line run + expect check (else inactive)
   │         └─ validated plan ∩ device window ∩ kernel policy
   └─ detect + declare (HwDescriptor)
```

After `destroy`, no bytes of the driver remain anywhere: no filesystem entry
(there is no driver filesystem), no registry slot, no cached expansion.
The *plan* may be kept by the requester (it is their request, not the
kernel's state); the *grant* — the bound addresses — dies with the record.
Re-running the hardware means re-generating, which re-validates: policy
changes apply to old plans automatically because nothing was stored past
the decision.

---

## 2. Why (AGENTS.md)

- **Stale authority dies.** A `.ko` on disk is authority that outlives its
  review. A generated binding is authority with a visible lifetime; revoking
  it is `destroy`, not "find every copy".
- **Policy is always current.** If the kernel adds a forbidden region
  tomorrow, yesterday's stored driver would silently violate it. With no
  stored drivers, every bind checks today's policy.
- **Measurement stays honest.** "Does the plan still generate?" is answered
  by generating — not by trusting a cached artifact while presenting results
  as the same experiment (reproducibility rule).

---

## 3. What is (and is not) stored

| Stored | Not stored |
|--------|-----------|
| `DriverPlan` (requester's request text) | `BoundDriver` (kernel's grant — dies at destroy) |
| `HwDescriptor` format (protocol) | per-device expansions |
| Templates (framework boilerplate in kernel source) | compiled driver blobs |
| Validation policy (source) | validation *results* as authority |

The framework templates live in kernel source because they are *not*
hardware-specific (AGENTS.md boilerplate rule: *does this teach us something
about AI-generated hardware logic?* — registration/IPC/lifecycle do not, so
they are deterministic infrastructure, reviewed once).

---

## 4. Costs, stated plainly

- Re-generation costs a validation + expansion per bind (microseconds of
  integer math — measured, not assumed; the demo does it every boot test).
- Plans must be re-supplied after reboot (they are small: the demo plan is
  1 range + 1 step + 2 reads + 1 expect).
- Debugging a destroyed driver means re-running with the plan, not
  inspecting a corpse — the `expect` counterexample plus the named sensor
  errors (`NotReady`, `ReadOnly`, …) are the post-mortem.

These costs are the experiment's price for the guarantee. If measurement
ever shows the price exceeding the value for a device class, that class gets
a named exception here — not a silent cache.

---

## 5. Relation to other phases

- Phase 30/33 (load/unload, hot-swap): plugins are already replaceable
  units; drivers follow the same lifecycle one level down.
- Phase 31.5 (snapshots): owned *state* migration is orthogonal — a
  re-generated driver starts unarmed by design; state restore (if ever
  wanted for hardware) would be an explicit, separately validated step.
- Phase 35 (federation): a plan is portable text; a *grant* is not —
  migrating hardware access means re-generating against the target's
  descriptor and policy, never copying bound addresses across nodes.
