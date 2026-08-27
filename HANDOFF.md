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

Three of the four protocols have been exercised against Ollama's compatible
port — Chat Completions, Responses, and an Anthropic-compatible endpoint from
one port. `spec/live/ollama_spec.cr` records a session answered by one
protocol and continued on another, including a tool call minted on one and
replayed on the next. But a compatibility port proves the shape is accepted,
not that the vendor whose protocol it imitates would accept it. The real
Anthropic endpoint has now also been called directly, and settled two things
Ollama structurally could not: a `thinking` block with no signature is a
genuine 400 (`spec/transcripts/anthropic_thinking_no_signature.json`), and a
real signature genuinely replays on the next turn while the budget path and
its 1,024-token floor are accepted as documented
(`spec/transcripts/anthropic_thinking_signature_replay.json`). Detail in
`docs/protocols/ANTHROPIC.md`. All transcripts are committed under
`spec/transcripts/` and replay offline, so the suite needs no server.

Request options are complete: tool declarations, output caps and reasoning
controls, the last of which introduced `Capability::Catalog` — the fourth
identity, opened one axis wide. Two protocols spell reasoning control in two
units and reject being handed both, and which unit a deployment wants is a fact
about the *model*, so the catalog resolves it per call by narrowing the same
`Profile`. Read *A model catalog* in `SCOPE.md` before adding a second axis to
it.

**Gemini is now executed, the last of the four.** Ollama never served it, so
unlike Anthropic this had no compatibility port to have already exercised the
wire shape — first contact and the falsifying tests happened in the same pass.
Found and fixed along the way: Gemini 3 requires a `thoughtSignature` on
`functionCall` parts, which `elelem` had nowhere to carry, and
`gemini-3.1-pro-preview` actively rejects a zero thinking budget rather than
silently ignoring it, both now handled
(`spec/live/gemini_spec.cr`, `docs/protocols/GEMINI.md`). Confirmed and closed:
the reasoning-off budget genuinely disables thinking on Flash, and
`reasoning_signature_required` correctly stays `false` here — Anthropic's fix
does not generalize to this protocol's plain-text reasoning, only to its tool
calls. Still open: a `ToolCallBlock` handed to this protocol from another one
has no signature to offer, and nothing yet checks for that before sending
(`SCOPE.md`).

Recording practice, and why re-recording is more disruptive than it looks:
*Live specs* in `DEVELOPMENT.md`.

**Azure OpenAI is now live too, and it amended the design as expected.**
`Adapter` assumed path and auth were protocol facts; Azure proved them
protocol-*plus*-deployment facts — `Provider.for_azure`,
`AzureChatCompletionsAdapter`, `AzureResponsesAdapter`. The two protocols
disagree with each other on where the deployment lives (path segment for Chat
Completions, body-only for Responses) badly enough that Microsoft's own
documentation disagreed with itself; settled against a live deployment's own
portal rather than guessed. First contact also found a live gap unrelated to
the amendment itself: a reasoning-capable deployment rejects `max_tokens`
outright and wants `max_completion_tokens`, handled as an explicit
per-deployment override (`Wire::MaxTokensField`) rather than a model catalog,
since Azure deployment names carry no model identity a catalog could match
against — same shape as `reasoning_unit`'s existing override, and the same
justification. Detail in `docs/servers/AZURE.md` and
`docs/protocols/CHAT_COMPLETIONS.md`'s own *Live finding* sections.

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

All four protocols and a fifth deployment (Azure, atop Chat Completions and
Responses) are now exercised live. `SCOPE.md`'s `MUST FIX` section is what's
left and unsequenced: a Gemini tool call carrying a foreign or missing thought
signature, and interrupted-turn session repair are both real, both confirmed
live-reproducible, and neither built yet.

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
- **`Restructured` is not a bug waiting to be found.** Twice while getting
  Azure live, a `report.worst.should eq Exact` failed and looked like a new
  protocol gap — it was the test both times, not the mapper. Chat Completions
  and Responses both report `Restructured` on *any* session carrying a system
  prompt, unconditionally, by design: MPSH holds the prompt as a session
  field, and turning it into any wire form is a restructuring of MPSH's own
  shape regardless of whether the destination protocol calls that placement
  native. Pinned already in `spec/conformance/layer_spec.cr`; check there —
  or the protocol's own doc — before assuming a Restructured result is new
  information.
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
- **A settled "won't do" is a decision**, not an oversight to helpfully
  correct. `DEVELOPMENT.md`'s "No `UNSUPPORTED.md`" and this file's *Deferred,
  and staying deferred*, below, are both this.
- Diagrams are Mermaid, fenced inline in Markdown so they render on GitHub.
- Nothing under `mpsh/` may know that HTTP or any provider exists, and no
  canonical type may serialize into a request body.

## Deferred, and staying deferred

Session tree, branching, scatter/gather, provider bindings, stateful handles,
streaming, tool execution, prompt caching, compaction. See
`docs/IMPLEMENTATION_PLAN.md` §7 and `docs/PSR_BRANCHING_AND_SCATTER_GATHER.md`,
which carries a deferred-status banner for exactly this reason.
