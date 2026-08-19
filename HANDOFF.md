# Handoff

For starting a fresh session on this shard. Deliberately short: almost
everything worth knowing is already in the repository, and this file points
rather than restates.

## Read in this order

Document                    |Why                                                                           
----------------------------|------------------------------------------------------------------------------
`docs/MPSH_SPECIFICATION.md`|Authoritative. §8a records what the checkpoint established and what it did not
`SCOPE.md`                  |The worklist. Every open question, each with the trap that makes it awkward   
`DEVELOPMENT.md`            |Layering, conventions, how an agent uses the shard, how to add a protocol     
`docs/protocols/*.md`       |One per protocol: declared capabilities, limits, the bugs each produced       

Where this file and `docs/MPSH_SPECIFICATION.md` disagree, the specification
wins.

## State

Phases 0–2 and the checkpoint are complete. Four protocols — Chat Completions,
Responses, Anthropic, Gemini — each with a mapper, an exporter and a shared
structural conformance suite. 218 examples, entirely offline: no key, no model,
no network, no HTTP object constructed. Zero runtime dependencies.

Seven of nine acceptance criteria are met. Outstanding: a live handoff
(criterion 8), and confirming `shards.yml` still has no runtime dependencies
(criterion 9).

Anthropic and Gemini are **structurally verified but unexecuted**, which is the
checkpoint working as designed — keys gate execution, not mapping.

## Next: the path to a live handoff

Three pieces, in order. Each is a `MUST FIX` in `SCOPE.md` with fuller detail.

1. **Response-shaped export.** Exporters currently handle *requests*, which is
   what round-trip conformance needs. A live call returns a different shape per
   protocol — `choices[0].message`, `output[]` items, Anthropic's `content[]`.
   Mostly a second entry point onto existing block-building, not new
   translation.
2. **A minimal client.** `HTTP::Client` and nothing else. No retries, no
   streaming, no tool dispatch. This is where the third identity gets a type: a
   provider is an endpoint plus a protocol plus available models. API shape is
   settled — see `DEVELOPMENT.md`, *How an agent uses this shard*.
3. **The Ollama run.** The first thing in this project to touch a network.

### On Ollama, and what it will not prove

Ollama serves Chat Completions, Responses *and* an Anthropic-compatible
protocol from one endpoint, so a three-way handoff on one local model is
possible with no API spend. That is a far stronger portability demonstration
than the OpenAI pair, because the Anthropic leg genuinely reshapes the request.

But a compatibility layer proves the **shape is accepted**, not that Anthropic
accepts it, and the difference falls exactly where the open questions are:

- Ollama has no thinking signature to demand, so a `thinking` block without one
  will pass. The signature entry in `SCOPE.md` stays open regardless.
- Compatibility layers are permissive. Alternation, first-user and `max_tokens`
  may be accepted where the real endpoint rejects — the same asymmetry already
  seen between Azure and Ollama on tool-result ordering.
- A non-Claude model behind an Anthropic-shaped API does not inherit Claude's
  capabilities.

Write that distinction into the Ollama work so a green run is not later read as
having closed items it never touched.

## How to work on this

- **Read declarations, not fixture names.** Twice, assertions were written from
  the general story rather than from a protocol's declared `Profile`, and were
  wrong both times. `unsupported_media_type` is *exact* on Anthropic, because
  WEBP is accepted there.
- **Corrections cluster in the capability model, not the format.** Three came
  from declaring profiles and round-tripping fixtures; all three changed the
  capability model. Gemini, the protocol most likely to break MPSH, changed only
  mapper code.
- **A green suite is narrower than it looks.** Compilation proves types line up.
  Structural conformance proves shapes. Neither says anything about request-time
  behaviour, and three known uncertainties are recorded in `SCOPE.md`.
- **`SCOPE.md` "Explicitly not doing" is a decision**, not an oversight to
  helpfully correct.
- Diagrams are Mermaid, fenced inline in Markdown so they render on GitHub.
- Nothing under `mpsh/` may know that HTTP or any provider exists, and no
  canonical type may serialize into a request body.

## Deferred, and staying deferred

Session tree, branching, scatter/gather, provider bindings, stateful handles,
streaming, tool execution, prompt caching, compaction. See
`docs/IMPLEMENTATION_PLAN.md` §7 and `docs/PSR_BRANCHING_AND_SCATTER_GATHER.md`,
which carries a deferred-status banner for exactly this reason.
