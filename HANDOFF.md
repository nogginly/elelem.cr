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
`README.md`                 |The front door: what the shard is for, and the handoff in twenty lines         

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
identity. It now carries **two axes**: the reasoning unit two protocols spell
differently and reject being handed both, and whether a model authenticates
its own tool calls. Both narrow the same `Profile` per call. Read *A model
catalog* in `SCOPE.md` before adding a third — the two reach the same
optimistic default by *opposite* arguments, and neither generalises.

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
calls. **Now closed too:** a `ToolCallBlock` handed to this protocol from
another has no signature to offer, and `Resolver` checks for that ahead of
`own?`, reporting `Degraded` rather than sending a request that cannot
succeed. Keyed on the model via `Catalog`, not declared on the protocol,
because the requirement arrived with Gemini 3 and the 2.5 series lacks it —
`docs/protocols/GEMINI.md` records why the protocol-wide version was written
first and rejected.

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

**Carrier deferral is now extracted**, ahead of a fifth protocol as its own
entry asked. The rule — buffer lifted content, flush before anything that is
not a tool result, recognise the carrier again on the way back — lived in three
mappers and three exporters, written differently each time and wrong once. It
is now `Capability::Carrier` (`src/elelem/capability/carrier.cr`), generic over
the wire part type so it cannot know what a protocol is, with the marker as one
constant rather than three that had to stay byte-identical forever. A protocol
keeps only the message shape it spells a carrier with, plus any precondition of
its own, which is why `carrier?` takes an `eligible` flag rather than letting
callers guard ahead of it: both preconditions sat *below* the synthetic check
and hoisting them would have changed the answer. Unit-tested directly for the
first time (`spec/capability/carrier_spec.cr`) — the old arrangement could only
test each copy through its own protocol's fixtures, which is exactly how one
copy stayed wrong. That spec immediately earned itself: it caught an
inherited infelicity in `absorb`, which counted markers but filled the first
one still open, so a part the target could not express left the surviving
marker trailing at the end of the result instead of standing where it belonged.
Placement is positional now, and `SCOPE.md` is one item shorter than it was
rather than level.

**Two things now exist beyond the live protocol layer itself.**
`MPSH::Archive` (`src/elelem/mpsh/archive.cr`) round-trips a `Session` to
JSON and back — the piece the whole portable-history pitch was missing,
since nothing previously turned a `Session` into anything that could
survive past one process. Tested against the full MPSH fixture set through
`Conformance.compare`, zero divergence required (`spec/mpsh/archive_spec.cr`)
— a stricter bar than any protocol gets, since this isn't a capability
adaptation and has no matrix to excuse a difference.

And `elelem` now ships as more than a library. Verbs: `start` (with `--id`),
`continue`, `list`, `show` (`--snapshots`, `--json`). `continue` remembers
which deployment last answered a session by reading it off the snapshot's own
filename rather than a config default — `docs/CLI_DESIGN.md` records that a
`default_deployment` key was tried first and rejected, not merely skipped,
because it answered "what does the config prefer" when what `continue` needs
is "what was this conversation already having."

`elelem.yaml` is two tables: a **server** is a url plus the protocol it
speaks, a **deployment** names one model on one server. Deployments may also
carry `reasoning` and `reasoning_retention`, which settled the question
`Capability::Retention` had parked — those are soft preferences read off a
model card, not hard protocol facts, so they live in config rather than in
`Catalog`, and adding a model needs no release.

`Progress` shows a spinner and elapsed seconds while a request is in flight,
on stderr and only when stderr is a terminal. It is a fiber and a clock, not
an event queue; `docs/CLI_DESIGN.md` records what streaming will want from it,
which is why `#start`/`#stop` are public and `#label` is mutable.

Live-tested in-process against a sandboxed config and session store, recorded
against Ollama (`spec/elelem_cli/commands/`). `spec/support/cli_output.cr`
keeps a spec run quiet.

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

`SCOPE.md`'s `MUST FIX` is down to **one item** — interrupted-turn session
repair — and as of August 2026 it is **held until streaming lands**. Read its
entry before reopening it: the investigation is recorded there and the
conclusion is not "not yet worth doing" but "not yet decidable".

The short version. Interruption is three classes, not one cause with
variations. Pre-request rejections and model-side stops are already handled or
already fixture-covered. The third — a failure part-way through generation —
does not exist without streaming, because nothing has reached the wire and the
server simply discards the partial and returns an error. With streaming it
exists in a form that carries no vendor field at all: a stream that ends
without its terminal event. That absence is what constrains where the portable
"this turn was cut short" fact must live — it has to be settable from a
transport observation, not merely parsed from a response — and choosing that
home while unable to test the case that constrains it is how the wrong home
gets chosen.

So the design fork this section used to describe is *answered in outline* and
deliberately not built: a canonical `Ending` on `MPSH::Message`, additive in
`Archive`, with repair as a pure-MPSH `MPSH::Repair`. `SCOPE.md` has the
reasoning and the fixture plan, which costs nothing when it resumes.

Session pruning and deletion, which was the unblocked item here, is **built**:
`elelem prune SESSID --keep N` and `elelem delete SESSID`, with the design
record in `docs/CLI_DESIGN.md`'s *Removing things*. Neither touches a network,
so both are fully spec-covered without a recording.

What remains on `docs/CLI_DESIGN.md`'s *Deliberately deferred, not forgotten*
is tool support (open question: text-only first?) and streaming itself (the
library has no streaming seam). Tool support is downstream of interrupted-turn
repair, since repair is what shapes the turn loop — which now puts both of
them behind streaming. **Streaming is the next real piece of work**, and it
has stopped being merely additive: two other items are queued behind it.

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
- **A guard at the right seam still needs a non-raising twin.** Session id
  validation went into `Sessions.path_for` — correct, since an id becomes
  dangerous exactly when it becomes a path, and no future verb can forget it
  there. But `list` enumerates the folder through the same method, so one
  `.DS_Store` took the whole listing down on first real use. A validator for
  *input* and a predicate for *enumeration* are different questions;
  `validate_id` and `valid_id?` are both needed.
- **Crystal is not Ruby, in three places this shard has already hit.** `out` is
  a reserved word and cannot name a property or a local. There is no trailing
  `while` modifier, only trailing `if`/`unless`. And a variable captured by a
  block — an `OptionParser` handler, typically — will not narrow out of `T?`
  however it is tested; copy it to a fresh local first.
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
