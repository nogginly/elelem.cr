# Scope

Outstanding work, tracked in two buckets. **Completed items are deleted, not
ticked** — this file is a worklist, not a changelog. It should grow through the
early phases and dissolve as the design settles.

- **MUST FIX** — blocks progress, or is cheap now and expensive later.
- **WILL FIX** — real, but deliberately not now.

Anything settled belongs in code comments or `DEVELOPMENT.md`; anything
outstanding belongs here, because nobody greps a codebase for open questions.

---

## MUST FIX

### Nothing has been compiled

Phase 0 has passed `ameba` and `crystal spec`, but the spec suite is empty, so
essentially no code has been through the type checker. Crystal only checks paths
it actually instantiates. Expect the first fixture to surface several errors at
once.

**Highest-risk construct**: `MPSH::Block` is a recursive union alias —
`ToolResultBlock#content : Array(Block)` forward-references the alias that
includes `ToolResultBlock`. This mirrors `JSON::Any` and should be legal, but it
is unverified and load-bearing.

*If it does not compile*: fall back to an abstract base class plus a `kind` enum.
The cost is real and should be recorded here if paid — mappers lose
compiler-enforced exhaustiveness over the block catalog, which is the single
guard against a mapper silently forgetting `audio`.

Resolve at the first Phase 0 fixture.

### Conformance fixtures do not exist

Phase 0's deliverable list includes the fixture set from
`docs/mpsh-specification.md` §9. Types are proposed and ratified; fixtures are not
written. They are the next piece of work and the thing that will compile the
types for the first time.

The three fixtures arising from Phase 0 rulings are now in the specification's
§9 list: refusal with and without `reason`, consecutive same-role messages
against an alternation-requiring profile, and reasoning under each retention
mode with an open tool-calling turn.

---

## WILL FIX

### Model awareness, and whether a model catalog should exist

Everything in this shard is keyed on **protocol**. The requirement that
motivated `ReasoningRetention::CompletedTurns` is keyed on **model** — one model
family asks that reasoning be dropped once a turn closes, regardless of the
protocol it is reached through.

Open questions, parked until the protocol layer exists and can be argued against
something concrete:

- Should a model catalog exist, independent of protocol?
- What is the minimal preference set it carries? Reasoning retention is one.
  There are probably two or three others, and the discipline is to keep the list
  short.
- **The trap**: a catalog is a second place where "what this endpoint wants" is
  decided. If a preference can override capability rather than only constrain
  playback, it becomes a back door around the capability model. Retention is
  safe precisely because it can only ask for *less* than the protocol can carry.
  Any candidate preference failing that test does not belong in the catalog.

### `tool_result.content` as a nested block list

Specified and implemented as nested blocks. Prior art in Python uses a flat
`output : String` plus an `attachments` sidecar — simpler, but cannot express
interleaved content and needs assembly when mapping to Anthropic.

Revisit **only on evidence** that the recursive type is awkward in Crystal, with
specifics. Quietly flattening it is the failure mode to avoid: it makes
image-returning tools unrepresentable even for providers that support them
natively.

### README.md

Deferred to a named moment rather than "later": **when Phase 2 passes.** The
quick-start example is the handoff — start on Chat Completions, export, resume
on Responses — and that example cannot be written honestly before then. A
placeholder now would say nothing.

### Per-protocol documentation

`docs/protocols/<name>.md`, one per mapper, holding its capability declaration,
its gotchas, and which fixtures it compensates on. Created with the first
mapper, not before. Keeping this material out of `DEVELOPMENT.md` is what stops
the spine growing into a monospec.

---

## Explicitly not doing

### No `UNSUPPORTED.md`

The capability matrix is that document, in a better form: derived from each
protocol's declared `Profile` rather than written by hand, expressed per media
type rather than per feature, and queryable by callers at runtime. A prose
version would be a second statement of the same fact and would drift within a
single phase.

### Out of scope for the current pass

Session tree, branching, scatter/gather, provider bindings, stateful handles,
streaming, tool execution and dispatch, prompt caching, compaction. See
`docs/implementation-plan.md` §7. `llm-stateful-session-design.md` is
deliberately **not** in `docs/` — it describes bindings, drift markers and
provider handles, none of which exist here, and committing it invites a
contributor to start building them. It arrives with Phase 5. `MPSH::CallIdTable` exists because ID translation
is needed for round-trip conformance now; it is shaped like what a binding will
later hold, and is the only part of the deferred layer present.
