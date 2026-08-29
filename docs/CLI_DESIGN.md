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

  gemma:
    server: home-ollama
    model: gemma4-27b
```

Credentials are referenced by environment variable name, never stored in the
file.

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

## Verbs: `list`, `show`

```
elelem list                                → one line per session
elelem show SESSID                         → the transcript
elelem show SESSID --snapshots             → the append-only turn history
elelem show SESSID --json                  → the stored archive, verbatim
```

Two read-only verbs. Neither touches a network, which makes them the only
commands here fully testable without a recording.

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
- **Streaming.** Doesn't exist in the library yet (`DEVELOPMENT.md`'s event-block
  sketch is forward-looking design prose, not built) — so it can't exist in
  the CLI either. Not this document's problem to solve. When it does arrive,
  see *What streaming will want from it* above: `Progress` is built to be
  reused mid-stream rather than replaced.
- **Interrupted-turn repair.** `SCOPE.md` MUST FIX, unbuilt. A `continue`
  against a session left dangling by a cut-short turn behaves however the
  library currently behaves — honest, not (yet) repaired.
- **Session deletion or pruning.** Nothing removes a session or trims its
  snapshot history yet. `list` and `show` make the accumulation visible,
  which is the point at which someone will want to; not designed in now.
