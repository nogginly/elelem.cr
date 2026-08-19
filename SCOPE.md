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

### Thinking blocks without a signature will be rejected at request time

Anthropic requires a `thinking` block to carry the signature it issued, replayed
unmodified. We carry signatures correctly when they exist — but nothing stops a
reasoning block that arrived from *another* vendor being mapped here, producing
a `thinking` block with no signature.

The resolver calls foreign reasoning **Restructured**, which is right in the
abstract: the block survives in MPSH and only the unreadable payload is shed.
This protocol turns that into a hard rejection rather than a graceful drop.

Likely correct answer: foreign reasoning mapped to a protocol requiring a
replayable signature should be **Degraded**, dropping the block from the wire
rather than emitting an invalid one. Confirm against a live call before
changing the matrix — this is precisely the class of thing structural
verification cannot settle.

### Protocol documentation is behind the code

`docs/protocols/CHAT_COMPLETIONS.md` exists. `RESPONSES.md`, `ANTHROPIC.md` and
`GEMINI.md` do not. Deferred deliberately until the Gemini mapper lands, since
that is the implementation likeliest to force another correction to the shared
capability model — and revising three protocol documents afterwards costs more
than writing them once.

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

### Carrier deferral is reimplemented per protocol

Three mappers now buffer compensation carriers and flush them at turn
boundaries, and the rule is identical in all three: a carrier belongs to the run
of tool results preceding it, so it must be emitted before anything that is not
itself a tool result — genuine user content, an assistant turn, or the end of
the request.

Written three times, expressed differently each time, and wrong once: the Gemini
mapper flushed only before user messages, so the carrier landed *after* the
model's reply, where export could no longer see the results it belonged to. The
symptom was two divergences — a message count off by one and an image that
stayed a placeholder — from a single missing case.

Export has the same duplication in reverse: three near-identical
`carrier?`/`absorb_carrier`/`split_placeholders` implementations differing only
in the wire types they walk.

Extract once the fourth protocol is stable rather than mid-checkpoint. The shape
is probably a small module parameterized by two predicates — *is this part a
tool result* and *build a carrier message* — since the buffering, the flush
points and the placeholder handling are otherwise identical. `Structural` is
where the outcome is already recorded, so it is the natural home.

Worth doing before a fifth protocol, not after.

### A localizable content synthesizer

Mappers insert two kinds of text, and conflating them would break export.

           |Markers                                             |Glue                                    
-----------|----------------------------------------------------|----------------------------------------
Examples   |`COMPENSATION_PLACEHOLDER`, `FIRST_USER_PLACEHOLDER`|"Result of a provider-run web_search:"  
Read by    |Our own exporter, structurally                      |The model                               
Must be    |Byte-identical in both directions                   |Idiomatic in the conversation's language
Localizable|**Never**                                           |Yes                                     

Markers are matched exactly on export, so a session mapped under one locale and
exported under another would fail to recognise its own scaffolding. They stay
constants, and the reason is recorded beside them.

Glue is read by the model and should be in the conversation's language — which
is *not* the user's interface locale: someone with a French UI may be talking to
the model in Spanish.

Shape: a method-per-case interface (`combine_tool_call_with_response(...)`)
rather than a translation table, so an implementation can reorder a sentence
instead of substituting words. English implementation first.

Two constraints, both load-bearing:

- **It must be a pure function.** Mapping determinism and prefix stability are
  asserted in `spec/conformance/determinism_spec.cr` and are the precondition
  for prefix caching. A sidecar model generating glue per call breaks both. If
  dynamic synthesis is wanted, its output must be generated once and pinned —
  `provider_metadata` on the block that needed it is the natural home — and the
  interface should permit that without changing callers.
- **Locale is supplied, not detected.** Inferring it is a guess that degrades in
  mixed-language sessions. Default English.

Build when the Gemini mapper needs it, so it has two consumers rather than one.

### Server-executed tools degrade without their framing

When a provider-run tool has no equivalent on the target, the result content
survives as conversation and the tool framing does not. That is the right
choice — synthesizing a phantom `tool_call` would advertise a tool the target
does not have, and may prompt it to request one — but the current degradation
drops the framing entirely.

Bare result content loses the fact that a lookup occurred, which occasionally
matters. A short lead-in restores it as prose. That lead-in is **glue**, so it
waits on the synthesizer above.

Explicitly not attempted: re-expressing one vendor's server tool as another's.
Anthropic's web search and Gemini's code execution have rough counterparts, but
they take different parameters and return different shapes, so the mapping
cannot be right by construction. It is the same class of problem as the model
catalog, one layer up.

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
