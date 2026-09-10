# Eeden — Zinux Is a Foundation for Building Operating Systems (Phase 37.3)

> *"Zinux is not a fixed operating system. Zinux is a foundation for
> building operating systems."*
>
> Phase 37 closes the roadmap by proving the sentence above is operational,
> not poetic: the system is born for a task, lives by it, and lets itself
> decompose back to the core. What follows is what that means — and what it
> does not.

---

## 1. Birth, life, death (the lifecycle)

A conventional OS is *installed* (a permanent accumulation of drivers,
daemons, and state) and then *maintained* against decay. Zinux inverts this:

- **Birth** — a task arrives as text (`task "serve" { ... }`). The kernel
  composes the minimal environment the task needs: nothing more, nothing
  cached from before. Birth is fast because there is nothing to preserve.
- **Life** — plugins serve under capability bounds. Faults are observed
  (`diag`), corrected versions are validated in-sandbox and hot-swapped
  (Phase 33), load migrates across nodes (Phase 35), drivers are generated
  for the hardware at hand and destroyed after (Phase 36). Life is
  *replaceability in motion*: no component is load-bearing forever.
- **Death** — when the task completes (or its deadline passes), the
  environment decomposes LIFO back to core-only. Death is success, not
  failure: a system that cannot die cleanly cannot be reborn cleanly, and
  the Eeden gate fails loudly on any leftover (`core_only`).

The 30-day demonstration (EEDEN_DEMO.md) runs this whole arc fast-forwarded;
QEMU runs the joints on real kernel code. Both must pass. Either half alone
would be theater.

---

## 2. What Zinux is not

- **Not an AI assistant for a traditional OS.** The AI never holds
  authority: it proposes tasks, plans, and hardware maps; the kernel
  decides capabilities, installation, and execution (every phase, 29–37).
- **Not a driver collection.** There are no `.ko` files (NO_DRIVERS.md).
  Hardware support is a *capacity to generate*, exercised per task and
  destroyed after — "do not store what can safely be constructed."
- **Not a fixed product.** There is no Zinux desktop, no package universe,
  no POSIX promise. Those would be *things built on* the foundation, and
  the foundation must not presume its buildings.
- **Not proven by uptime.** Thirty days of *unchanged* running would prove
  nothing here. The gate measures the opposite: faults healed (5/5 days),
  a crash recovered, a migration completed, a node lost and replaced, and a
  clean death. Stability is shown through repair and release, not stasis.

---

## 3. What the foundation guarantees (and to whom)

To anyone building on Zinux, the core promises a small set of invariants,
each with a test behind it rather than a paragraph:

1. **Least authority** — every plugin holds only its scope (I1–I7); every
   install re-passes the gate, even across the wire (a MAC is an envelope,
   not a capability).
2. **Replaceability** — any plugin can be diagnosed, validated, and swapped
   without human intervention; any driver can be regenerated; any node can
   die without taking the service.
3. **Informative failure** — every refusal names its cause (`Replay`,
   `ForbiddenOverlap`, `NotReady`, `FAILED check '...'`), so the proposer
   (human or AI) can revise without guessing — and without bypassing policy.
4. **Clean death** — decomposition is total and verified; the core alone is
   the defined rest state, and the gate refuses to pass on leftovers.

---

## 4. Standing on shoulders (prior art, honored)

Zinux invented none of its ingredients: capability systems, microkernel
driver isolation, driver synthesis (Termite/Termite-2, with their documented
limits on specification burden and concurrency), sandboxing, checkpointing,
or the idea of composing systems from declarations. The experiment was
narrower and, we hope, honest: *can these known ideas be arranged so that a
system is routinely born and allowed to die — with the kernel, not the AI,
holding every consequential decision?* Phases 29–37 are the apparatus that
makes the question answerable, and the failing-or-passing gate is the answer
for any given commit.

---

## 5. End state

After `Eeden Gate: PASSED`, what remains is the core: memory management,
processes, capabilities, IPC, the plugin lifecycle, and the decision gates.
No services. No drivers. No debris. Ready for the next task — which is the
whole point:

> **Zinux does not maintain itself. It re-becomes itself.**
