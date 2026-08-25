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

---

## WILL FIX

### Reasoning controls: the unit is keyed on the model

`Profile` gained `reasoning_unit`, `Capability::Catalog` resolves `Either` per
model — see each protocol's own `docs/protocols/*.md` for the spelling.
What remains open is only what a live call can settle:

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

### A model catalog, keyed independently of protocol

`Capability::Catalog` resolves an ambiguous reasoning unit per model — see
its own doc comment for the shape and the reasoning behind the optimistic
default. Still open, and the reason this stays in WILL FIX:

- Should the catalog become a layer, or stay a lookup returning a narrowed
  `Profile`? The lookup is right so far, on one axis.
- `ReasoningRetention::CompletedTurns` exists for a requirement keyed on model
  and is still applied by hand. Declared media support has the same problem in
  miniature — both OpenAI profiles list audio media types, but audio support is
  model-gated in practice.
- Per-model *rung* support, if a rejection ever demands it. A second axis on
  the same entry, not a second mechanism.

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

### README.md

Was deferred to "when Phase 2 passes." Phase 3 is done now — the deferral
already lapsed, this note just hadn't caught up. The quick-start example is
the handoff — start on Chat Completions, export, resume on Responses — and
that example can be written honestly now. Not written yet; do it next, not
"later."

---

## Explicitly not doing

### No `UNSUPPORTED.md`

The capability matrix is that document, in a better form: derived from each
protocol's declared `Profile` rather than written by hand, expressed per media
type rather than per feature, and queryable by callers at runtime. A prose
version would be a second statement of the same fact and would drift within a
single phase.
