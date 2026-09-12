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

Empty. Interrupted-turn repair — the last entry here — is built: `MPSH::Ending`
on the message, `MPSH::Repair` over the session, and the invariant it closes on
(*no tool call without its result*) asserted directly rather than described.
`docs/MPSH_SPECIFICATION.md` §3a carries the argument now, which is where it
belongs: it is a statement about the format, not an outstanding question.

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
