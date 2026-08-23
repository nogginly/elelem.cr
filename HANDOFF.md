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
`docs/servers/*.md`         |One per server: what it serves, where it diverges, what a green run misses    

Where this file and `docs/MPSH_SPECIFICATION.md` disagree, the specification
wins.

## State

Phase 3 is complete: **the live handoff works.** Four protocols — Chat
Completions, Responses, Anthropic, Gemini — each with a mapper, an exporter, a
response reader, and a wire request that can declare tools and cap output.
Zero runtime dependencies; `wiretap` is development-only.

Three of the four protocols have been exercised against a real server. Ollama
serves Chat Completions, Responses and an Anthropic-compatible endpoint from
one port, and `spec/live/ollama_spec.cr` records a session answered by one
protocol and continued on another, including a tool call minted on one and
replayed on the next. Transcripts are committed under `spec/transcripts/` and
replay offline, so the suite needs no server.

Request options are complete: tool declarations, output caps and reasoning
controls, the last of which introduced `Capability::Catalog` — the fourth
identity, opened one axis wide. Two protocols spell reasoning control in two
units and reject being handed both, and which unit a deployment wants is a fact
about the *model*, so the catalog resolves it per call by narrowing the same
`Profile`. Read *A model catalog* in `SCOPE.md` before adding a second axis to
it.

**Gemini has never been executed.** Ollama does not serve it, so that mapper
remains structurally verified and unrun — the checkpoint working as designed.

Recording practice, and why re-recording is more disruptive than it looks:
*Live specs* in `DEVELOPMENT.md`.

## The live layer

Built and described in `DEVELOPMENT.md` — *Layering*, *Three identities, kept
apart*, and *Live specs*. The short version: `Server` is a deployment,
`Provider` is a server speaking one protocol plus its vendor claim, `Adapter`
holds the only endpoint knowledge, `Client#send` performs one exchange and
returns `(MPSH::Message, Capability::Report)`.

The one rule worth repeating here because breaking it is silent: vendor
narrowing is **one-directional**. A provider may declare that a deployment
honours *less* than its protocol allows, never more.

## Next

1. **Anthropic live, reasoning numbers.** The narrowing default is settled: a
   real 400 confirmed a `thinking` block requires a signature, `Resolver`
   now checks for one before `own?` ever gets asked, and the fix is covered
   offline in `spec/conformance/anthropic_spec.cr` — nothing further needs the
   network to prove it. See `docs/protocols/ANTHROPIC.md`.

   What that recording did not settle: whether `Protocol::Anthropic::REASONING_BUDGETS`
   and the budget clamp behave as the documentation says, and whether the
   own-vendor signature-replay path actually works end to end rather than
   merely being unrejected. `Reasoning::Effort` against a budget-only model,
   two turns, is the next recording — still needs a paid call.
2. **Gemini live.** The only live coverage that protocol will get — and the
   only way to confirm that a budget of 0 disables thinking on the series that
   prefers levels, which the mapper currently assumes.
4. **Azure will amend the design.** It speaks Chat Completions but embeds a
   deployment name and `api-version` in the path and authenticates with
   `api-key`, not `Bearer`. `Adapter` currently assumes path and auth are
   *protocol* facts; Azure proves they are protocol-plus-deployment facts. Do
   it last, so the amendment lands against three working examples.

### On Ollama

What it serves, where it diverges, and what a green run there does *not* prove:
`docs/servers/ollama.md`. Read it before treating any live green as having
closed an open question — Ollama has no signature to validate, which is
exactly why the narrowing default needed a real Anthropic recording rather
than a green run here to settle it. See `docs/protocols/ANTHROPIC.md`.

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
  behaviour.
- **A fixture written by the same hand as the code tests the hand, not the
  wire.** One recording found a bug that hundreds of green offline examples
  could not. See *Live specs* in `DEVELOPMENT.md` for the rules that follow
  from it.
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
