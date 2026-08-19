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

### Export handles requests, not responses

Acceptance criterion 8 — a live session started on Chat Completions, exported,
and resumed on the Responses API — needs export to accept a provider
*response*, which is a different shape from the request the conformance suite
round-trips (`choices[0].message`, not `messages[]`).

Round-trip conformance is unaffected and remains request-shaped. Fold this into
Phase 2, since both OpenAI protocols need it and the client layer is where it
gets used.

---

Otherwise nothing outstanding. The Phase 0 entries — the unverified recursive `Block`
union, the plan's superseded checklist line, and the missing conformance
fixtures — are all resolved. The union compiles, so mappers keep
compiler-enforced exhaustiveness over the block catalog and the flat-form
fallback was not needed.

---

## WILL FIX

### The third identity: providers, and whether a model catalog should exist

Phase 0 established two identities and needs a third.

Identity             |Where it lives now    |Answers                                            
---------------------|----------------------|---------------------------------------------------
**Vendor namespace** |`Profile#metadata_key`|Whose opaque data is this, and who can read it back
**Protocol**         |`Profile#provider`    |What shape does the request take                   
**Provider instance**|Does not exist yet    |Where is it sent, which models are served          

The third arrives with the client layer, and it is genuinely many-to-one:
Ollama, LM Studio and vLLM all serve Chat Completions, and none of them issues
OpenAI's encrypted reasoning items. A provider is an endpoint plus a protocol
plus the models available there.

That last part is where the parked model-catalog question attaches, because the
two turned out to be the same question. `ReasoningRetention::CompletedTurns`
exists for a requirement keyed on **model**, not protocol — one model family
asks that reasoning be dropped once a turn closes. Declared media support has
the same problem in miniature: both OpenAI profiles list audio media types, but
audio support is model-gated in practice, and a self-hosted server speaking Chat
Completions may support none of it.

Open questions:

- Should a model catalog exist, keyed independently of protocol, and is it the
  same thing as a provider's model list or a separate layer?
- What is the minimal preference set it carries? Reasoning retention is one.
  Media support narrowing is a likely second.
- **The trap**: a catalog is a second place where "what this endpoint wants" is
  decided. A preference may only ask for *less* than the protocol can carry —
  narrowing declared media, or trimming playback. One that can *add* capability,
  or override a refusal, is a back door around the capability model. Any
  candidate failing that test does not belong in the catalog.

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

`docs/protocols/CHAT_COMPLETIONS.md` exists. One per remaining mapper, written
with that mapper rather than after it. Keeping this material out of
`DEVELOPMENT.md` is what stops the spine growing into a monospec.

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
`docs/IMPLEMENTATION_PLAN.md` §7. The stateful-session design is deliberately **not** in `docs/` — it describes
bindings, drift markers and provider handles, none of which exist here, and
committing it invites a contributor to start building them. It arrives with
Phase 5. `docs/PSR_BRANCHING_AND_SCATTER_GATHER.md` *is* present, despite also
being Phase 5 material, because it is the source of the annotation concept
Phase 0 already implements and of the view seam that keeps mappers
branch-unaware. It carries a deferred-status banner. `MPSH::CallIdTable` exists because ID translation
is needed for round-trip conformance now; it is shaped like what a binding will
later hold, and is the only part of the deferred layer present.
