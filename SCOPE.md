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

### Interrupted turns must leave a sendable session

**Now reproducible on demand.** `spec/live/ollama_spec.cr` records a turn cut
short by `max_output_tokens: 24`: `stop_reason: max_tokens`, a thinking block,
and no answer. It first appeared by accident — a small model reasoning past its
ceiling — and an accident is a poor fixture. Repair remains unbuilt; the
exporter is deliberately honest and returns what arrived.

A turn can stop before it completes: a user interrupt in an interactive agent, a
resource limit in an automated one, a provider quota, a dropped connection, a
timeout. All produce the same problem and differ only in cause, so they are one
case with a cause attached.

**The invariant**: the session is never left in a state a subsequent `send`
cannot build on. Concretely, no `tool_call` block without a matching
`tool_result` — a dangling call is the one shape Anthropic rejects outright and
the others merely tolerate. Partial turns therefore need *repair*, not just
truncation.

Three states, and only the third is awkward:

What arrived                   |Action                                                                                                                                       
-------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------
Nothing                        |Append nothing. The session is unchanged and immediately resendable                                                                          
Text, no tool calls            |Append the partial assistant message; mark it truncated in `provider_metadata`                                                               
Tool calls, possibly incomplete|**Drop the calls, keep any text.** A partial set may be half a parallel plan, and there is no way to know whether another was about to arrive

**Mechanism: cooperative, not an exception.** Raising from inside the caller's
block unwinds through the client mid-parse, leaving it to reconstruct state
while handling control flow — where subtle bugs live. Prefer a signal the block
can set, with the client stopping at the next safe point and finalising
normally:

```crystal
reply, report = client.send(session) do |event, turn|
  turn.stop if user_pressed_escape?
  present(event)
end
report.interrupted?   # cause attached
```

The cause matters only for the caller's next move — await input, back off,
retry. Session repair is identical in all three.

**Quota needs one distinction.** A pre-request rejection leaves the session
untouched and is a plain retry; mid-response truncation is the third state
above. Streaming exposes the second far more often, which is another reason
streaming is not purely additive later.

No fixture covers this. Build alongside the client.

### The specification is silent on request parameters

`docs/MPSH_SPECIFICATION.md` covers tool *calls and results* in detail and says
nothing about tool *definitions*, output caps or reasoning controls. `Options`
is now complete and every part of it was built past the edge of the spec rather
than against it — reasoning controls most of all, since they also drove a new
`Profile` field and the first model catalog.

That is not obviously wrong — the spec describes a portable *session*, and these
are per-call concerns that deliberately never enter one. But the omission should
be a recorded decision rather than an accident, so a future reader does not
assume the spec ruled on it. Resolve when the spec is next revised.

### Thinking blocks without a signature will be rejected at request time

**The Ollama run did not touch this**, and cannot. Its recorded `thinking`
blocks carry no `signature` field at all, so a block without one passes
trivially. This stays open until a real Anthropic endpoint is recorded — see
`docs/servers/ollama.md`.


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

---

## WILL FIX

### Reasoning controls: the unit is keyed on the model

**Built, and the trichotomy held — but not the table that predicted it.** The
worklist recorded three units keyed on protocol (level, level, tokens, both).
Current documentation says something sharper: two protocols spell *both* units
and reject being handed both, and which one a deployment wants depends on the
**model**.

Protocol        |Spelling                                         |Unit  
----------------|-------------------------------------------------|------
Chat Completions|`reasoning_effort`                               |Rung  
Responses       |`reasoning.effort`                               |Rung  
Anthropic       |`output_config.effort` / `thinking.budget_tokens`|Either
Gemini          |`thinkingConfig.thinkingLevel` / `thinkingBudget`|Either

`Profile` gained `reasoning_unit` as predicted; `Capability::Catalog` resolves
`Either` per model. What remains open is only what a live call can settle:

- **Rungs are model-dependent on the OpenAI protocols too.** `xhigh` and `max`
  serialize happily and may still be rejected by the model behind the endpoint.
  A protocol-level declaration cannot know, and a per-model rung list is a
  catalog axis nobody has yet needed. Wait for a rejection.
- **Gemini's `Off` is unconfirmed.** A budget of 0 disables thinking, and is
  documented on the series that takes budgets; the series that prefers levels
  accepts a budget only for backwards compatibility, and has no `off` rung.
- **No budget clamp on Gemini.** Anthropic documents that the budget must sit
  below `max_tokens`; Gemini documents no such relationship, so none is
  invented. Revisit the first time a live call disagrees.
- **A Restructured request option is never annotated, by design.** `Report`
  files an annotation only for Degraded, Refused and Compensated, so a caller
  whose rung became a token budget learns it from `report.worst` moving off
  Exact and nowhere else. Annotating Restructured would make the channel mean
  "something was translated" rather than "something was lost" — `Resolver`
  returns it from five places and the mappers record it at two dozen sites, so
  a long session would annotate roughly in proportion to its length, and the
  `reasoning_dropped` counter exists precisely to keep that noise out.

  The pre-request answer is better placed anyway: `provider.profile(model)`
  reports the unit *before* the call. Revisit if a second request option wants
  the same confirmation, at which point there is enough evidence to design a
  path rather than guess at one.
- **Reasoning controls invalidate prompt caching.** Both vendors render the
  value into the prompt, so changing it mid-conversation misses the cache.
  `spec/conformance/determinism_spec.cr` asserts prefix stability for exactly
  this reason; nothing to fix, but the guidance belongs beside it before prompt
  caching arrives.

### A model catalog, keyed independently of protocol

**One axis exists.** `Capability::Catalog` resolves an ambiguous reasoning unit
per model, and it is deliberately the smallest thing that could work: exact
spellings, no patterns, one field narrowed, an optimistic default, and an
explicit override for the deployments whose model name says nothing about the
model.

It passes the test set below — an entry may only resolve `Either` into a unit
the protocol already spelled, so it cannot add a capability or overturn a
refusal — and it follows the precedent vendor narrowing set: reassign one
`Profile` field and let the existing resolver do the work.

The default is optimistic where the rest of this shard is pessimistic, and the
reason is specific rather than a change of heart: **the exception list is closed
and shrinking.** Budget-only models are the legacy ones, every model since takes
a rung, so a stale table fails safe. That argument does not transfer to the
axes below, and reusing it there without checking would be the mistake.

Still open, and the reason this stays in WILL FIX:

- Should the catalog become a layer, or stay a lookup returning a narrowed
  `Profile`? The lookup is right so far, on one axis.
- `ReasoningRetention::CompletedTurns` exists for a requirement keyed on model
  and is still applied by hand. Declared media support has the same problem in
  miniature — both OpenAI profiles list audio media types, but audio support is
  model-gated in practice.
- Per-model *rung* support, if a rejection ever demands it. A second axis on
  the same entry, not a second mechanism.
- **The trap, unchanged**: a preference may only ask for *less* than the
  protocol can carry. One that can *add* capability, or override a refusal, is
  a back door around the capability model.

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

&nbsp;     |Markers                                             |Glue                                    
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

## Lessons that changed how this is built

Not tasks. Recorded because each cost something and each will recur.

### A fixture written by the same hand as the code tests the hand, not the wire

Ollama spells the Chat Completions reasoning field `reasoning`; vLLM and
DeepSeek spell it `reasoning_content`. The reader required the second, so every
Ollama reasoning trace was dropped — silently, with no error and no annotation,
while 218 offline examples stayed green. They stayed green *because* the
fixtures had been written from the same assumption as the reader.

One recording found it. Every protocol here is served by implementations that
disagree with its specification in small ways, and only a transcript is
evidence. Both spellings are now read, as Gemini already read `inlineData` and
`inline_data`.

### An uncapped request is unbounded

A small model with no output cap spent 4,096 tokens reasoning without reaching
an answer, and an earlier run stalled twelve minutes with every later request
queued behind it — Ollama processes serially, so one runaway blocks the rest.
Live requests now always carry a cap.

### A suite that re-records is not a suite that replays

The three tool specs had never once replayed. Every run under wiretap's `:once`
mode re-recorded any transcript that failed to match, so they asserted against a
recording the code under test had made moments earlier — the same shape as the
fixture lesson above, one layer down, and just as green.

The cause was a request body carrying a freshly minted, timestamped call
identifier, which could not digest the same way twice. That was a five-minute
fix. What cost the time was that the failure had been invisible for as long as
anyone kept deleting transcripts to make it go away.

Now: `:none` under CI, `Wiretap.verify!` after every suite, and `RECORD=1` for
the runs where recording is the point. **The run after a re-record is the one
that proves anything.** This matters more, not less, as the Anthropic and Gemini
transcripts arrive, since those cost money to cut and will be re-cut reluctantly.

### Record transcripts; never hand-write them

Both times a transcript was guessed at rather than captured, the guess was wrong
and cost a debugging round. A real server produces the real error body, which is
what the decoder actually has to survive.

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
