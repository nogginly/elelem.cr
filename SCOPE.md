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

**Three classes, not one cause with variations.** Investigated August 2026; the
entry above collapsed them, which is what made the item look buildable.

1. **Pre-request rejection** — quota, rate limit, context window exceeded, bad
   auth. Rejected before generation: 429, 400, 413, no partial content in
   either mode. The session is untouched and this is a plain retry.
   `transmit` already raises. Nothing to repair.
2. **Model-side stop** — `max_tokens`, stop sequence, safety. A complete,
   well-formed 200 with the reason in its own field, identical streaming or
   not. This is the truncation case, and today it is the *only* one that
   reaches repair.
3. **Mid-generation server failure** — and here the two modes diverge sharply.

Without streaming there is no third state. Nothing has reached the wire, so the
server discards the partial generation and returns an HTTP error; the tokens
are gone and there is no partial response to repair. With streaming the outer
status is already committed at 200, so the failure arrives *in band*: an
`error` event in place of the terminal one, or — worse and reportedly common —
the stream simply ending with no terminal event at all.

**Context windows create no new state.** Input too large is rejected up front,
class 1. A model running out of room mid-generation is not a server decision;
it is class 2 under another name.

**The absence is the finding.** A dropped stream carries the "cut short" fact
as the *lack* of a terminal event. There is no vendor field to read, so any
design that *derives* the fact by normalising `provider_metadata` cannot
express it. Whatever holds this must be something the client can **set** from a
transport observation, not only something a response reader parses. That is the
strongest argument for a canonical field on `MPSH::Message` rather than a
lookup over the four existing spellings — and it is an argument that only
appears once streaming is in view, which is why this waits for it.

**Held until streaming lands.** Classes 1 and 2 are already handled or already
fixture-covered; class 3 is unreachable without a streaming seam, and it is the
class that shapes where the fact lives. Building the truncation half now would
mean choosing that home while unable to test the case that constrains it. The
invariant above is what this closes on, and it stays the acceptance test.

**When it resumes, the fixtures cost nothing.** Truncation is recorded already
(the `max_output_tokens: 24` transcript). Ollama's small-context and
fail-when-full flags give a genuine class-1 rejection. A real vendor 400 comes
free from requesting `max_tokens` above a model's ceiling — rejected before
generation, so no output tokens are billed. Class 3 should be *deliberately*
synthetic: a stream cut after three deltas, or an error frame in place of the
terminal event, is a transport shape rather than model output, so a
hand-authored transcript tests our parser rather than our guess about a vendor.
Copy the error envelopes verbatim from provider documentation.

---

## WILL FIX

### Retention governs replay, not display and not storage

Surfaced settling a streaming question, and recorded because the assumption is
natural and wrong. `Capability::ReasoningRetention` is applied in exactly one
place — `Capability::Retention.plan`, called from the four `Mapper#map`
implementations. No exporter consults it. So under `None`, a reply's
`ReasoningBlock` is still exported into the `MPSH::Message`, still handed to the
caller, and still written to disk by the CLI. Only the *next* request omits it.

That is the correct behaviour and the enum's own comment already says so — it
is a playback preference, not a capability. What is missing is anything that
answers the other two questions someone might reasonably think it answers:

- **Display.** Whether reasoning is shown live. Belongs to the consumer, and
  the CLI answers it with `--show-reasoning`, defaulting off
  (`docs/CLI_DESIGN.md`).
- **Storage.** Whether reasoning is retained in the session and archive at all.
  Nothing offers this. A caller who wants reasoning never persisted has to
  strip it from the reply themselves before `session << reply`.

Whether the third one deserves a control is genuinely open, and there is no
evidence yet that anyone wants it. Do not reach for `ReasoningRetention` when
they do: conflating the three axes is the exact failure its comment warns
against, and a fourth `None`-like member that silently meant something else on
each axis would be worse than a new type.

### `max_tokens` vs `max_completion_tokens` is per-deployment, not yet per-model

Confirmed live: `gpt5.4mini` on Azure rejects `max_tokens` outright and wants
`max_completion_tokens`, OpenAI's replacement field for the reasoning-model
line. Ollama's Chat Completions-compatible endpoint has the opposite problem —
`max_completion_tokens` support has been an open, unresolved request against
it for over a year, so defaulting to the new spelling would silently stop
capping output there rather than fail loudly.

Handled for now as an explicit, per-adapter override —
`Wire::MaxTokensField`, threaded through `Provider.for`/`.for_azure` the same
way `reasoning_unit` already is — defaulting to the old spelling everywhere,
stated explicitly for a deployment known to need the new one. Not a
`Capability::Catalog` axis: Catalog matches on model string, and this
shard has no live coverage yet of plain OpenAI direct, only Azure and
Ollama's emulation of the protocol. Building an exact-match list now would be
guessing ahead of evidence this shard doesn't have.

Worth revisiting once there's a second data point beyond Azure — a live
OpenAI-direct spec, or a second Azure deployment on an older, non-reasoning
model that still wants `max_tokens`. At that point this becomes the same
shape as the reasoning-unit catalog: an exact-match table plus the same
deployment-level override for names that carry no model identity.

### Reasoning controls: the unit is keyed on the model

`Profile` gained `reasoning_unit`, `Capability::Catalog` resolves `Either` per
model — see each protocol's own `docs/protocols/*.md` for the spelling.
What remains open is only what a live call can settle:

- **Rungs are model-dependent on the OpenAI protocols too.** `xhigh` and `max`
  serialize happily and may still be rejected by the model behind the endpoint.
  A protocol-level declaration cannot know, and a per-model rung list is a
  catalog axis nobody has yet needed. Wait for a rejection.
- **No budget clamp on Gemini.** Anthropic documents that the budget must sit
  below `max_tokens`; Gemini documents no such relationship, so none is
  invented. Revisit the first time a live call disagrees.

### A model catalog, keyed independently of protocol

`Capability::Catalog` resolves an ambiguous reasoning unit per model — see
its own doc comment for the shape and the reasoning behind the optimistic
default. Still open, and the reason this stays in WILL FIX:

- Should the catalog become a layer, or stay a lookup returning a narrowed
  `Profile`? The lookup is still right on two axes: `SIGNED_TOOL_CALLS`
  arrived exactly as this section predicted — a second axis on the same
  entry, not a second mechanism — and needed no structural change to land.
  The one thing it did change is that "why the default is optimistic" is now
  a per-axis argument rather than a catalog-wide one, and the two axes reach
  the same default by opposite reasoning. A third axis should state its own
  rather than inherit either.
- `ReasoningRetention::CompletedTurns` exists for a requirement keyed on model
  and is still applied by hand. Declared media support has the same problem in
  miniature — both OpenAI profiles list audio media types, but audio support is
  model-gated in practice.
- Per-model *rung* support, if a rejection ever demands it. A second axis on
  the same entry, not a second mechanism.

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
