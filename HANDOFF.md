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

`elelem.yaml` is two tables and a block. A **server** is a url plus the
protocol it speaks, a **deployment** names one model on one server, and
**`defaults`** is how the CLI itself behaves — `streaming` and
`show_reasoning`, both false, each pairing with a flag of the same name. That
pairing is the rule the block is held to: a key with no flag behind it is how a
section like this becomes a junk drawer.

The CLI applies `MPSH::Repair` in two places. On append, in `Query`, the
snapshot gets the repaired message and the screen gets what actually arrived.
On load, in `continue`, because a snapshot may have been written by a build
predating repair or by something else entirely — the format being portable is
the point — and it says so on stderr rather than quietly rewriting a file
someone may be reasoning about. Deployments may also
carry `reasoning` and `reasoning_retention`, which settled the question
`Capability::Retention` had parked — those are soft preferences read off a
model card, not hard protocol facts, so they live in config rather than in
`Catalog`, and adding a model needs no release.

`Progress` shows a spinner and elapsed seconds while a request is in flight,
on stderr and only when stderr is a terminal. It is a fiber and a clock, not
an event queue. Its own doc comment predicted that streaming would put it up
and down repeatedly within one turn rather than retire it, which is why
`#start`/`#stop` are public and `#label` is mutable — and that is exactly how
the streamed turn uses it, relabelled to name the tool being called.

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

**Next is tool execution**, the last entry on `docs/CLI_DESIGN.md`'s
*Deliberately deferred, not forgotten* and the only one left. It is genuinely
open rather than merely unbuilt: whether `start`/`continue` take tool
declarations in v1 or ship text-only first is unanswered, the doc leans
text-only, and `Client#send`'s turn loop is caller-owned by design so the CLI
has to decide what *it* does. It is also what finally gives `CLI_DESIGN.md`'s
*Printed bytes precede repair* something to bite on — see below.

Two smaller open items, both recorded in `SCOPE.md`: `Ending::Interrupted` has
no end-to-end spec, and there is no recorded spec of a streamed `start` or
`continue`. The first is free; the second costs a recording.

**`SCOPE.md`'s `MUST FIX` is empty.** Interrupted-turn repair, the last entry
in it, is built, and the argument that used to live there now lives in
`docs/MPSH_SPECIFICATION.md` §3a — where it belongs, being a statement about
the format rather than an open question.

`MPSH::Ending` is a settable field on `MPSH::Message`: `Complete`, `Truncated`,
`Stopped`, `Interrupted`. The four exporters normalise their own stop reason
onto it and keep the verbatim copy; `Client` sets the two facts only it knows.
`MPSH::Repair` is pure MPSH — drop the calls, keep any text — with the
invariant expressed as `Repair.sendable?` rather than described.

Three things about it are worth knowing before touching it, because each was
checked and none is obvious:

- **The field is outside round-trip identity, deliberately**, on
  `text_fallback`'s terms. No protocol has a *request*-side field meaning "this
  message was cut short", so `Conformance.compare` does not check it and says
  so in writing. Adding it there would report a permanent divergence reading as
  a mapper bug.
- **Which means the archive's own gate does not reach it.** `archive_spec.cr`
  claims zero divergence for every fixture and enforces it through
  `Conformance.compare` — which walks only what a wire can carry, and is
  equally silent on `Provenance` and annotations. `Archive` could stop writing
  `ending` entirely and every fixture would still pass. Covered by explicit
  examples instead, the same way annotations already were.
- **`Client` no longer raises on a cut stream.** It returns the partial reply
  carrying `Ending::Interrupted`; the raise was a placeholder chosen when there
  was nowhere to record *why* a reply was partial. An in-band error frame still
  raises `Protocol::StreamError` from the assembler that read it — that is a
  failure the server described, this is one it never mentioned.

What is left is coverage, not design: `Ending::Interrupted` is the one member
with no end-to-end spec, since no transcript ends without its terminal frame.
`SCOPE.md`'s remaining entry has the fixture plan.

Session pruning and deletion, which was the unblocked item here, is **built**:
`elelem prune SESSID --keep N` and `elelem delete SESSID`, with the design
record in `docs/CLI_DESIGN.md`'s *Removing things*. Neither touches a network,
so both are fully spec-covered without a recording.

**The CLI half of streaming is built.** `Display` resolves what the terminal
does, `Query` runs the streamed turn, `Output` prints it. Precedence is flag,
then `defaults.streaming`, then a tty test on **stdout** — with the tty test a
floor that configuration does not lift, and `--stream` the one thing that goes
through it. Reasoning goes to stderr in grey behind `defaults.show_reasoning`
and `--show-reasoning`, off by default.

Three things in it were checked rather than assumed:

- **Whether a reply was streamed is read off `report.streamed?`, never off the
  request.** A protocol with no streaming seam falls back to one body inside
  `Client#send` having printed nothing, so asking the request would print
  nothing at all on exactly those providers.
- **`Progress` had a latent bug this was the first code to reach.** Its stop
  channels were built once in `initialize`, invisible while `while_waiting` was
  the only door; put the indicator up a second time and the new fiber found a
  closed channel and drew nothing, silently. Channels are made per `start` now.
- **`CLI_DESIGN.md`'s *Printed bytes precede repair* guards a hazard that does
  not exist yet.** Repair removes tool calls; `Output.reply` prints text blocks
  only; so a streamed run and its saved session currently agree exactly and
  anyone looking for the discrepancy will not find it. It arrives with tool
  execution, when the terminal starts narrating calls as they materialise. The
  rule is stated there as a property — *the terminal is the only surface
  permitted to disagree with the archive* — rather than as a guess about who is
  watching.

Streaming was built **one protocol at a time** — read
`docs/STREAMING_DESIGN.md` before touching it. The short version: frames
assemble into each protocol's own `Wire::Response` and then take the *existing*
`export_reply(Wire::Response)`, so there is exactly one translation path and a
streamed reply is the same `MPSH::Message` as a non-streamed one by
construction.

**All four slices are done. Streaming is built for the library.** What
exists now:

- `Elelem::Streaming` — `Sse` framing shared by all four protocols, a closed
  five-variant `Event` union, `Turn` (the cooperative stop handle), and the
  abstract `Assembler`.
- `Server#stream`, and `Protocol::StreamError` beside `MalformedResponseError`.
- `Client#send` with a second overload taking `|event, turn|`. **Passing a
  block is the request to stream**; there is no flag. Adapters opt in by
  overriding `Adapter#prepare_stream`, which returns `nil` by default, and
  `Report#streamed` says which way a turn actually went.
- An assembler for each of the four protocols — `Responses`, `Gemini`,
  `Anthropic`, `ChatCompletions` — each with offline and live specs.
- `Adapter#stream_path`, defaulting to `path`. Gemini is the only protocol
  where streaming is a different method on the URL rather than a flag in the
  body, and `alt=sse` is required or the endpoint streams a chunked JSON array
  instead of server-sent events.

**The rule every remaining assembler follows: never stitch anything whose
partial form is invalid.** Text concatenates — a prefix is a legitimate short
answer. A tool call does not: half an arguments blob cannot be dispatched, so a
call still arriving when the stream ended must not appear in the reply.

Both halves of that were learned rather than designed. Responses first called
for keeping only the terminal frame, which is trivial and wrong — the whole
reply lives in that frame, so `Turn#stop` would return nothing. Gemini then
broke the replacement wording (*assemble from complete units*) by emitting no
finished units at all. `docs/STREAMING_DESIGN.md` records both corrections;
expect Anthropic and Chat Completions to test the rule again rather than to
fit it quietly.

**Streaming is proved against vendors, not only against Ollama.** That turned
out to matter: recording against Azure and Anthropic found a bug Ollama had
been hiding — every `Usage.parse` mishandled a `"usage": null` chunk, which
Azure and OpenAI send and Ollama omits — and confirmed the one thing only a
vendor could confirm, that a streamed Anthropic `signature_delta` survives and
is accepted when replayed. The general lesson is in `docs/servers/OLLAMA.md`:
this server is *more* forgiving than the endpoints it imitates, and offline
fixtures cut from its transcripts inherit that blind spot. Gemini's streamed
`thoughtSignature` is still unproven on replay and is the one gap left.

**Interrupted-turn repair is built on top of it** — see *Next* above. Two
things the streaming build had already settled did most of the work: a stopped
turn and a cut turn are indistinguishable to an assembler, so the fact has to
be set by the layer that knows; and every assembler already refuses to emit a
tool call it cannot vouch for, so "drop the calls, keep any text" was already
true for a cut stream in all four protocols before repair existed.

Both halves of streaming are now built, library and CLI. Tool execution is what
sits behind them, and is no longer blocked by anything.

**How the rule was arrived at matters more than the rule.** It was rewritten
twice under contact — first from "keep the terminal frame", then from
"assemble from complete units" — and each rewrite came from a protocol
refusing to fit. Expect the same of anything added later rather than assuming
the current phrasing is final.

**Two traps worth knowing before touching `Server#stream`.** Nothing within its
reach may `yield`: the block reaches `HTTP::Client#exec(request, &)`, which
Wiretap redefines with a *captured* block, and `yield` is illegal inside one.
Relatedly, it calls `exec` directly rather than `post` — `post`'s block form
routes through a stdlib overload that yields, which cannot compile at all while
Wiretap is loaded. That is a latent Wiretap bug affecting any consumer calling
a verb with a block; it has not been reported upstream yet.

Wiretap does record and replay SSE, but it buffers the whole body before
handing it on, so **no spec here exercises incremental arrival** — only frame
vocabulary and assembly.

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
