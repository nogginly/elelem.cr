# Handoff

For starting a fresh session on this shard. Deliberately short: almost
everything worth knowing is already in the repository, and this file points
rather than restates.

## Read in this order

Document                    |Why                                                                            
----------------------------|-------------------------------------------------------------------------------
`docs/MPSH_SPECIFICATION.md`|Authoritative. §8a records what the checkpoint established and what it did not 
`SCOPE.md`                  |The worklist. Every open question, each with the trap that makes it awkward    
`DEVELOPMENT.md`            |Layering, conventions, how an agent uses the shard, how to add a protocol      
`docs/protocols/*.md`       |One per protocol: declared capabilities, limits, the bugs each produced        
`docs/servers/*.md`         |One per server: what it serves, where it diverges, what a green run misses     
`docs/CLI_DESIGN.md`        |The `elelem` executable: config, session storage, verb grammar, what's deferred

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

**Two things now exist beyond the live protocol layer itself.**
`MPSH::Archive` (`src/elelem/mpsh/archive.cr`) round-trips a `Session` to
JSON and back — the piece the whole portable-history pitch was missing,
since nothing previously turned a `Session` into anything that could
survive past one process. Tested against the full MPSH fixture set through
`Conformance.compare`, zero divergence required (`spec/mpsh/archive_spec.cr`)
— a stricter bar than any protocol gets, since this isn't a capability
adaptation and has no matrix to excuse a difference.

And `elelem` now ships as more than a library: `start`/`continue`
(`src/elelem_cli/`, entrypoint `src/elelem_cli.cr`) build one
`elelem.yaml`-configured deployment into a session snapshot per turn.
`continue` remembers which deployment last answered a given session by
reading it off the snapshot's own filename, rather than falling back to a
global config default — `docs/CLI_DESIGN.md` records that a `default_deployment`
config key was tried first and rejected, not merely skipped, because it
answered "what does the config prefer" when what `continue` needs is "what
was this conversation already having." Live-tested in-process against a
sandboxed config and session store, recorded against Ollama
(`spec/elelem_cli/commands/`).

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

All four protocols, a fifth deployment (Azure), `Archive`, and a first-party
CLI are now built and live-tested. Two separate worklists, not one:

- **Protocol side** — `SCOPE.md`'s `MUST FIX`: a Gemini tool call carrying a
  foreign or missing thought signature, and interrupted-turn session repair.
  Both real, both confirmed live-reproducible, neither built yet.
- **CLI side** — `docs/CLI_DESIGN.md`'s own *Deliberately deferred, not
  forgotten*: tool support, streaming, session-inspection verbs
  (`list`/`show`). None chosen or sequenced yet.

### On Ollama

What it serves, where it diverges, and what a green run there does *not* prove:
`docs/servers/OLLAMA.md`. Read it before treating any live green as having
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
- **A test's own sandboxing can break the thing it's testing around it.**
  Two `elelem_cli` specs `Dir.cd`'d into a temp directory to sandbox
  `Sessions`/`Config`'s filesystem resolution, and silently broke Wiretap's
  own relative transcript path doing it — Wiretap resolves that path against
  the real process CWD too. Every spec passed, because the live call to
  Ollama still succeeded; the recordings just never landed anywhere real,
  and the sandbox's own cleanup deleted whatever had been written into it
  before anyone noticed. Fixed by giving `Sessions`/`Config` an explicit
  env-var override (`$ELELEM_HOME`, `$ELELEM_CONFIG`) instead of moving the
  process's CWD at all: sandbox exactly what the code under test reads,
  never anything downstream of it that happens to read the same ambient
  state.
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
