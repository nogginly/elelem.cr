# CLI Design

**Status**: `src/elelem_cli/` and `src/elelem_cli.cr` now exist — `start`,
`continue`, `list` and `show` are built. What follows is still the record of
*why*, kept current rather than archived, so a decision made once in
conversation doesn't get silently re-made differently later.

**Scope**: The `elelem` executable — config resolution, deployment naming,
session storage, and the verb grammar. Does not cover the `Archive` format
itself (`session.cr`'s own comment, `DEVELOPMENT.md` rule 2) or the session
tree/branching work `MPSH_SPECIFICATION.md` explicitly defers.

---

## What this is, and what it deliberately is not

A non-interactive, single-shot CLI: one invocation, one call to a provider,
one saved result. Not a REPL, not an agent framework, not a place for the
deferred session-tree/scatter-gather work to land — if that ever wants a
sentence-like grammar, it's a different, later tool built *on* `elelem`, not
a reason to complicate this one now.

## Ships inside this shard, not a separate project

`elelem` is both a library and a first-party CLI. `shard.yml` gains an
`executables:` entry; no new `dependencies:` entry, because both pieces the
CLI needs — YAML parsing, argument parsing — are already in Crystal's
stdlib. The zero-runtime-dependency posture stays true of what
`require "elelem"` pulls in.

```
src/elelem/             # the library — unchanged by any of this
  mpsh/archive.cr          # a library concern: Session ↔ JSON,
                           # independent of the CLI existing at all
src/elelem.cr

src/elelem_cli/         # CLI-only: config, session-folder naming, commands
  config.cr
  sessions.cr
  query.cr
  output.cr
  commands/
    start.cr
    continue.cr
src/elelem_cli.cr        # thin entrypoint: verb dispatch, error handling, done

examples/                # small, standalone, one file each, no CLI machinery
```

Reasoning: someone who `require`s `elelem` to build their own thing should
never transitively get config-file parsing or session-folder conventions
they didn't ask for. `elelem_cli/` as a sibling directory to `elelem/` —
rather than nested inside it — makes that boundary a fact about the
filesystem, not just a convention within a shared tree: `require "elelem"`
touches zero files under `elelem_cli/`, provably, not just by agreement.
Everything under `elelem_cli/` still lives in the `Elelem::Cli` namespace,
though — this isn't a second product, it's the same one wearing a different
front door, and the module name says so even though the directory doesn't
have to.

## Verbs: `start`, `continue`

```
elelem start anthropic "What color is the sky on Mars?"    → SESSID
elelem continue SESSID "Why is that?"
elelem continue SESSID "Why is that?" --on azure-mini
```

Considered and rejected: `ask` (with `--continue` as a flag), and a
SQL-like "everything after `elelem` is one query" grammar.

- **`start`/`continue` over `ask`/`--continue`.** Continuing is a first-class
  operation on a conversation, not a modifier on asking — it deserves its own
  verb. `start` was chosen over `new` because it pairs with `continue` on the
  same axis (two things you can do to a conversation over time), where `new`
  pulls toward a noun-first grammar (`session new`) that isn't the one this
  tool uses anywhere else.
- **Verb-first over a sentence grammar.** SQL's "read the whole thing as one
  query" earns its complexity because SQL queries are genuinely
  compositional — joins, subqueries, an open-ended space. `elelem`'s
  operations are a small, fixed, enumerable set. A sentence grammar needs a
  real parser and fights shell tab-completion and scripting for no benefit
  this tool actually has. `git`, `docker`, `kubectl` all converged on
  verb-first for the same reason.
- **`--on` stays a flag**, not a third verb, because which deployment to
  continue *on* is genuinely optional and orthogonal — continuing itself is
  not.

Both verbs are thin wrappers over one shared operation — `Elelem::Cli::Query.run`,
in `elelem_cli/query.cr` — which resolves a `Provider`, appends the prompt,
calls `Client#send`, hands back the reply and report.

## Config: `elelem.yaml`

Search order: `$ELELEM_CONFIG` if set — the literal path, no search — else
`$CWD/elelem.yaml`, then `$HOME/elelem.yaml`. Explicit beats implicit: an
env var naming the file directly always wins over guessing from what
happens to exist.

Two tables. A **server** is somewhere to send requests and the protocol it
speaks; a **deployment** is a named way to reach one model on one server.

```yaml
servers:
  anthropic:
    protocol: anthropic
    url: https://api.anthropic.com
    credential_env: ANTHROPIC_API_KEY

  azure-alpha:
    protocol: chat_completions
    url: https://oxaro-alpha.openai.azure.com
    credential_env: AZURE_OPENAI_API_KEY
    max_tokens_field: max_completion_tokens
    azure:
      api_version: "2025-04-01-preview"

  home-ollama:
    protocol: chat_completions
    url: http://localhost:11434

deployments:
  haiku:
    server: anthropic
    model: claude-haiku-4-5

  azure-mini:
    server: azure-alpha
    model: gpt5.4mini

  qwen:
    server: home-ollama
    model: qwen3.8
    reasoning: none

  gemma:
    server: home-ollama
    model: gemma4-27b
    reasoning_retention: completed_turns
```

Credentials are referenced by environment variable name, never stored in the
file.

### Model preferences: `reasoning` and `reasoning_retention`

Both optional, both per deployment, both absent by default.

`reasoning` takes `low`, `medium`, `high`, `xhigh`, `max`, `none`, or a
positive integer token budget. `none` asks the model not to think; leaving
the key out asks nothing and leaves the provider's own default alone. The two
are genuinely different, and the distinction is load-bearing — an absent
`Options#reasoning` emits nothing on any protocol, so a deployment that
configures neither produces the same request body it produced before either
option existed, and no recorded transcript is re-cut.

There is no `off` spelling. YAML 1.1 reads a bare `off` as boolean false, so
`reasoning: off` would arrive as a bool and fail somewhere unhelpful. Rather
than accept a quoted `"off"` and carry two spellings for one thing, there is
one word — `none` — and a bare boolean gets an error saying so.

`reasoning_retention` takes `all`, `completed_turns`, or `none`, mapping
straight onto `Capability::ReasoningRetention`. `completed_turns` replays
reasoning only for the turn in progress and drops it from closed ones, which
is what some model cards ask for.

The `none` under each key means a different thing — one asks the model not to
produce reasoning, the other drops reasoning out of the history being
replayed. They share a word because it is the honest word for each key.

### Why these are configuration and not a catalog

`Capability::Catalog` already holds model-specific facts, and these
deliberately do not go in it. The line is between **hard protocol facts** and
**soft quality preferences**:

&nbsp;      |`SIGNED_TOOL_CALLS`|`reasoning`, `reasoning_retention`
------------|-------------------|----------------------------------
Wrong ⇒     |400, request fails |Answers are merely worse          
Authority   |The vendor's API   |A model card, read by the operator
Disagreement|Not reasonable     |Perfectly reasonable              
Lives in    |Code               |`elelem.yaml`                     

Facts that break requests are ours to get right. Preferences someone read off
a model card are theirs to state — and stating them in config means adding a
model never requires a release, which for locally served models is most of the
point. This settles the question `Capability::Retention` had parked.

### Why the split

One flat table meant a local Ollama serving six models repeated its URL and
protocol six times. Worse, everything awkward about that table turned out to
be a **server fact wearing a model entry's clothes** — which is why this one
change fixes two complaints rather than one.

`azure` is the clearest case. It was a boolean on a deployment, paired with
an `api_version` that had to accompany it; "azure with no api_version" was
writable and failed at provider-construction time. Nested on the server it is
present or absent, `api_version` is non-nilable, and the bad shape cannot be
written down. It also now sits on the thing it describes: Azure is about
where a request goes and how it is addressed, not about which model answers.

`max_tokens_field` moved for the same reason. `Provider.for_azure` already
rejects it on anything but ChatCompletions, which makes it a fact about the
protocol — and protocol is now a property of the endpoint.

### One behavioural change: whose name the vendor claim follows

`Provider.for`'s vendor default compares the `Server`'s name against the
protocol's canonical vendor, so a server called `anthropic` is treated as
authentically Anthropic. That name used to come from the *deployment*, which
meant `haiku` and `sonnet` were two different vendor identities for one
endpoint. It now comes from the server entry, which is the right way round:
the vendor claim is a fact about the endpoint.

### The old format is rejected, not accommodated

An old config says `server: https://…` on the deployment itself. Under the
new shape that parses as a reference to a server *named* after a URL, and
would fail with an accurate and useless "no server named
`http://localhost:11434`". `Config` sniffs for the old shape once at load and
raises something that says what to change.

Deliberately not supported as an alternative form. Accepting both forever
would mean `server:` means two different things depending on whether it
contains `://` — exactly the kind of cleverness this restructure exists to
remove.

### Naming a session: `--id`

`elelem start <deployment> <prompt...> [--id <session-id>]`. Absent, a name is
generated as before.

For anyone driving `elelem` from a script, who would rather the session be
called `nightly-summary` than have to capture whatever two words came out. It
is also the honest answer to running out of generated names: 31 adjectives by
30 nouns is 930, comfortable to around 500 stored sessions and deteriorating
past 700, and someone creating sessions in bulk was always better served by a
meaningful name than by a bigger word list.

**An existing id is refused, not continued.** `start` means start, and
silently appending to a conversation because a script reused a name is the
kind of surprise that costs someone a day. The error points at `continue`,
which says what it does.

The generator also stopped being able to fail. It used to raise after twenty
colliding tries; it now falls back to numbering — `brisk-comet-2` — but only
once the two-word space is genuinely crowded, so the first several hundred
sessions pay nothing for it. A random suffix on every name would have taxed
day one to protect against a problem most users never reach.

### Session ids are validated, because they always were user input

Letters, digits, dot, dash and underscore, starting with a letter or digit, 64
characters at most, and no `..`.

`continue SESSID` and `show SESSID` have always taken an id straight from
argv, and `path_for` joined it unchecked — so `elelem show ../../somewhere`
walked out of the sessions folder. `--id` makes that a write path too, which
is what prompted the fix, but the hole predates it.

Enforced inside `path_for` rather than at each call site: an id becomes
dangerous at exactly the moment it becomes a path, so that is the one place a
future verb cannot forget to check.

`Sessions.valid_id?` is the same question without the exception, for callers
*enumerating* the folder rather than being handed an id. The two situations
are genuinely different: an id from argv that fails validation is a mistake
worth reporting, while a directory entry that fails is debris. `list` uses the
predicate, having first shipped without it and fallen over a `.DS_Store`.

## Session storage

`$ELELEM_HOME` if set, else `$CWD/.elelem` if it exists, else `$HOME/.elelem`.
Promoted to first once `Config` needed the same escape hatch for
`$ELELEM_CONFIG` — an explicit path someone actually pulled up should not
lose to whatever `.elelem` a real invocation happened to leave sitting in
`$CWD` or `$HOME`, and that's exactly what only checking `$CWD` first could
not offer. A `sessions/` subfolder, one folder per session.

Session IDs: generated, short, memorable — adjective-noun pairs (`brisk-comet`)
over a hash prefix, for the same reason git branch names and Docker container
names do this. Collision handling is a retry-on-directory-exists, nothing
cleverer.

Storage is snapshot-per-turn, not an append-only diff log: `Session`'s own
`Archive` form is already a complete point-in-time record — MPSH rebuilds
the full request from the whole history on every call regardless — so a
session's true state at any point already *is* a full snapshot, and storing
anything less would mean reconstructing what's already free to keep. Each
`continue` writes a new timestamped file into the session's folder; nothing
is overwritten. A future `--no-history` (or similar) to overwrite instead is
cheap to add later and isn't designed in now.

Filenames carry the deployment name, not just a timestamp —
`<unix_ms>-<deployment>.json`. This is what makes `continue SESSID "..."`
work with no flag at all: it reuses whichever deployment last answered
*this* session, read straight off the last snapshot's filename. There is no
`default_deployment` in `elelem.yaml` for this to fall back to, on purpose —
an earlier version of this design had one, and it was wrong in a way that
only showed up with two configured deployments in play: it answered "what do
I usually want," a fact about the config, when what `continue` actually
needs is "what was this conversation already having," a fact about the
session. A global default silently aims a continued conversation at
whatever the config happens to prefer, which has nothing to do with where
that conversation was. Switching deployments remains exactly as deliberate
as it already was — `--on` — but staying on the same one is now free and
correct by default, rather than requiring the same flag every single time.

A snapshot written before this existed has no deployment segment in its
filename. Treated as genuinely unknown rather than guessed at: `continue`
against one of these asks for `--on` once, and every snapshot after that
carries the answer.

## Verbs: `list`, `show`, `prune`, `delete`

```
elelem list                                → one line per session
elelem show SESSID                         → the transcript
elelem show SESSID --snapshots             → the append-only turn history
elelem show SESSID --json                  → the stored archive, verbatim
elelem prune SESSID --keep N               → trim to the newest N snapshots
elelem delete SESSID                       → remove the session outright
```

Four verbs that touch no network, which makes them the only commands here
fully testable without a recording. Two read, two remove.

### Turns and snapshots are not the same number

`list` reports turns; `show --snapshots` reports save points. In the ordinary
case they agree — one `start` or `continue` writes one snapshot and adds one
genuine user input — which is why `list` counting `messages.size` went unnoticed
until someone compared the two and saw ten against five.

They can legitimately differ, because **a snapshot is a complete archive rather
than a delta**. Snapshot five is not turn five; it is the whole conversation as
of turn five. So `prune --keep 1` shortens no conversation at all: the surviving
snapshot still holds every turn, and what is lost is the ability to read the
session as it stood earlier. A pruned session therefore shows many turns and few
snapshots, correctly. The reverse — one snapshot holding a long conversation —
is possible for an archive placed by hand, though nothing in the CLI produces it.

The turn count itself defers to `MPSH::Turns`, which already knows the subtlety
that a tool result is a user-role message but not user *input*, so a
call-and-result exchange stays inside the turn that prompted it.

### Removing things

Two verbs rather than one with a mode flag. `delete` and `prune` have very
different blast radii, and behind a flag on `delete` a mistyped flag is a lost
conversation rather than a lost turn or two. Separate words also match the
grammar, which is all plain verbs.

**Naming the id is the confirmation.** No prompt, and no `--yes` to dismiss
one. This CLI is non-interactive and single-shot, prompting needs a stdin the
recorded-command specs do not have, and `rm foo` does not ask either. That
posture holds only while the blast radius is one typed name, so there is no
`--all`, no glob and no bulk mode; a verb that could remove an unknown number
of sessions would need a different answer to the confirmation question, and
would be a different verb.

**`--keep` has no default and must be at least one.** Every value is a
judgement about how much history is worth keeping. A session with no snapshots
is indistinguishable from a corrupt one, and `delete` is the verb for meaning
that.

**Neither verb parses an archive.** They work from filenames alone. An
unreadable session is among the likeliest reasons to want one gone — `list`
already renders those as `<unreadable>` — and a delete that insisted on
reading what it was about to remove would fail exactly when it was most
wanted.

**Both report to stderr**, with the session id and the fidelity warnings,
rather than to stdout with the listings: a receipt for work already done is
information about the invocation, not the thing you would pipe somewhere.

Pruning is only meaningful because `Sessions.snapshots` is genuinely
chronological, which is newer than it looks. Before `snapshot` began bumping
shared milliseconds, "the newest three" was a lexical accident that could name
the wrong file.

**Every block is rendered, not just the text ones.** `Message#text`
concatenates text blocks and drops the rest — correct for printing a reply,
wrong for an inspection verb. A transcript that silently omitted tool calls
and reasoning would misrepresent precisely the sessions this shard exists to
carry between providers, and would be most convincing on the ones that matter
most. Non-text blocks get a bracketed one-line descriptor (`Output.describe`)
— enough to know a block is there and what it is, without dumping base64 into
a terminal.

**`--snapshots` exists because the storage design is otherwise invisible.** A
transcript only ever shows the newest snapshot, so nothing in the CLI would
reveal that every `continue` appends rather than overwrites. That is a design
decision worth being able to see.

**`--json` emits the file's own bytes, not `Archive.write(Archive.read(...))`.**
A read-then-write would put this command's understanding of the format between
the person and their data, and quietly rewrite anything it did not understand.
The portable artefact is the point of the shard; handing it over should not
require knowing the folder convention, nor risk a lossy round trip on the way
out.

**Listing is deliberately cheap.** One file read per session — the newest
snapshot, which is already a complete point-in-time record, so turn count and
opening prompt come free from a read that also proves the session is intact. A
folder with no snapshots (what a crashed `start` leaves) is skipped, and one
that will not parse is reported inline rather than fatally: a corrupt session
should cost you that session, not the ability to find the other nineteen.

**`Output` gained an injectable stream** (`Output.stream`, `Output.error_stream`).
`start`/`continue` never needed one — their observable effect is a file on
disk. For `list` and `show` the output *is* the behaviour, so without a seam
they could only be tested by asserting they did not raise, which is not a test.

It turned out to be worth having for `start`/`continue` after all, for a
different reason: a `crystal spec` run was buried under the replies of every
recorded command. `spec/support/cli_output.cr` redirects both streams for the
duration of a block, and the two live command specs wrap their sandbox in it.

`Progress` is the reason `Output` had to become the *single* switch rather
than merely a switch. It draws whenever its stream is a terminal, and a spec
run in a terminal is one — so silencing `Output` alone would have left the
spinner ticking over the transcripts. `start`/`continue` therefore hand
`Progress` the `Output.error_stream` rather than `STDERR` directly.

The one thing still writing to the real streams is `src/elelem_cli.cr`, the
executable's own usage and error reporting. That is the process boundary, no
spec invokes it, and routing it through `Output` would buy nothing.

## Waiting: a ticker, not an event queue

`start` and `continue` block on one HTTP round trip with nothing to print.
Without an indicator that reads as *slow*, not *stuck* — especially against a
local Ollama, where thirty seconds is normal and indistinguishable from a hang.

`Progress` spawns a fiber that wakes every `TICK` (250ms) and redraws a
spinner and an elapsed-second count. **Elapsed seconds are the point**; a
spinner alone says the process is alive, `23s` says whether the model is slow
or the endpoint is hanging, which is the question actually being asked.

**On stderr, and only when stderr is a terminal.** The stdout rule above
exists so `elelem start ollama "..." > answer.txt` works, and a spinner on
stdout would corrupt that file. Redirected stderr is a log or a CI transcript,
where a few hundred carriage returns are worse than no indicator, so
`STDERR.tty?` gates the whole thing to a no-op.

### Why not an event queue

The natural design is for the library to emit progress events and the CLI to
render them — correct *when there are events*, which is to say once streaming
lands. Today there is one thing to report and its source is a clock, not the
server. A queue would build half of streaming's architecture against a library
with no seam to feed it, delivering none of streaming's benefit. `Elelem::Client`
is untouched by this and stays headless.

### What streaming will want from it

Streaming does not retire the ticker. Chunks arrive that cannot be shown — a
tool call spread over several deltas has to be aggregated before it is
parseable, and during that aggregation the CLI is waiting with nothing to
print again. The indicator survives; it gets started and stopped repeatedly
within one turn rather than wrapping the whole call.

Two accommodations, both free:

- `#start`/`#stop` are public and `.while_waiting` is a convenience built on
  them, so the block form is not the only door.
- `#label` is mutable, so a caller mid-stream can say what it is waiting *for*
  ("aggregating tool call") without tearing the indicator down. This is the
  part of the event-queue idea worth keeping, at none of its cost.

**Known limit:** Crystal's sockets are non-blocking and yield to the
scheduler, so ticks continue through the HTTP round trip. DNS resolution is
the exception — `getaddrinfo` can block the thread, so on a cold cache the
spinner may pause briefly before the request proper begins. It is short, it
is before the slow part, and engineering around it would cost more than it
returns. Recorded so it is not rediscovered as a bug.

## Deliberately deferred, not forgotten

- **Tool execution.** `Client#send`'s turn loop, including tool dispatch, is
  caller-owned by design (`client.cr`'s own doc comment). Whether `elelem
  start`/`continue` take tool declarations at all in v1, or ship text-only
  first, is still open — leaning text-only first, since it's the smaller
  surface to get the verb grammar and storage shape right against.
- **Streaming.** Decided in outline, deliberately unbuilt until the library's
  own streaming seam is finished and stable — this shard is a library that
  ships a CLI to prove itself, and a CLI written against a moving seam would
  end up answering the library's design questions by accident. The decision is
  recorded in *Streaming: decided, waiting on the library* below rather than
  left open, because settling it was cheap and rediscovering it would not be.
- **Interrupted-turn repair.** `SCOPE.md` MUST FIX, unbuilt. A `continue`
  against a session left dangling by a cut-short turn behaves however the
  library currently behaves — honest, not (yet) repaired.

## Streaming: decided, waiting on the library

Nothing here is built. It is written down because the two questions
`docs/STREAMING_DESIGN.md` ended with were settled before the first assembler,
and one of the two answers is this document's.

### The default is a tty test on stdout

**Stream when `stdout` is a terminal.** Not stderr. `Progress` asks
`STDERR.tty?` because it *writes* to stderr; deltas write to stdout, so the
analogous rule is the same question asked of the other stream. Copying the
expression rather than the rule would stream into a file under
`elelem start ollama "…" > answer.txt 2>&1`, where stderr is a terminal and
stdout is not.

**`--stream` and `--no-stream` override it, and win.** Not decoration: it is
how both modes get recorded per protocol, and it is the escape hatch the
library's own design argues for — the caller who has just asked for a very
large output and would rather the connection stayed warm.

### Transport follows rendering

A redirected run displays nothing incrementally, so streaming buys it nothing
— while costing it a failure class it does not otherwise have. `SCOPE.md`'s
class 3, the stream that ends without its terminal frame, **exists only when
you stream**. Accepting a new way to be silently truncated in exchange for no
visible benefit is a bad trade, so the non-tty path asks for one body.

### Printed bytes precede repair

This is the load-bearing argument for the tty rule, and it is stronger than
"a person is probably watching".

Interrupted-turn repair operates on the assembled message and may remove
content from it — a dangling tool call, most obviously. Repair cannot un-print.
Streaming to stdout is reading a page as it comes off the press: fine when you
are standing there and can see the correction slip, less fine when you wanted
the corrected edition.

The tty rule confines that irreversibility to the terminal, where a person can
see what happened and a stderr warning reaches them. Redirected stdout — the
thing a script consumes — is never streamed, so it always receives the repaired
reply. Streaming and non-streaming stdout are therefore not quite the same
artifact, and this is the sentence that says so out loud rather than leaving it
to be found.

### Reasoning is not the reply, and does not go to stdout

The library emits reasoning deltas under every retention setting — see
`docs/STREAMING_DESIGN.md` for why that is forced rather than chosen. What the
CLI does with them is a separate question, and the answer preserves an existing
guarantee: `Output.reply` prints `Message#text`, which concatenates text blocks
only, so reasoning has never reached stdout. Streaming must not be the thing
that changes that.

So: **reasoning deltas go to stderr, behind `--show-reasoning`, off by
default.** Someone who set `reasoning_retention: none` on a deployment and sees
no reasoning in their terminal gets what they expected — by way of the control
that actually governs display, rather than by the library second-guessing a
playback preference. Someone who wants to watch the model think asks for it.

### `Progress` survives, as its own doc predicted

Up before the first delta, down on it, up again with a new `label` during the
stretches that cannot be shown — a tool call spread over several deltas has to
be aggregated before it is parseable. Started and stopped repeatedly within one
turn rather than wrapping the whole call. `#start`/`#stop` being public and
`#label` being mutable is exactly this, and no part of it needs rewriting.
